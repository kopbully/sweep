import SwiftUI
import Darwin
import IOKit.ps

private func memoryText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
}

// MARK: - 系统采样器

struct SystemSnapshot {
    var cpuUsage: Double? = nil         // 两次采样间的 0...100
    var memUsedBytes: Int64 = 0
    var memTotalBytes: Int64 = 0
    var netInBps: Int64? = nil
    var netOutBps: Int64? = nil
    var diskTotalBytes: Int64 = 0
    var diskFreeBytes: Int64 = 0
    var batteryPercent: Double? = nil
    var onAC: Bool = true
    var load1: Double = 0
    var uptimeText: String = "—"
    var timestamp: Date? = nil
}

struct SystemReading {
    var snapshot = SystemSnapshot()
    var cpuHistory: [Double] = []
    var memHistory: [Double] = []
    var netInHistory: [Double] = []
    var netOutHistory: [Double] = []
}

@MainActor
final class SystemSampler: ObservableObject {
    @Published private(set) var reading = SystemReading()
    var snapshot: SystemSnapshot { reading.snapshot }
    var cpuHistory: [Double] { reading.cpuHistory }
    var memHistory: [Double] { reading.memHistory }
    var netInHistory: [Double] { reading.netInHistory }
    var netOutHistory: [Double] { reading.netOutHistory }
    private var samplingTask: Task<Void, Never>?

