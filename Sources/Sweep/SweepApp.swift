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
        .windowStyle(.automatic)
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
        if ProcessInfo.processInfo.environment["SWEEP_ORPHAN_PROBE"] != nil {
            let generic = ProcessInfo.processInfo.environment["SWEEP_ORPHAN_PROBE_GENERIC"] == "1"
            UninstallDiagnostics.runOrphans(generic: generic)
            exit(0)
        }
        if ProcessInfo.processInfo.environment["SWEEP_DEV_PROBE"] != nil {
            DevLeftoverEngine.runProbe()
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
    @StateObject private var devLeftoverEngine = DevLeftoverEngine()
    @ObservedObject private var blackHole = BlackHoleController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            Rectangle().fill(Theme.border).frame(width: 1)
            VStack(spacing: 0) {
                workspaceBar
                ZStack {
                    AmbientBackdrop()
                    detail
                        .id(selected)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 10)),
                            removal: .opacity))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .animation(reduceMotion ? nil : Motion.base, value: selected)
            }
        }
        .background(Theme.bg)
        .background(SweepWindowChrome().frame(width: 0, height: 0))
        .foregroundStyle(Theme.textPrimary)
        .tint(Theme.accent)
    }

    // MARK: 侧边栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.s100) {
                    ForEach(ModuleGroup.all) { group in
                        VStack(alignment: .leading, spacing: Space.s25) {
                            Text(group.title)
                                .font(Typo.f(Typo.xs, .medium))
                                .foregroundStyle(Theme.textMuted)
                                .padding(.horizontal, Space.s200)
                                .padding(.bottom, Space.s50)
                            ForEach(group.modules) { module in
                                SidebarRow(module: module, selected: selected == module) {
                                    withAnimation(reduceMotion ? nil : Motion.quick) { selected = module }
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, Space.s100)
            }
            Spacer(minLength: Space.s100)
            footer
        }
        .frame(width: 224)
        .background(GlassSurface())
    }

    private var brand: some View {
        HStack(spacing: Space.s100) {
            // 图标自带 100/1024 的透明留白，取 46 让视觉尺寸落在 40pt
            SweepLogo(size: 46)
                .overlay(SheenOverlay(cornerRadius: 12, period: 7, intensity: 0.5))
            VStack(alignment: .leading, spacing: 3) {
                Text("Sweep")
                    .font(Typo.f(Typo.xl, .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("macOS 空间管家")
                    .font(Typo.f(Typo.xs))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, Space.s200)
        .padding(.top, Space.s200)
        .padding(.bottom, Space.s200)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Space.s25) {
            Rectangle().fill(Theme.border).frame(height: 1).padding(.horizontal, Space.s200)
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
            HStack {
                Text(blackHole.lastMessage)
                    .font(Typo.f(Typo.xs))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(.horizontal, Space.s200)
            .padding(.top, Space.s25)
            HStack {
                Text("Sweep \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                Spacer()
                Image(systemName: "laptopcomputer")
            }
            .font(Typo.f(Typo.xs))
            .foregroundStyle(Theme.textMuted)
            .padding(.horizontal, Space.s200)
            .padding(.top, Space.s75)
            .padding(.bottom, Space.s200)
        }
    }

    private var workspaceBar: some View {
        HStack(spacing: 10) {
            Image(systemName: selected.glyph)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
            Text(ModuleGroup.all.first { $0.modules.contains(selected) }?.title ?? "Sweep")
                .foregroundStyle(Theme.textSecondary)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
            Text(selected.title).fontWeight(.semibold)
            Spacer()
            Label("本机运行", systemImage: "internaldrive")
                .font(Typo.f(Typo.xs))
                .foregroundStyle(Theme.textSecondary)
        }
        .font(Typo.f(Typo.sm))
        .padding(.horizontal, Space.s300)
        .frame(height: 50)
        .background(GlassSurface(material: .headerView, blendingMode: .withinWindow))
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
        case .uninstall: UninstallView(engine: uninstallEngine, devEngine: devLeftoverEngine)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s100) {
                Image(systemName: module.glyph)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? Color.white : (hovering ? Theme.accent : Theme.textSecondary))
                    .frame(width: 20)
                    .symbolRenderingMode(.hierarchical)
                Text(module.title)
                    .font(Typo.f(Typo.sm, selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.white : Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, Space.s100)
            .frame(height: 32)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .fill(hovering && !selected ? Theme.surface.opacity(0.65) : Color.clear)
                    SelectionPill(active: selected)
                }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Space.s100)
        .accessibilityLabel(module.title)
        .accessibilityValue(selected ? "当前页面" : "")
        .accessibilityIdentifier("module-\(module.rawValue)")
        .onHover { hovering = $0 }
        .animation(reduceMotion ? .none : Motion.quick, value: hovering)
        .animation(reduceMotion ? .none : Motion.base, value: selected)
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
            HStack(spacing: Space.s100) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(active ? Theme.accent : Theme.textSecondary)
                    .frame(width: 16)
                Text(title)
                    .font(Typo.f(Typo.sm))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if active {
                    Circle().fill(Theme.success).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, Space.s200)
            .padding(.vertical, Space.s75)
            .background(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(hovering ? Theme.surface : Color.clear)
                    .padding(.horizontal, Space.s100)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
