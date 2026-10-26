import SwiftUI
import AppKit

@main
struct SweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ShellView()
                .frame(minWidth: 1080, minHeight: 700)
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

// MARK: - 外壳

struct ShellView: View {
    @State private var selected: Module
    @StateObject private var analyzeEngine = AnalyzeEngine()
    @StateObject private var cleanEngine = CleanEngine()
    @StateObject private var uninstallEngine = UninstallEngine()
    @ObservedObject private var blackHole = BlackHoleController.shared

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
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
        }
        .background(Theme.bg)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }

    // MARK: 侧边栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.s200) {
                    ForEach(ModuleGroup.all) { group in
                        VStack(alignment: .leading, spacing: Space.s25) {
                            Text(group.title)
                                .font(Typo.f(Typo.xs, .medium))
                                .foregroundStyle(Theme.textMuted)
                                .padding(.horizontal, Space.s200)
                                .padding(.bottom, Space.s50)
                            ForEach(group.modules) { module in
                                SidebarRow(module: module, selected: selected == module) {
                                    withAnimation(Motion.quick) { selected = module }
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
        .frame(width: 228)
        .background(Theme.bg)
    }

    private var brand: some View {
        HStack(spacing: Space.s100) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(Theme.accent)
                    .frame(width: 28, height: 28)
                Image(systemName: "wind")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.black)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Sweep")
                    .font(Typo.f(Typo.lg, .semibold))
                    .foregroundStyle(Theme.titleGradient)
                Text("安静的 macOS 空间管家")
                    .font(Typo.f(Typo.xs))
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer()
        }
        .padding(.horizontal, Space.s200)
        .padding(.top, Space.s300)
        .padding(.bottom, Space.s200)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Space.s25) {
            Rectangle().fill(Theme.border).frame(height: 1)
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
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(.horizontal, Space.s200)
            .padding(.top, Space.s25)
            Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                .font(Typo.f(Typo.xs))
                .foregroundStyle(Theme.textMuted)
                .padding(.horizontal, Space.s200)
                .padding(.top, Space.s75)
                .padding(.bottom, Space.s200)
        }
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
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(selected ? Theme.accent : Color.clear)
                    .frame(width: 2, height: 14)
                Image(systemName: module.glyph)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                    .frame(width: 16)
                Text(module.title)
                    .font(Typo.f(Typo.sm, selected ? .medium : .regular))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, Space.s200)
            .padding(.vertical, Space.s75)
            .background(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(selected ? Theme.surfaceRaised : (hovering ? Theme.surface : Color.clear))
                    .padding(.horizontal, Space.s100)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? .none : Motion.quick, value: hovering)
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
                    .font(.system(size: 12))
                    .foregroundStyle(active ? Theme.accent : Theme.textSecondary)
                    .frame(width: 16)
                Text(title)
                    .font(Typo.f(Typo.xs))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
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