    func start() {
        guard samplingTask == nil else { return }
        reading = SystemReading()
        samplingTask = Task { [weak self] in
            let reader = SystemReader()
            while !Task.isCancelled {
                let snapshot = await reader.sampleOnce()
                guard !Task.isCancelled, self != nil else { return }
                self?.publish(snapshot)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
    }

    deinit { samplingTask?.cancel() }

    private func publish(_ snapshot: SystemSnapshot) {
        var next = reading
        next.snapshot = snapshot
        if let cpu = snapshot.cpuUsage { next.cpuHistory = push(next.cpuHistory, cpu / 100) }
        if snapshot.memTotalBytes > 0 {
            next.memHistory = push(next.memHistory, Double(snapshot.memUsedBytes) / Double(snapshot.memTotalBytes))
        }
        if let rate = snapshot.netInBps { next.netInHistory = push(next.netInHistory, Double(rate)) }
        if let rate = snapshot.netOutBps { next.netOutHistory = push(next.netOutHistory, Double(rate)) }
        reading = next
    }

    private func push(_ arr: [Double], _ v: Double) -> [Double] {
        Array((arr + [v]).suffix(60))
    }
}

struct InterfaceCounters {
    let received: UInt32
    let sent: UInt32
    let changedAt: Int64
}

struct NetworkSample {
    let interfaces: [String: InterfaceCounters]
    let uptime: Double
}

private actor SystemReader {
    private var lastCPU: [UInt32]?
    private var lastNet: NetworkSample?

    func sampleOnce() -> SystemSnapshot {
        var s = SystemSnapshot()
        let ticks = Sizing.cpuTicks()
        s.cpuUsage = Sizing.cpuUsage(previous: lastCPU, current: ticks)
        lastCPU = ticks

        let (memUsed, memTotal) = Sizing.memory()
        s.memUsedBytes = memUsed
        s.memTotalBytes = memTotal

        let network = Sizing.netBytes()
        let rates = Sizing.networkRates(previous: lastNet, current: network)
        s.netInBps = rates.received
        s.netOutBps = rates.sent
        lastNet = network

        let (total, free) = Sizing.disk()
        s.diskTotalBytes = total
        s.diskFreeBytes = free

        let batt = Sizing.battery()
        s.batteryPercent = batt.percent
        s.onAC = batt.onAC

        s.load1 = Sizing.loadAverage()
        s.uptimeText = Sizing.uptimeText()
        s.timestamp = Date()
        return s
    }
}

// 系统指标读取
enum Sizing {
    // CPU: host_processor_info
    static func cpuTicks() -> [UInt32]? {
        var numCPUs: natural_t = 0
        var info: processor_info_array_t? = nil
        var count: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &info, &count)
        guard kr == KERN_SUCCESS, let info = info, count > 0 else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(count) * MemoryLayout<integer_t>.stride))
        }
        let buf = UnsafeBufferPointer(start: info, count: Int(count))
        guard buf.count == Int(numCPUs) * Int(CPU_STATE_MAX) else { return nil }
        return buf.map { UInt32(bitPattern: $0) }
    }

    static func cpuUsage(previous: [UInt32]?, current: [UInt32]?) -> Double? {
        guard let previous, let current, !current.isEmpty,
              current.count == previous.count, current.count % Int(CPU_STATE_MAX) == 0 else { return nil }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        for i in current.indices {
            let delta = UInt64(current[i] &- previous[i])
            total += delta
            if i % Int(CPU_STATE_MAX) != Int(CPU_STATE_IDLE) { busy += delta }
        }
        guard total > 0 else { return nil }
        return Double(busy) / Double(total) * 100
    }

    // 内存：host_statistics64(HOST_VM_INFO64)
    static func memory() -> (used: Int64, total: Int64) {
        let totalMem = totalPhysicalMemory()
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { p in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, p, &count)
            }
        }
        guard kr == KERN_SUCCESS, totalMem > 0 else { return (0, Int64(totalMem)) }
        let usedPages = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
            + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
        return (min(max(usedPages * pageSize(), 0), Int64(totalMem)), Int64(totalMem))
    }

    static func totalPhysicalMemory() -> UInt64 {
        var q: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &q, &size, nil, 0)
        return q
    }

    static func pageSize() -> Int64 {
        Int64(vm_page_size)
    }

    // 网络: getifaddrs
    static func netBytes() -> NetworkSample {
        var counters: [String: InterfaceCounters] = [:]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return NetworkSample(interfaces: [:], uptime: ProcessInfo.processInfo.systemUptime)
        }
        defer { freeifaddrs(ifaddr) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            p = cur.pointee.ifa_next
            let name = String(cString: cur.pointee.ifa_name)
            // 物理 Wi-Fi / 以太网合计；避免把 VPN、回环和桥接流量重复累计。
            guard name.hasPrefix("en"), cur.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  cur.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  cur.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let data = cur.pointee.ifa_data else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            let changedAt = Int64(d.ifi_lastchange.tv_sec) * 1_000_000 + Int64(d.ifi_lastchange.tv_usec)
            counters[name] = InterfaceCounters(received: d.ifi_ibytes, sent: d.ifi_obytes, changedAt: changedAt)
        }
        return NetworkSample(interfaces: counters, uptime: ProcessInfo.processInfo.systemUptime)
    }

    static func networkRates(previous: NetworkSample?, current: NetworkSample) -> (received: Int64?, sent: Int64?) {
        guard let previous, current.uptime > previous.uptime else { return (nil, nil) }
        var received: UInt64 = 0
        var sent: UInt64 = 0
        for (name, counter) in current.interfaces {
            guard let old = previous.interfaces[name], old.changedAt == counter.changedAt else { continue }
            received += UInt64(counter.received &- old.received)
            sent += UInt64(counter.sent &- old.sent)
        }
        let elapsed = current.uptime - previous.uptime
        return (Int64(Double(received) / elapsed), Int64(Double(sent) / elapsed))
    }

    static func disk() -> (total: Int64, free: Int64) {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]) else {
            return (0, 0)
        }
        let total = Int64(v.volumeTotalCapacity ?? 0)
        return (total, min(max(Int64(v.volumeAvailableCapacity ?? 0), 0), total))
    }

    static func battery() -> (percent: Double?, onAC: Bool) {
        guard let psInfo = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(psInfo)?.takeRetainedValue() as? [CFTypeRef] else {
            return (nil, true)
        }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(psInfo, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let cap = desc[kIOPSMaxCapacityKey] as? Int, cap > 0,
               let cur = desc[kIOPSCurrentCapacityKey] as? Int,
               let state = desc[kIOPSPowerSourceStateKey] as? String {
                let onAC = state == kIOPSACPowerValue
                return (Double(cur) / Double(cap) * 100, onAC)
            }
        }
        return (nil, true)
    }

    static func loadAverage() -> Double {
        var avgs = [Double](repeating: 0, count: 3)
        getloadavg(&avgs, 3)
        return avgs[0]
    }

    static func uptimeText() -> String {
        var tv = timeval()
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var len = MemoryLayout<timeval>.size
        guard sysctl(&mib, 2, &tv, &len, nil, 0) == 0 else { return "—" }
        let secs = Int(Date().timeIntervalSince1970) - Int(tv.tv_sec)
        let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
        return d > 0 ? "\(d) 天 \(h) 小时" : "\(h) 小时 \(m) 分钟"
    }
}

// MARK: - 进程列表

