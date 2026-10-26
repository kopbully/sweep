import SwiftUI
import AppKit
import Darwin

// MARK: - 采样

struct MemoryBreakdown {
    var total: Int64 = 0
    var used: Int64 = 0
    var app: Int64 = 0
    var wired: Int64 = 0
    var compressed: Int64 = 0
    var cached: Int64 = 0
    var free: Int64 = 0
    var swapUsed: Int64 = 0
    var pressureLevel: Int = 1

    var usedRatio: Double { total > 0 ? Double(used) / Double(total) : 0 }

    var pressureText: String {
        switch pressureLevel {
        case 4: return "危急"
        case 2: return "紧张"
        default: return "正常"
        }
    }

    var pressureTone: TagTone {
        switch pressureLevel {
        case 4: return .danger
        case 2: return .warn
        default: return .accent
        }
    }
}

struct MemoryConsumer: Identifiable, Hashable {
    let id: Int32          // pid
    let name: String
    let rss: Int64
    var pid: Int32 { id }
}

enum MemoryProbe {
    static func read() -> MemoryBreakdown {
        var out = MemoryBreakdown()
        out.total = Int64(Sizing.totalPhysicalMemory())
        let page = Int64(vm_kernel_page_size)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return out }

        let active = Int64(stats.active_count) * page
        let inactive = Int64(stats.inactive_count) * page
        let wired = Int64(stats.wire_count) * page
        let compressed = Int64(stats.compressor_page_count) * page
        let speculative = Int64(stats.speculative_count) * page
        let purgeable = Int64(stats.purgeable_count) * page
        let app = max(Int64(stats.internal_page_count) * page - purgeable, 0)
        let cached = Int64(stats.external_page_count) * page + purgeable + speculative

        out.wired = wired
        out.compressed = compressed
        out.app = app
        out.cached = cached
        out.free = Int64(stats.free_count) * page + inactive
        out.used = app + wired + compressed
        _ = active

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            out.swapUsed = Int64(swap.xsu_used)
        }

        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 {
            out.pressureLevel = Int(level)
        }
        return out
    }

    /// 通过 ps 读取常驻内存，避免私有 API
    static func consumers(limit: Int = 14) -> [MemoryConsumer] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,rss=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var rows: [MemoryConsumer] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.drop(while: { $0 == " " })
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let kb = Int64(parts[1]) else { continue }
            let path = String(parts[2])
            let name = (path as NSString).lastPathComponent
            rows.append(MemoryConsumer(id: pid, name: name, rss: kb * 1024))
        }
        return Array(rows.sorted { $0.rss > $1.rss }.prefix(limit))
    }

    /// purge 需要管理员权限；只回收非活跃的文件缓存，不会退出任何应用
    static func purge() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"/usr/sbin/purge\" with administrator privileges"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if process.terminationStatus != 0 {
            throw NSError(domain: "Sweep.Memory", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: text.isEmpty ? "授权被取消或 purge 执行失败" : text])
        }
        return text.isEmpty ? "已执行内存整理" : text
    }
}

// MARK: - 引擎

@MainActor
final class MemoryEngine: ObservableObject {
    @Published private(set) var breakdown = MemoryBreakdown()
    @Published private(set) var consumers: [MemoryConsumer] = []
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var lastFreed: Int64 = 0

    private var timer: Task<Void, Never>?

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                self?.sample()
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func sample() {
        let snapshot = MemoryProbe.read()
        let list = MemoryProbe.consumers()
        breakdown = snapshot
        consumers = list
    }

    func release() {
        guard !busy else { return }
        busy = true
        message = "正在请求管理员授权并回收可释放内存…"
        let before = breakdown.used
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
                do {
                    _ = try MemoryProbe.purge()
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            self.busy = false
            switch outcome {
            case .success:
                self.sample()
                let freed = max(before - self.breakdown.used, 0)
                self.lastFreed = freed
                self.message = freed > 0
                    ? "内存整理完成，已用内存减少 \(freed.bytesText)。"
                    : "内存整理完成，当前没有可回收的闲置缓存。"
                OperationHistory.record(kind: .memory, summary: "整理可回收内存", bytes: freed)
                OperationsLog.write("MEMORY PURGE freed=\(freed)")
            case .failure(let error):
                self.message = "未执行：\(error.localizedDescription)"
            }
        }
    }

    func quit(_ consumer: MemoryConsumer) {
        guard let app = NSRunningApplication(processIdentifier: consumer.pid) else {
            message = "\(consumer.name) 不是可退出的前台应用，pid \(consumer.pid) 已跳过。"
            return
        }
        if app.terminate() {
            message = "已请求退出 \(consumer.name)。"
            OperationHistory.record(kind: .memory, summary: "退出 \(consumer.name)（pid \(consumer.pid)）")
        } else {
            message = "\(consumer.name) 拒绝了退出请求，可能正在处理任务。"
        }
        sample()
    }
}

// MARK: - 视图

