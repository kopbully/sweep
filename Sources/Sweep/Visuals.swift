import SwiftUI

// MARK: - 页面底色
//
// 早期版本在内容区底下铺了三团漂移的彩色光雾。重新设计后改为系统式的纯色底：
// 层次交给卡片的实色表面与发丝描边，而不是装饰光效。类型保留，调用点不变。

struct AmbientBackdrop: View {
    var body: some View {
        Theme.bg
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

// MARK: - 微光扫过（已停用）
//
// 保留 API 以兼容调用点，但不再绘制任何东西：周期性高光属于“花哨装饰”。

struct SheenOverlay: View {
    var cornerRadius: CGFloat = Radius.md
    var period: Double = 6
    var intensity: Double = 0.45

    var body: some View {
        Color.clear.allowsHitTesting(false)
    }
}

// MARK: - 选中态胶囊
//
// 与 macOS 侧栏一致：纯色强调色圆角矩形，无渐变、无投影。

struct SelectionPill: View {
    var active: Bool
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            // 窗口失焦时像系统侧栏一样退成灰色
            .fill(activeState == .inactive ? Theme.textPrimary.opacity(0.10) : Theme.accent)
            .opacity(active ? 1 : 0)
    }
}

// MARK: - 呼吸光晕
//
// 空状态图标背后的一圈缓慢扩散的光，让“什么都没有”也有点动静。

struct PulseHalo: View {
    var color: Color = Theme.accent
    var size: CGFloat = 60

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { i in
                Circle()
                    .stroke(color.opacity(0.35 - Double(i) * 0.12), lineWidth: 1)
                    .frame(width: size, height: size)
                    .scaleEffect(animate ? 1.5 + CGFloat(i) * 0.25 : 0.9)
                    .opacity(animate ? 0 : 0.9)
                    .animation(reduceMotion ? nil
                               : .easeOut(duration: 2.6)
                                   .repeatForever(autoreverses: false)
                                   .delay(Double(i) * 1.1),
                               value: animate)
            }
        }
        .onAppear { animate = true }
    }
}

// MARK: - 工具栏分隔线

struct ToolbarRule: View {
    var body: some View {
        Rectangle().fill(Theme.border).frame(height: 0.5)
    }
}

// MARK: - 动画数字

struct TickerText: View {
    let text: String
    var font: Font
    var color: Color

    var body: some View {
        Group {
            if #available(macOS 14.0, *) {
                Text(text)
                    .contentTransition(.numericText())
                    .animation(Motion.base, value: text)
            } else {
                Text(text)
            }
        }
        .font(font.monospacedDigit())
        .foregroundStyle(color)
    }
}

// MARK: - 列表行入场
//
// 按索引错开淡入 + 上移，让扫描结果「长出来」而不是一次性出现。
// 只播一次：List/ForEach 复用行时重新 onAppear 不会重播。

struct StaggerIn: ViewModifier {
    var index: Int
    var distance: CGFloat = 6
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : distance)
            .onAppear {
                guard !shown else { return }
                guard !reduceMotion else { shown = true; return }
                withAnimation(Motion.base.delay(Double(min(index, 24)) * 0.018)) { shown = true }
            }
    }
}

extension View {
    func staggerIn(_ index: Int) -> some View { modifier(StaggerIn(index: index)) }
}

// MARK: - 忙碌提示
//
// 原来是按钮外一圈呼吸光晕；现在进度由按钮内的文字与进度条表达，这里保持为空操作。

struct PulseGlow: ViewModifier {
    var active: Bool
    var color: Color

    func body(content: Content) -> some View { content }
}

extension View {
    func pulseGlow(_ active: Bool, color: Color = Theme.accent) -> some View {
        modifier(PulseGlow(active: active, color: color))
    }
}

/// macOS 13 只有 onChange(of:perform:)，这里统一成一处以免散落废弃警告
extension View {
    @ViewBuilder
    func onChangeCompat(value: Bool, perform: @escaping () -> Void) -> some View {
        if #available(macOS 14.0, *) {
            self.onChange(of: value) { _, _ in perform() }
        } else {
            self.onChange(of: value) { _ in perform() }
        }
    }
}
