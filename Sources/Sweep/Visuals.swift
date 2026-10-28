import SwiftUI

// MARK: - 环境光
//
// 内容区底下的一层柔光：三团几乎看不见的蓝/青/紫雾，几秒钟挪一点位置。
// 面板本身是接近实色的白，所以光只在页边留白和半透的面板上透出来，
// 用来把“一张张白纸”压出层次，而不是抢文字的对比度。

struct AmbientBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var drift = false

    private struct Blob {
        let color: String
        let size: CGFloat
        let x: CGFloat
        let y: CGFloat
        let light: Double
        let dark: Double
        let phase: CGFloat
    }

    private let blobs: [Blob] = [
        Blob(color: "#4C8DFF", size: 720, x: 0.16, y: 0.04, light: 0.30, dark: 0.40, phase: 0),
        Blob(color: "#2FC8E6", size: 560, x: 0.86, y: 0.14, light: 0.20, dark: 0.30, phase: 1),
        Blob(color: "#8B7BFF", size: 620, x: 0.58, y: 0.92, light: 0.16, dark: 0.26, phase: 2),
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.bg
                ForEach(Array(blobs.enumerated()), id: \.offset) { index, blob in
                    Circle()
                        .fill(RadialGradient(
                            colors: [Color(hex: blob.color).opacity(opacity(blob)), .clear],
                            center: .center, startRadius: 0, endRadius: blob.size / 2))
                        .frame(width: blob.size, height: blob.size)
                        .blur(radius: 70)
                        .position(x: geo.size.width * blob.x, y: geo.size.height * blob.y)
                        .offset(x: drift ? 30 - CGFloat(index) * 12 : -30 + CGFloat(index) * 12,
                                y: drift ? -22 + CGFloat(index) * 9 : 22 - CGFloat(index) * 9)
                        .animation(reduceMotion ? nil
                                   : .easeInOut(duration: 14 + Double(index) * 4)
                                       .repeatForever(autoreverses: true),
                                   value: drift)
                }
            }
            .compositingGroup()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear { drift = true }
    }

    private func opacity(_ blob: Blob) -> Double {
        scheme == .dark ? blob.dark : blob.light
    }
}

// MARK: - 微光扫过
//
// 给标题、Logo 这类小面积元素加一道周期性的高光，只在浅色主题下看得见。

struct SheenOverlay: View {
    var cornerRadius: CGFloat = Radius.md
    var period: Double = 6
    var intensity: Double = 0.45

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [.clear, .white.opacity(intensity), .clear],
                startPoint: .top, endPoint: .bottom)
                .frame(width: geo.size.width * 0.45)
                .rotationEffect(.degrees(18))
                .offset(x: phase * geo.size.width * 1.8)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 1.4).delay(1.2)
                        .repeatForever(autoreverses: false)) { phase = 1 }
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .allowsHitTesting(false)
    }
}

// MARK: - 选中态胶囊

struct SelectionPill: View {
    var active: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(hex: "#3E7DF3"), Color(hex: "#2557CE")],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.55), .white.opacity(0.06)],
                            startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
            )
            .overlay(
                // 顶部高光，让胶囊看起来是“凸”的
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.22), .clear],
                                         startPoint: .top, endPoint: .center))
            )
            .shadow(color: active ? Color(hex: "#2557CE").opacity(0.42) : .clear, radius: 10, y: 4)
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
//
// 一条会慢慢游走的高光，替代工具栏底部那根死灰线。

struct ToolbarRule: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shift = false

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.border)
            GeometryReader { geo in
                LinearGradient(
                    colors: [.clear, Theme.accent.opacity(0.55), .clear],
                    startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.35)
                    .offset(x: shift ? geo.size.width : -geo.size.width * 0.35)
                    .animation(reduceMotion ? nil
                               : .easeInOut(duration: 7).repeatForever(autoreverses: true),
                               value: shift)
            }
        }
        .frame(height: 1)
        .onAppear { shift = true }
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

// MARK: - 忙碌呼吸
//
// 扫描/卸载进行中，给主按钮一层缓慢呼吸的光，替代转圈之外的第二重反馈。

struct PulseGlow: ViewModifier {
    var active: Bool
    var color: Color
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(active ? (breathe ? 0.55 : 0.22) : 0),
                    radius: active ? 12 : 0, x: 0, y: 0)
            .onAppear { guard active, !reduceMotion else { return }; cycle() }
            .onChangeCompat(value: active) { guard active, !reduceMotion else { withAnimation { breathe = false }; return }
                cycle()
            }
    }

    private func cycle() {
        withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true)) { breathe = true }
    }
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