struct MemoryView: View {
    @StateObject private var engine = MemoryEngine()
    @State private var pendingQuit: MemoryConsumer?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s300) {
                PageHeader("内存", subtitle: "已用内存由应用内存、联动内存与压缩内存组成。系统会把闲置缓存留给应用复用，整理只是提前交还这部分，不会让正在运行的程序变快。") {
                    SweepButton(.secondary, title: "刷新", systemImage: "arrow.clockwise") { engine.sample() }
                    SweepButton(.primary, title: "整理可回收内存", systemImage: "memorychip") { engine.release() }
                        .disabled(engine.busy)
                }

                composition

                HStack(spacing: Space.s100) {
                    MetricTile(title: "应用内存", value: engine.breakdown.app.sizeText,
                               caption: "各进程实际占用")
                    MetricTile(title: "联动内存", value: engine.breakdown.wired.sizeText,
                               caption: "内核与驱动，无法回收")
                    MetricTile(title: "压缩内存", value: engine.breakdown.compressed.sizeText,
                               caption: "被压缩的冷数据")
                    MetricTile(title: "交换使用", value: engine.breakdown.swapUsed.sizeText,
                               caption: engine.breakdown.pressureText == "正常" ? "压力正常" : "压力\(engine.breakdown.pressureText)",
                               tone: engine.breakdown.pressureTone == .danger ? Theme.accentDanger : Theme.textPrimary)
                }

                if let message = engine.message {
                    Text(message).font(Typo.f(Typo.xs)).foregroundStyle(Theme.textSecondary)
                }

                consumersPanel

                Panel {
                    HStack(alignment: .top, spacing: Space.s100) {
                        Image(systemName: "info.circle").font(Typo.f(Typo.sm)).foregroundStyle(Theme.textMuted)
                        Text("整理内存会调用系统自带的 purge，需要输入一次管理员密码；它只回收非活跃的文件缓存。要真正降低占用，优先退出长期不用却一直驻留的应用。")
                            .font(Typo.f(Typo.xs)).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Space.s300)
        }
        .pageSurface()
        .onAppear { engine.start() }
        .onDisappear { engine.stop() }
        .alert("退出 \(pendingQuit?.name ?? "")？", isPresented: Binding(
            get: { pendingQuit != nil },
            set: { if !$0 { pendingQuit = nil } })) {
            Button("退出应用", role: .destructive) {
                if let target = pendingQuit { engine.quit(target) }
                pendingQuit = nil
            }
            Button("取消", role: .cancel) { pendingQuit = nil }
        } message: {
            Text("会向该应用发送正常退出请求，未保存的内容可能丢失。")
        }
    }

    private var composition: some View {
        let b = engine.breakdown
        let parts: [(String, Int64, Color)] = [
            ("应用", b.app, Theme.accent),
            ("联动", b.wired, Theme.accentWarn),
            ("压缩", b.compressed, Color(hex: "#7C8CF8")),
            ("空闲", b.free, Theme.surfaceHover),
        ]
        return Panel {
            VStack(alignment: .leading, spacing: Space.s100) {
                HStack(alignment: .firstTextBaseline) {
                    Text("已用 \(b.used.sizeText)")
                        .font(Typo.mono(Typo.xxl, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("／ 共 \(b.total.bytesText)")
                        .font(Typo.f(Typo.sm)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Tag(text: "压力\(b.pressureText)", tone: b.pressureTone)
                    Tag(text: ratioText(b.usedRatio) + " 已用", tone: .neutral)
                }
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                            let ratio = b.total > 0 ? Double(part.1) / Double(b.total) : 0
                            Rectangle()
                                .fill(part.2)
                                .frame(width: max(geo.size.width * CGFloat(ratio), 0))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                }
                .frame(height: 12)
                HStack(spacing: Space.s200) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        HStack(spacing: Space.s50) {
                            Circle().fill(part.2).frame(width: 8, height: 8)
                            Text("\(part.0) \(part.1.bytesText)")
                                .font(Typo.f(Typo.xs)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
        }
    }

    private var consumersPanel: some View {
        Panel(padding: Space.s75) {
            VStack(spacing: 0) {
                HStack {
                    GroupTitle(text: "内存占用排行", trailing: "常驻大小")
                    Spacer()
                }
                .padding(.horizontal, Space.s100)
                .padding(.vertical, Space.s75)

                let peak = max(engine.consumers.first?.rss ?? 1, 1)
                ForEach(Array(engine.consumers.enumerated()), id: \.element.id) { index, consumer in
                    HStack(spacing: Space.s100) {
                        Image(systemName: "app.dashed")
                            .font(Typo.f(Typo.xs))
                            .foregroundStyle(Theme.textMuted)
                            .frame(width: 16)
                        Text(consumer.name)
                            .font(Typo.f(Typo.sm))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: Space.s100)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.surfaceHover)
                                Capsule().fill(Theme.accent.opacity(0.7))
                                    .frame(width: max(geo.size.width * CGFloat(Double(consumer.rss) / Double(peak)), 3))
                            }
                        }
                        .frame(width: 120, height: 5)
                        Text(consumer.rss.bytesText)
                            .font(Typo.mono(Typo.xs, .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 78, alignment: .trailing)
                        Text(verbatim: "pid \(consumer.pid)")
                            .font(Typo.mono(Typo.xs))
                            .foregroundStyle(Theme.textMuted)
                            .frame(width: 84, alignment: .trailing)
                        SweepButton(.quiet, title: "退出") { pendingQuit = consumer }
                    }
                    .padding(.horizontal, Space.s100)
                    .padding(.vertical, Space.s75)
                    .rowBackground()
                    if index < engine.consumers.count - 1 {
                        Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 34)
                    }
                }

                if engine.consumers.isEmpty {
                    EmptyState(icon: "memorychip", title: "暂时读不到进程",
                               message: "命令 ps 没有返回结果，稍后刷新重试。").frame(height: 160)
                }
            }
        }
    }
}
