import SwiftUI
import Darwin
import IOKit.ps

// MARK: - 系统采样器

struct SystemSnapshot {
    var cpuUsage: Double = 0            // 0...100
    var memUsedBytes: Int64 = 0
    var memTotalBytes: Int64 = 0
    var netInBps: Int64 = 0
    var netOutBps: Int64 = 0
    var diskTotalBytes: Int64 = 0
    var diskFreeBytes: Int64 = 0
    var batteryPercent: Double? = nil
    var onAC: Bool = true
    var load1: Double = 0
    var uptimeText: String = "—"
    var timestamp: Date = Date()
}

final class SystemSampler: ObservableObject {
    @Published var snapshot = SystemSnapshot()
    @Published var cpuHistory: [Double] = Array(repeating: 0, count: 60)
    @Published var memHistory: [Double] = Array(repeating: 0, count: 60)
    @Published var netInHistory: [Double] = Array(repeating: 0, count: 60)
    @Published var netOutHistory: [Double] = Array(repeating: 0, count: 60)

    private var timer: Timer?
    private var lastNet: (rx: Int64, tx: Int64, t: Date)? = nil

    func start() {
        guard timer == nil else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func tick() {
        let snap = sampleOnce()
        DispatchQueue.main.async {
            self.snapshot = snap
            let cpuSpec = snap.cpuUsage / 100
            let memSpec = snap.memTotalBytes > 0 ? Double(snap.memUsedBytes) / Double(snap.memTotalBytes) : 0
            let inSpec = min(Double(snap.netInBps) / 2_000_000, 1)      // 2MB/s 满量程
            let outSpec = min(Double(snap.netOutBps) / 2_000_000, 1)
            self.cpuHistory = self.push(self.cpuHistory, cpuSpec)
            self.memHistory = self.push(self.memHistory, memSpec)
            self.netInHistory = self.push(self.netInHistory, inSpec)
            self.netOutHistory = self.push(self.netOutHistory, outSpec)
        }
    }

    private func push(_ arr: [Double], _ v: Double) -> [Double] {
        Array(arr.dropFirst()) + [v]
    }

    func sampleOnce() -> SystemSnapshot {
        var s = SystemSnapshot()
        s.cpuUsage = Sizing.cpuLoad()

        let (memUsed, memTotal) = Sizing.memory()
        s.memUsedBytes = memUsed
        s.memTotalBytes = memTotal

        let (rx, tx) = Sizing.netBytes()
        let now = Date()
        if let last = lastNet, now.timeIntervalSince(last.t) > 0.5 {
            s.netInBps = Int64(Double(rx - last.rx) / now.timeIntervalSince(last.t))
            s.netOutBps = Int64(Double(tx - last.tx) / now.timeIntervalSince(last.t))
        }
        lastNet = (rx, tx, now)

        let (total, free) = Sizing.disk()
        s.diskTotalBytes = total
        s.diskFreeBytes = free

        let batt = Sizing.battery()
        s.batteryPercent = batt.percent
        s.onAC = batt.onAC

        s.load1 = Sizing.loadAverage()
        s.uptimeText = Sizing.uptimeText()
        return s
    }
}

// 系统指标读取
enum Sizing {
    // CPU: host_processor_info
    static func cpuLoad() -> Double {
        var numCPUs: natural_t = 0
        var info: processor_info_array_t? = nil
        var count: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &info, &count)
        guard kr == KERN_SUCCESS, let info = info, count > 0 else { return 0 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(count) * MemoryLayout<integer_t>.stride))
        }
        let buf = UnsafeBufferPointer(start: info, count: Int(count))
        let perCPU = Int(2 + CPU_STATE_MAX)
        guard buf.count >= Int(numCPUs) * perCPU else { return 0 }
        var user: Int64 = 0, sys: Int64 = 0, nice: Int64 = 0, idle: Int64 = 0
        for c in 0..<Int(numCPUs) {
            let base = c * perCPU
            user += Int64(buf[base + 0])
            sys += Int64(buf[base + 1])
            idle += Int64(buf[base + 2])
            nice += Int64(buf[base + 3])
        }
        let busy = user + sys + nice
        let total = busy + idle
        guard total > 0 else { return 0 }
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
        let free = Int64(stats.free_count) * pageSize()
        let inactive = Int64(stats.inactive_count) * pageSize()
        let purgeable = Int64(stats.purgeable_count) * pageSize()
        let used = Int64(totalMem) - free - inactive - purgeable
        return (max(used, 0), Int64(totalMem))
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
    static func netBytes() -> (rx: Int64, tx: Int64) {
        var rx: Int64 = 0, tx: Int64 = 0
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            p = cur.pointee.ifa_next
            if let data = cur.pointee.ifa_data, cur.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) {
                let d = data.assumingMemoryBound(to: if_data64.self).pointee
                rx += Int64(d.ifi_ibytes)
                tx += Int64(d.ifi_obytes)
            }
        }
        return (rx, tx)
    }

    static func disk() -> (total: Int64, free: Int64) {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) else {
            return (0, 0)
        }
        return (Int64(v.volumeTotalCapacity ?? 0), Int64(v.volumeAvailableCapacityForImportantUsage ?? 0))
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
    let memMB: Double
}

