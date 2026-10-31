import SwiftUI
import AppKit

// MARK: - 窗口可见性
//
// 监控页、进程列表和装饰动画都只对“看得见”的窗口有意义。窗口被最小化、
// 完全遮挡或切到别的桌面空间时，macOS 会清掉 occlusionState 的 .visible 位，
// 这里把它转成环境值，让各处在看不见时暂停采样和动画，省掉无人观看的 CPU。

private struct WindowVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// 宿主窗口当前是否真的出现在屏幕上（未最小化、未被完全遮挡）
    var sweepWindowVisible: Bool {
        get { self[WindowVisibleKey.self] }
        set { self[WindowVisibleKey.self] = newValue }
    }
}

/// 零尺寸的探针视图：挂到窗口后监听遮挡状态变化并回写 binding
struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = { value in
            if visible != value { visible = value }
        }
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onChange = { value in
            if visible != value { visible = value }
        }
    }

    final class ProbeView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        private func report() {
            guard let window else { return }
            onChange?(window.occlusionState.contains(.visible))
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

/// 装饰性循环动画是否应该在跑：窗口可见、是前台窗口、且未开启“减弱动态效果”
struct DecorativeMotion {
    static func running(visible: Bool, activeState: ControlActiveState, reduceMotion: Bool) -> Bool {
        visible && activeState != .inactive && !reduceMotion
    }
}
