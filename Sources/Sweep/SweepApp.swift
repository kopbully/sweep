import SwiftUI

@main
struct SweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ShellView()
                .frame(minWidth: 1020, minHeight: 660)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let instanceLock = SingleInstanceLock()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 每个进程都会创建自己的桌面黑洞面板，第二个实例只会让桌面上多出一个
        // 重复的悬浮窗。这里只保留最先启动的进程，其余实例唤起已有窗口后退出。
        if ProcessInfo.processInfo.environment["SWEEP_ALLOW_MULTI_INSTANCE"] == "1" { return }
        guard instanceLock.acquire() else {
            OperationsLog.write("INSTANCE SECONDARY_LAUNCH pid=\(ProcessInfo.processInfo.processIdentifier)")
            activateRunningInstance()
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        BlackHoleController.shared.restoreIfEnabled()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard instanceLock.isHeld else { return }
        BlackHoleController.shared.shutdown()
    }

    private func activateRunningInstance() {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let others = (Bundle.main.bundleIdentifier.map {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
        } ?? []).filter { $0.processIdentifier != selfPID }
        others.first?.activate(options: [.activateIgnoringOtherApps])
    }
}

// MARK: - 模块路由

enum Module: String, Hashable, CaseIterable, Identifiable {
    case clean, uninstall, optimize, analyze, status
    var id: String { rawValue }

    var title: String {
        switch self {
        case .clean: return "清理"
        case .uninstall: return "卸载"
        case .optimize: return "优化"
        case .analyze: return "分析"
        case .status: return "监控"
        }
    }

    var glyph: String {
        switch self {
        case .clean: return "wind.snow"
        case .uninstall: return "arrow.uturn.down"
        case .optimize: return "bolt.horizontal"
        case .analyze: return "chart.pie"
        case .status: return "waveform.path.ecg"
        }
    }

    var hint: String {
        switch self {
        case .clean: return "扫描可再生缓存、日志与废纸篓"
        case .uninstall: return "移除应用并追踪残留文件"
        case .optimize: return "一键运行安全的维护任务"
        case .analyze: return "看看磁盘空间都去哪了"
        case .status: return "CPU · 内存 · 磁盘 · 网络 · 电源"
        }
    }
}

struct ShellView: View {
    @State private var selected: Module = .status
    @StateObject private var cleanEngine = CleanEngine()
    @StateObject private var uninstallEngine = UninstallEngine()
    @StateObject private var analyzeEngine = AnalyzeEngine()
    @ObservedObject private var blackHole = BlackHoleController.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                Section {
                    Image(systemName: "leaf")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.vertical, 6)
                        .listRowSeparator(.hidden)
                    Text("Sweep")
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(Theme.textPrimary)
                        .listRowSeparator(.hidden)
                    Text("安静的 macOS 空间管家")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .listRowSeparator(.hidden)
                }
                ForEach(Module.allCases) { m in
                    Label(m.title, systemImage: m.glyph)
                        .tag(m)
                        .padding(.vertical, 2)
                }
                Section("桌面") {
                    Button { blackHole.toggle() } label: {
                        Label(blackHole.isVisible ? "隐藏桌面黑洞" : "桌面黑洞", systemImage: "circle.dotted")
                    }
                    .buttonStyle(.plain)
                    .help("靠近黑洞查看引力效果，拖入文件移到废纸篓")
                    Text(blackHole.lastMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section("信息") {
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: OperationsLog.logPath, isDirectory: false))
                    } label: {
                        Label("操作日志", systemImage: "doc.text")
                    }
                    .buttonStyle(.plain)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detail
                .background(Theme.bg)
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var detail: some View {
        switch selected {
        case .clean: CleanView(engine: cleanEngine)
        case .uninstall: UninstallView(engine: uninstallEngine)
        case .optimize: OptimizeView()
        case .analyze: AnalyzeView(engine: analyzeEngine)
        case .status: StatusView()
        }
    }
}