enum ProcList {
    static func fetch() -> [ProcInfo] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "ps -axo pid=,pcpu=,pmem=,comm= | grep -v 'ps -axo'"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var list: [ProcInfo] = []
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4,
                  let pid = Int32(parts[0]),
                  let cpu = Double(parts[1]),
                  let pmem = Double(parts[2]) else { continue }
            let name = parts[3...].joined(separator: " ")
            if pid == ProcessInfo.processInfo.processIdentifier { continue }
            list.append(ProcInfo(id: pid,
                                 name: (name as NSString).lastPathComponent,
                                 cpu: cpu,
                                 memMB: pmem * 10))   // %mem * 物理 GB => MB 近似，展示用
        }
        // 用真实物理内存换算 MB
        let totalMem = Sizing.totalPhysicalMemory()
        let gb = Double(totalMem) / 1e9
        return list.map { ProcInfo(id: $0.id, name: $0.name, cpu: $0.cpu, memMB: $0.memMB / 10 * gb) }
            .sorted { $0.cpu > $1.cpu }
    }
}

// MARK: - 监控视图

struct StatusView: View {
    @StateObject private var sampler = SystemSampler()
    @State private var procs: [ProcInfo] = []
    @State private var sortKey: SortKey = .cpu
    @State private var pinned: Set<String> = []
    @State private var loopActive = false
    @State private var pollInFlight = false

    enum SortKey: String, CaseIterable {
        case cpu = "CPU"
        case mem = "内存"
        case name = "名称"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(title: "监控", subtitle: "本机正在发生的每一件事")

                healthRow

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                          spacing: 12) {
                    metricCard(title: "CPU", value: String(format: "%.0f%%", sampler.snapshot.cpuUsage),
                               ratio: sampler.snapshot.cpuUsage / 100,
                               detail: "负载 \(String(format: "%.2f", sampler.snapshot.load1))",
                               color: Theme.healthColor(100 - sampler.snapshot.cpuUsage),
                               series: sampler.cpuHistory)
                    metricCard(title: "内存", value: sampler.snapshot.memUsedBytes.bytesText,
                               ratio: Double(sampler.snapshot.memUsedBytes) / Double(max(sampler.snapshot.memTotalBytes, 1)),
                               detail: "共 \(sampler.snapshot.memTotalBytes.bytesText)",
                               color: Theme.healthColor(100 - memPct()),
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
            .padding(20)
        }
        .onAppear { sampler.start(); refreshProcs() }
        .onDisappear { sampler.stop(); loopActive = false }
        .background(Theme.bg)
    }