struct ProcInfo: Identifiable, Hashable {
    let id: Int32
    let name: String
    let cpu: Double
    let memoryBytes: Int64
}

enum ProcList {
    static func fetch() throws -> [ProcInfo] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,pcpu=,rss=,comm="]
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        task.environment = environment
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "Sweep.Processes", code: Int(task.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "进程列表暂时不可用"])
        }
        return parse(text, excludingPID: task.processIdentifier)
    }

    static func parse(_ text: String, excludingPID: Int32? = nil) -> [ProcInfo] {
        var list: [ProcInfo] = []
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 4,
                  let pid = Int32(parts[0]),
                  let cpu = Double(parts[1]),
                  let rss = Int64(parts[2]), rss >= 0 else { continue }
            let name = parts[3...].joined(separator: " ")
            if pid == excludingPID { continue }
            list.append(ProcInfo(id: pid,
                                 name: (name as NSString).lastPathComponent,
                                 cpu: cpu,
                                 memoryBytes: rss * 1024))
        }
        return list
    }
}

// MARK: - 监控视图

struct StatusView: View {
    @StateObject private var sampler = SystemSampler()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s200) {
                SectionTitle(title: "监控", subtitle: "本机正在发生的每一件事")

                healthRow

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                          spacing: 12) {
                    metricCard(title: "CPU", value: sampler.snapshot.cpuUsage.map { String(format: "%.0f%%", $0) } ?? "采样中",
                               ratio: (sampler.snapshot.cpuUsage ?? 0) / 100,
                               detail: "负载 \(String(format: "%.2f", sampler.snapshot.load1))",
                               color: Theme.usageColor(sampler.snapshot.cpuUsage ?? 0),
                               series: sampler.cpuHistory)
                    metricCard(title: "内存", value: sampler.snapshot.memTotalBytes > 0 ? memoryText(sampler.snapshot.memUsedBytes) : "暂无数据",
                               ratio: Double(sampler.snapshot.memUsedBytes) / Double(max(sampler.snapshot.memTotalBytes, 1)),
                               detail: "共 \(memoryText(sampler.snapshot.memTotalBytes))",
                               color: Theme.usageColor(memPct()),
                               series: sampler.memHistory)
                    diskCard
                    netCard(direction: .down)
                    netCard(direction: .up)
                    if let b = sampler.snapshot.batteryPercent {
                        batteryCard(percent: b, onAC: sampler.snapshot.onAC)
                    } else {
                        uptimeCard
                    }
                }

                processCard
            }
            .padding(Space.s300)
        }
        .onAppear { if scenePhase != .background { sampler.start() } }
        .onDisappear { sampler.stop() }
        .task(id: scenePhase) {
            guard !Task.isCancelled else { return }
            if scenePhase == .background { sampler.stop() } else { sampler.start() }
        }
    }

    private var healthRow: some View {
        Card {
            HStack(spacing: Space.s200) {
                GaugeRing(value: healthScore() / 100, color: Theme.healthColor(healthScore()))
                    .frame(width: 60, height: 60)
                    .overlay(
                        Text(sampler.snapshot.timestamp == nil ? "—" : "\(Int(healthScore()))")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                    )
                VStack(alignment: .leading, spacing: Space.s50) {
                    Text("健康分")
                        .font(Typo.f(Typo.base, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(healthNote())
                        .font(Typo.f(Typo.sm))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: Space.s50) {
                    Tag(text: sampler.snapshot.timestamp == nil ? "采样中" : "实时采样",
                        tone: sampler.snapshot.timestamp == nil ? .neutral : .accent,
                        icon: "waveform.path.ecg")
                    Text("每秒更新").font(Typo.f(Typo.xs)).foregroundStyle(Theme.textMuted)
                }
            }
        }
    }

    private var processCard: some View { ProcessCard() }

    private var diskCard: some View {
        let ratio = Double(sampler.snapshot.diskTotalBytes - sampler.snapshot.diskFreeBytes) / Double(max(sampler.snapshot.diskTotalBytes, 1))
        return Card {
            VStack(alignment: .leading, spacing: Space.s100) {
                HStack {
                    Text("磁盘").font(Typo.f(Typo.sm, .medium)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Image(systemName: "internaldrive").foregroundStyle(Theme.textMuted)
                }
                HStack(alignment: .firstTextBaseline, spacing: Space.s50) {
                    Text(sampler.snapshot.diskTotalBytes > 0 ? sampler.snapshot.diskFreeBytes.bytesText : "采样中")
                        .font(Typo.f(Typo.xxl, .semibold).monospacedDigit())
                        .lineLimit(1).minimumScaleFactor(0.75)
                    if sampler.snapshot.diskTotalBytes > 0 {
                        Text("可用").font(Typo.f(Typo.xs)).foregroundStyle(Theme.textSecondary)
                    }
                }
                ProgressBar(value: ratio, color: Theme.usageColor(ratio * 100), height: 5)
                Spacer(minLength: 0)
                Text("已用 \(Int(ratio * 100))% · 共 \(sampler.snapshot.diskTotalBytes.bytesText)")
                    .font(Typo.f(Typo.xs)).foregroundStyle(Theme.textSecondary)
            }
            .frame(height: 126, alignment: .topLeading)
        }
    }

    private func netCard(direction: NetDir) -> some View {
        let isDown = direction == .down
        let bps = isDown ? sampler.snapshot.netInBps : sampler.snapshot.netOutBps
        return Card {
            VStack(alignment: .leading, spacing: Space.s100) {
                HStack {
                    Text(isDown ? "下载" : "上传")
                        .font(Typo.f(Typo.sm, .medium)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Image(systemName: isDown ? "arrow.down.circle" : "arrow.up.circle")
                        .foregroundStyle(Theme.accent)
                }
                Text(bps.map { $0 == 0 ? "0 B/s" : "\(max($0, 0).bytesText)/s" } ?? "采样中")
                    .font(Typo.f(Typo.xxl, .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Sparkline(data: isDown ? sampler.netInHistory : sampler.netOutHistory, color: Theme.accent)
                    .frame(height: 28)
                Text("Wi-Fi 与以太网合计").font(Typo.f(Typo.xs)).foregroundStyle(Theme.textMuted)
            }
            .frame(height: 126, alignment: .topLeading)
        }
        .help("Wi-Fi 与以太网物理接口合计；不重复累计 VPN 隧道流量。")
    }

    enum NetDir { case down, up }

    private func batteryCard(percent: Double, onAC: Bool) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Space.s100) {
                HStack {
                    Text("电池").font(Typo.f(Typo.sm, .medium)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Image(systemName: onAC ? "bolt.fill" : "battery.75percent").foregroundStyle(Theme.success)
                }
                Text("\(Int(percent))%").font(Typo.f(Typo.xxl, .semibold).monospacedDigit())
                ProgressBar(value: percent / 100, color: percent > 20 ? Theme.success : Theme.accentDanger, height: 5)
                Spacer(minLength: 0)
                Text(onAC ? "已接通电源" : "使用电池")
                    .font(Typo.f(Typo.xs)).foregroundStyle(Theme.textSecondary)
            }
            .frame(height: 126, alignment: .topLeading)
        }
    }

    private var uptimeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.s100) {
                HStack {
                    Text("开机时长").font(Typo.f(Typo.sm, .medium)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.textSecondary)
                }
                Text(sampler.snapshot.uptimeText)
                    .font(Typo.f(Typo.xxl, .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                Text("自本次系统启动").font(Typo.f(Typo.xs)).foregroundStyle(Theme.textMuted)
            }
            .frame(height: 126, alignment: .topLeading)
        }
    }

    private func metricCard(title: String, value: String, ratio: Double, detail: String, color: Color, series: [Double]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Space.s100) {
                HStack {
                    Text(title).font(Typo.f(Typo.sm, .medium)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Image(systemName: title == "CPU" ? "cpu" : "memorychip").foregroundStyle(Theme.accent)
                }
                Text(value).font(Typo.f(Typo.xxl, .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary).lineLimit(1).minimumScaleFactor(0.75)
                Sparkline(data: series, color: color).frame(height: 28)
                HStack {
                    GaugeRing(value: ratio, color: color).frame(width: 10, height: 10)
                    Text(detail).font(Typo.f(Typo.xs)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
            }
            .frame(height: 126, alignment: .topLeading)
        }
    }

    // MARK: helpers

    private func memPct() -> Double {
        sampler.snapshot.memTotalBytes > 0
            ? Double(sampler.snapshot.memUsedBytes) / Double(sampler.snapshot.memTotalBytes) * 100
            : 0
    }

    private func diskPct() -> Double {
        let used = sampler.snapshot.diskTotalBytes - sampler.snapshot.diskFreeBytes
        guard sampler.snapshot.diskTotalBytes > 0 else { return 0 }
        return Double(used) / Double(sampler.snapshot.diskTotalBytes) * 100
    }

    private func healthScore() -> Double {
        var score = 100.0
        if diskPct() > 90 { score -= 40 } else if diskPct() > 80 { score -= 15 }
        if memPct() > 90 { score -= 25 } else if memPct() > 80 { score -= 10 }
        if (sampler.snapshot.cpuUsage ?? 0) > 90 { score -= 15 }
        return max(score, 0)
    }

    private func healthNote() -> String {
        if sampler.snapshot.timestamp == nil { return "正在读取系统指标…" }
        if diskPct() > 90 { return "磁盘已用 \(Int(diskPct()))%，建议在「分析」中查看大文件。" }
        if diskPct() > 80 { return "磁盘占用偏高（\(Int(diskPct()))%），可以从「分析」里找找大头。" }
        if memPct() > 90 { return "内存使用率较高，可以在下方按内存排序查看进程。" }
        return "当前使用率处于常规范围。"
    }

}

private struct ProcessCard: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var procs: [ProcInfo] = []
    @State private var sortKey: SortKey = .cpu
    @State private var pinned: Set<Int32> = []
    @State private var errorMessage: String?

    private enum SortKey: String, CaseIterable {
        case cpu = "CPU", memory = "内存", name = "名称"
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("进程").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Picker("进程排序", selection: $sortKey) {
                        ForEach(SortKey.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                    Label("\(procs.count) 项 · 2 秒刷新", systemImage: "clock")
                        .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                }
                HStack {
                    Text("进程 · 点击图钉置顶")
                    Spacer()
                    Text("CPU %").frame(width: 60, alignment: .trailing)
                    Text("内存 RSS").frame(width: 84, alignment: .trailing)
                }
                .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                Divider().overlay(Theme.cardBorder)
                if let errorMessage {
                    Text(errorMessage).font(.system(size: 11)).foregroundStyle(Theme.accentWarn)
                }
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(sortedProcs) { process in
                            HStack(spacing: 10) {
                                Button { togglePin(process.id) } label: {
                                    Image(systemName: pinned.contains(process.id) ? "pin.fill" : "pin")
                                        .font(.system(size: 10))
                                        .foregroundStyle(pinned.contains(process.id) ? Theme.accentWarn : Theme.textSecondary)
                                        .frame(width: 20, height: 24)
                                }
                                .buttonStyle(.plain)
                                .help(pinned.contains(process.id) ? "取消置顶 \(process.name)" : "置顶 \(process.name)")
                                .accessibilityLabel("\(pinned.contains(process.id) ? "取消置顶" : "置顶") \(process.name)")
                                Text(process.name).font(.system(size: 12))
                                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                                    .help("PID \(process.id) · \(process.name)")
                                Spacer()
                                Text(String(format: "%.1f%%", process.cpu))
                                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                                    .foregroundStyle(process.cpu > 20 ? Theme.accentWarn : Theme.textSecondary)
                                    .frame(width: 60, alignment: .trailing)
                                Text(memoryText(process.memoryBytes))
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 84, alignment: .trailing)
                            }
                        }
                    }
                }
                .frame(height: 260)
            }
        }
        .help("CPU 为 ps 提供的进程平均占用；内存为驻留大小 RSS，共享页可能被多个进程计入。")
        .task(id: scenePhase) {
            guard scenePhase != .background else { return }
            while !Task.isCancelled {
                do {
                    let result = try await Task.detached(priority: .utility) { try ProcList.fetch() }.value
                    guard !Task.isCancelled else { return }
                    procs = result
                    pinned.formIntersection(Set(result.map(\.id)))
                    errorMessage = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    errorMessage = "读取进程失败：\(error.localizedDescription)"
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private var sortedProcs: [ProcInfo] {
        procs.sorted { a, b in
            let aPinned = pinned.contains(a.id), bPinned = pinned.contains(b.id)
            if aPinned != bPinned { return aPinned }
            switch sortKey {
            case .cpu: if a.cpu != b.cpu { return a.cpu > b.cpu }
            case .memory: if a.memoryBytes != b.memoryBytes { return a.memoryBytes > b.memoryBytes }
            case .name: if a.name != b.name { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            }
            return a.id < b.id
        }
    }

    private func togglePin(_ pid: Int32) {
        if pinned.contains(pid) { pinned.remove(pid) } else { pinned.insert(pid) }
    }
}
