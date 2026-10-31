import SwiftUI
import AppKit

@main
struct SweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ShellView()
                .frame(minWidth: 1080, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1080, height: 700)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let instanceLock = SingleInstanceLock()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 只读/受控诊断：核对卸载模块的残留匹配与删除链路，见 UninstallDiagnostics
        if let probe = ProcessInfo.processInfo.environment["SWEEP_UNINSTALL_PROBE"], !probe.isEmpty {
            let apply = ProcessInfo.processInfo.environment["SWEEP_UNINSTALL_PROBE_APPLY"] == "1"
            UninstallDiagnostics.run(appPath: probe, apply: apply)
            exit(0)
        }
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

// MARK: - 外壳

struct ShellView: View {
    @State private var selected: Module
    @StateObject private var analyzeEngine = AnalyzeEngine()
    @StateObject private var cleanEngine = CleanEngine()
    @StateObject private var uninstallEngine = UninstallEngine()
    @ObservedObject private var blackHole = BlackHoleController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var windowVisible = true

    init() {
        // 便于自动化验证：环境变量或 startModule 偏好可直接打开指定模块
        let requested = ProcessInfo.processInfo.environment["SWEEP_START_MODULE"]
            ?? UserDefaults.standard.string(forKey: "startModule")
            ?? ""
        _selected = State(initialValue: Module(rawValue: requested) ?? .status)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.border).frame(width: 0.5)
            VStack(spacing: 0) {
                workspaceBar
                ZStack {
                    AmbientBackdrop()
                    detail
                        .id(selected)
                        .transition(.opacity)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .animation(reduceMotion ? nil : Motion.quick, value: selected)
            }
        }
        // 隐藏标题栏后侧栏和工具栏延伸到窗口顶部，红绿灯浮在侧栏上，与系统应用一致
        .ignoresSafeArea(.container, edges: .top)
        .background(Theme.bg)
        .background(SweepWindowChrome().frame(width: 0, height: 0))
        .background(WindowVisibilityReader(visible: $windowVisible).frame(width: 0, height: 0))
        .environment(\.sweepWindowVisible, windowVisible)
        .foregroundStyle(Theme.textPrimary)
        .tint(Theme.accent)
    }

    // MARK: 侧边栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 给红绿灯留出位置
            Color.clear.frame(height: 40)
            brand
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.s200) {
                    ForEach(ModuleGroup.all) { group in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.title)
                                .font(Typo.f(Typo.xs, .semibold))
                                .foregroundStyle(Theme.textMuted)
                                .padding(.horizontal, Space.s200 + 2)
                                .padding(.bottom, Space.s50)
                            ForEach(group.modules) { module in
                                SidebarRow(module: module, selected: selected == module) {
                                    withAnimation(reduceMotion ? nil : Motion.instant) { selected = module }
                                }
                            }
                        }
                    }
                }
                .padding(.top, Space.s100)
                .padding(.bottom, Space.s200)
            }
            footer
        }
        .frame(width: 220)
        .background(GlassSurface())
    }

    private var brand: some View {
        HStack(spacing: Space.s75) {
            // 图标自带约 10% 透明留白，取 34 让视觉尺寸约 28pt
            SweepLogo(size: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text("Sweep")
                    .font(Typo.f(Typo.base, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("macOS 空间管家")
                    .font(Typo.f(Typo.xs))
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer()
        }
        .padding(.horizontal, Space.s200 - 2)
        .padding(.bottom, Space.s75)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 1) {
            Rectangle().fill(Theme.border).frame(height: 0.5)
                .padding(.horizontal, Space.s200)
                .padding(.bottom, Space.s75)
            SidebarFooterButton(
                title: blackHole.isVisible ? "隐藏桌面黑洞" : "桌面黑洞",
                icon: "circle.dotted",
                active: blackHole.isVisible
            ) {
                blackHole.toggle()
            }
            SidebarFooterButton(title: "操作日志", icon: "doc.text", active: false) {
                NSWorkspace.shared.open(URL(fileURLWithPath: OperationsLog.logPath, isDirectory: false))
            }
            Text(blackHole.lastMessage)
                .font(Typo.f(Typo.xs))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Space.s200 + 2)
                .padding(.top, Space.s50)
            Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                .font(Typo.f(10))
                .foregroundStyle(Theme.textMuted.opacity(0.8))
                .padding(.horizontal, Space.s200 + 2)
                .padding(.top, Space.s50)
                .padding(.bottom, Space.s200)
        }
    }

    private var workspaceBar: some View {
        HStack(spacing: Space.s75) {
            Text(ModuleGroup.all.first { $0.modules.contains(selected) }?.title ?? "Sweep")
                .foregroundStyle(Theme.textMuted)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
            Text(selected.title)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Label("仅在本机运行", systemImage: "lock.shield")
                .font(Typo.f(Typo.xs))
                .foregroundStyle(Theme.textMuted)
        }
        .font(Typo.f(Typo.sm))
        .padding(.horizontal, Space.s300)
        .frame(height: 52)
        .background(Theme.bg)
        .overlay(alignment: .bottom) { ToolbarRule() }
    }

    // MARK: 内容

    @ViewBuilder
    private var detail: some View {
        switch selected {
        case .clean: CleanView(engine: cleanEngine)
        case .largeFiles: LargeFilesView()
        case .duplicates: DuplicatesView()
        case .analyze: AnalyzeView(engine: analyzeEngine)
        case .status: StatusView()
        case .optimize: OptimizeView()
        case .startup: StartupView()
        case .memory: MemoryView()
        case .uninstall: UninstallView(engine: uninstallEngine)
        case .privacy: PrivacyView()
        case .history: HistoryView()
        }
    }
}

private struct SidebarRow: View {
    let module: Module
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let onAccent = selected && activeState != .inactive
        Button(action: action) {
            HStack(spacing: Space.s75) {
                Image(systemName: module.glyph)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(onAccent ? Color.white : Theme.accent)
                    .frame(width: 18)
                Text(module.title)
                    .font(Typo.f(Typo.sm, selected ? .medium : .regular))
                    .foregroundStyle(onAccent ? Color.white : Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, Space.s75)
            .frame(height: 28)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .fill(hovering && !selected ? Theme.textPrimary.opacity(0.06) : Color.clear)
                    SelectionPill(active: selected)
                }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Space.s100 - 2)
        .accessibilityLabel(module.title)
        .accessibilityValue(selected ? "当前页面" : "")
        .accessibilityIdentifier("module-\(module.rawValue)")
        .onHover { hovering = $0 }
        .help(module.hint)
    }
}

private struct SidebarFooterButton: View {
    let title: String
    let icon: String
    let active: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s75) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(active ? Theme.accent : Theme.textSecondary)
                    .frame(width: 18)
                Text(title)
                    .font(Typo.f(Typo.sm))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if active {
                    Circle().fill(Theme.success).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, Space.s75)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(hovering ? Theme.textPrimary.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Space.s100 - 2)
        .onHover { hovering = $0 }
    }
}