    private var healthRow: some View {
        Card {
            HStack(spacing: 18) {
                GaugeRing(value: healthScore() / 100, color: Theme.healthColor(healthScore()))
                    .frame(width: 52, height: 52)
                    .overlay(
                        Text("\(Int(healthScore()))")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text("健康分")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(healthNote())
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                Spacer()
            }
        }
    }

    private var processCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("进程")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Picker("", selection: $sortKey) {
                        ForEach(SortKey.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    Label("2 秒刷新", systemImage: "clock")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                }
                headerRow
                Divider().overlay(Theme.cardBorder)
                ForEach(sortedProcs) { p in
                    HStack(spacing: 10) {
                        Image(systemName: pinned.contains(p.name) ? "pin.fill" : "pin")
                            .font(.system(size: 9))
                            .foregroundStyle(pinned.contains(p.name) ? Theme.accentWarn : Theme.textSecondary.opacity(0.35))
                            .onTapGesture { togglePin(p.name) }
                        Text(p.name)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Text(String(format: "%.1f%%", p.cpu))
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(p.cpu > 20 ? Theme.accentWarn : Theme.textSecondary)
                            .frame(width: 60, alignment: .trailing)
                        Text("\(Int(p.memMB)) MB")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 72, alignment: .trailing)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture { togglePin(p.name) }
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Text("进程")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text("CPU %")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 60, alignment: .trailing)
            Text("内存")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 72, alignment: .trailing)
        }
    }

    private var diskCard: some View {
        let ratio = Double(sampler.snapshot.diskTotalBytes - sampler.snapshot.diskFreeBytes) / Double(max(sampler.snapshot.diskTotalBytes, 1))
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("磁盘").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text("\(Int(ratio * 100))% 已用")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.healthColor(100 - ratio * 100))
                }
                GaugeRing(value: ratio, color: Theme.healthColor(100 - ratio * 100))
                    .frame(width: 44, height: 44)
                    .frame(maxWidth: .infinity)
                Text("空闲 \(sampler.snapshot.diskFreeBytes.bytesText) / \(sampler.snapshot.diskTotalBytes.bytesText)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func netCard(direction: NetDir) -> some View {
        let isDown = direction == .down
        let bps = isDown ? sampler.snapshot.netInBps : sampler.snapshot.netOutBps
        return Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: isDown ? "arrow.down" : "arrow.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isDown ? Theme.accent : Theme.textSecondary)
                    Text(isDown ? "下载" : "上传")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text("\(max(bps, 0).bytesText)/s")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                }
                Sparkline(data: isDown ? sampler.netInHistory : sampler.netOutHistory,
                          color: isDown ? Theme.accent : Theme.textSecondary.opacity(0.7))
                    .frame(height: 26)
            }
        }
    }

    enum NetDir { case down, up }

    private func batteryCard(percent: Double, onAC: Bool) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: onAC ? "bolt.fill" : "battery.75percent")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(onAC ? Theme.accent : Theme.textSecondary)
                    Text("电池").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text("\(Int(percent))%")
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                }
                GaugeRing(value: percent / 100, color: percent > 20 ? Theme.accent : Theme.accentDanger)
                    .frame(width: 40, height: 40)
                    .frame(maxWidth: .infinity)
                Text(onAC ? "已接通电源" : "使用电池")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var uptimeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                    Text("开机时长").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Text(sampler.snapshot.uptimeText)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }
        }
    }

    private func metricCard(title: String, value: String, ratio: Double, detail: String, color: Color, series: [Double]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(value)
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                }
                Sparkline(data: series, color: color)
                    .frame(height: 24)
                HStack {
                    GaugeRing(value: ratio, color: color)
                        .frame(width: 12, height: 12)
                    Text(detail).font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
            }
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
        if sampler.snapshot.cpuUsage > 90 { score -= 15 }
        return max(score, 0)
    }

    private func healthNote() -> String {
        if diskPct() > 90 { return "磁盘已满 \(Int(diskPct()))%，系统开始变卡。去「清理」回收一些空间。" }
        if diskPct() > 80 { return "磁盘占用偏高（\(Int(diskPct()))%），可以从「分析」里找找大头。" }
        if memPct() > 90 { return "内存压力大，浏览器开着很多标签时尤其明显。" }
        return "一切正常，安静地跑着。"
    }

    private var sortedProcs: [ProcInfo] {
        let pinnedFirst = procs.filter { pinned.contains($0.name) }
        let rest = procs.filter { !pinned.contains($0.name) }
        let sorted: [ProcInfo]
        switch sortKey {
        case .cpu: sorted = rest.sorted { $0.cpu > $1.cpu }
        case .mem: sorted = rest.sorted { $0.memMB > $1.memMB }
        case .name: sorted = rest.sorted { $0.name < $1.name }
        }
        return pinnedFirst + sorted
    }

    private func togglePin(_ name: String) {
        if pinned.contains(name) { pinned.remove(name) } else { pinned.insert(name) }
    }

    private func refreshProcs() {
        loopActive = true
        pollingLoop()
    }

    private func pollingLoop() {
        guard loopActive else { return }
        pollInFlight = true
        DispatchQueue.global(qos: .utility).async {
            let result = ProcList.fetch()
            DispatchQueue.main.async {
                if loopActive {
                    procs = result
                }
                pollInFlight = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard loopActive else { return }
                pollingLoop()
            }
        }
    }
}
