import SwiftUI
import AppKit
import CoreImage

// MARK: - 环境光
//
// 内容区底下的一层柔光：三团几乎看不见的蓝/青/紫雾，几秒钟挪一点位置。
// 面板本身是接近实色的白，所以光只在页边留白和半透的面板上透出来，
// 用来把“一张张白纸”压出层次，而不是抢文字的对比度。

struct AmbientBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.sweepWindowVisible) private var windowVisible

    /// 只有前台可见窗口才漂移；否则原地暂停
    private var running: Bool {
        DecorativeMotion.running(visible: windowVisible, activeState: activeState, reduceMotion: reduceMotion)
    }

    fileprivate struct Blob {
        let color: String
        let size: CGFloat
        let x: CGFloat
        let y: CGFloat
        let light: Double
        let dark: Double
    }

    fileprivate static let blobs: [Blob] = [
        Blob(color: "#4C8DFF", size: 720, x: 0.16, y: 0.04, light: 0.30, dark: 0.40),
        Blob(color: "#2FC8E6", size: 560, x: 0.86, y: 0.14, light: 0.20, dark: 0.30),
        Blob(color: "#8B7BFF", size: 620, x: 0.58, y: 0.92, light: 0.16, dark: 0.26),
    ]

    var body: some View {
        ZStack {
            Theme.bg
            // 光雾的模糊只在外观切换时离屏渲染一次，漂移交给 Core Animation 在渲染服务器里插值。
            // 原实现用 SwiftUI repeatForever 按刷新率逐帧重做三团 70pt 半径的大模糊，
            // 还让上层所有磨砂面板跟着重新取样，是闲置时 CPU 占用的大头。
            AmbientBlobLayer(dark: scheme == .dark, running: running, reduceMotion: reduceMotion)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct AmbientBlobLayer: NSViewRepresentable {
    let dark: Bool
    let running: Bool
    let reduceMotion: Bool

    func makeNSView(context: Context) -> BlobView { BlobView() }

    func updateNSView(_ view: BlobView, context: Context) {
        view.configure(dark: dark, running: running, reduceMotion: reduceMotion)
    }

    final class BlobView: NSView {
        private static let blurRadius: CGFloat = 70
        private var blobLayers: [CALayer] = []
        private var dark: Bool?
        private var running = false
        private var reduceMotion = false
        private var laidOutSize: CGSize = .zero

        override var isFlipped: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
            for _ in AmbientBackdrop.blobs {
                let blob = CALayer()
                blob.contentsGravity = .resize
                layer?.addSublayer(blob)
                blobLayers.append(blob)
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(dark: Bool, running: Bool, reduceMotion: Bool) {
            if self.dark != dark {
                self.dark = dark
                renderContents()
            }
            if self.reduceMotion != reduceMotion {
                self.reduceMotion = reduceMotion
                laidOutSize = .zero
                needsLayout = true
            }
            if self.running != running {
                self.running = running
                setPaused(!running)
            }
        }

        override func layout() {
            super.layout()
            guard bounds.size != laidOutSize, bounds.width > 0 else { return }
            laidOutSize = bounds.size
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let pad = Self.blurRadius * 2
            for (index, blob) in AmbientBackdrop.blobs.enumerated() {
                let layer = blobLayers[index]
                let side = blob.size + pad * 2
                layer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                layer.position = CGPoint(x: bounds.width * blob.x, y: bounds.height * blob.y)
                layer.removeAnimation(forKey: "drift")
                let dx = 30 - CGFloat(index) * 12, dy = -22 + CGFloat(index) * 9
                if reduceMotion {
                    // 与原实现一致：减弱动态效果时停在终点位置
                    layer.position.x += dx
                    layer.position.y += dy
                    continue
                }
                let anim = CABasicAnimation(keyPath: "position")
                anim.isAdditive = true
                anim.fromValue = NSValue(point: NSPoint(x: -dx, y: -dy))
                anim.toValue = NSValue(point: NSPoint(x: dx, y: dy))
                anim.duration = 14 + Double(index) * 4
                anim.autoreverses = true
                anim.repeatCount = .infinity
                anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                anim.isRemovedOnCompletion = false
                layer.add(anim, forKey: "drift")
            }
            CATransaction.commit()
            setPaused(!running)
        }

        private func setPaused(_ paused: Bool) {
            guard let root = layer else { return }
            if paused {
                guard root.speed != 0 else { return }
                let t = root.convertTime(CACurrentMediaTime(), from: nil)
                root.speed = 0
                root.timeOffset = t
            } else {
                guard root.speed == 0 else { return }
                let paused = root.timeOffset
                root.speed = 1
                root.timeOffset = 0
                root.beginTime = 0
                root.beginTime = root.convertTime(CACurrentMediaTime(), from: nil) - paused
            }
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            renderContents()
        }

        /// 把“径向渐变圆 + 70pt 高斯模糊”预渲染成位图，之后只移动图层
        private func renderContents() {
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            // 模糊后的光雾本身没有细节，半分辨率位图放大显示看不出差别，省一半内存
            let renderScale = max(scale / 2, 1)
            let pad = Self.blurRadius * 2
            let context = CIContext(options: [.useSoftwareRenderer: false])
            for (index, blob) in AmbientBackdrop.blobs.enumerated() {
                let side = blob.size + pad * 2
                let px = Int((side * renderScale).rounded())
                guard px > 0,
                      let cg = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                cg.scaleBy(x: renderScale, y: renderScale)
                let base = NSColor(hex: blob.color).usingColorSpace(.sRGB) ?? NSColor(hex: blob.color)
                let alpha = (dark ?? false) ? blob.dark : blob.light
                let colors = [base.withAlphaComponent(alpha).cgColor, base.withAlphaComponent(0).cgColor] as CFArray
                guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                                locations: [0, 1]) else { continue }
                let center = CGPoint(x: side / 2, y: side / 2)
                cg.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                      endCenter: center, endRadius: blob.size / 2, options: [])
                guard let sharp = cg.makeImage() else { continue }
                let input = CIImage(cgImage: sharp)
                let blurred = input.clampedToExtent()
                    .applyingGaussianBlur(sigma: Double(Self.blurRadius * renderScale) / 2)
                    .cropped(to: input.extent)
                let image = context.createCGImage(blurred, from: input.extent) ?? sharp
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                blobLayers[index].contents = image
                CATransaction.commit()
            }
        }
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
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.sweepWindowVisible) private var windowVisible
    @State private var phase: CGFloat = -1

    private var running: Bool {
        DecorativeMotion.running(visible: windowVisible, activeState: activeState, reduceMotion: reduceMotion)
    }

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
        }
        // 按 period 间歇扫过一次，扫完就静止；原来的 repeatForever 忽略了 period，
        // 每 2.6 秒一次地让整块重绘。窗口不在前台时完全停下。
        .task(id: running) {
            guard running else { phase = -1; return }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            while !Task.isCancelled {
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) { phase = -1 }
                withAnimation(.easeInOut(duration: 1.4)) { phase = 1 }
                try? await Task.sleep(nanoseconds: UInt64((1.4 + max(period, 0)) * 1_000_000_000))
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
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.sweepWindowVisible) private var windowVisible

    private var running: Bool {
        DecorativeMotion.running(visible: windowVisible, activeState: activeState, reduceMotion: reduceMotion)
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.border)
            // 高光交给 Core Animation 在渲染服务器里插值：SwiftUI 的 repeatForever
            // 会让应用进程按刷新率逐帧重算布局并重绘下方的毛玻璃标题栏（实测约 6% CPU）。
            ToolbarSheenLayer(color: NSColor(Theme.accent), running: running)
        }
        .frame(height: 1)
        .allowsHitTesting(false)
    }
}

private struct ToolbarSheenLayer: NSViewRepresentable {
    let color: NSColor
    let running: Bool

    func makeNSView(context: Context) -> SheenView { SheenView() }

    func updateNSView(_ view: SheenView, context: Context) {
        view.color = color
        view.running = running
    }

    final class SheenView: NSView {
        private let gradient = CAGradientLayer()
        private var laidOutWidth: CGFloat = -1
        private static let animationKey = "sweep.toolbar.sheen"

        var color: NSColor = .controlAccentColor { didSet { if color != oldValue { applyColors() } } }
        var running = false { didSet { if running != oldValue { updateAnimation() } } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            gradient.anchorPoint = CGPoint(x: 0, y: 0.5)
            layer?.addSublayer(gradient)
            applyColors()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyColors()
        }

        override func layout() {
            super.layout()
            // 只有宽度真的变化才重建动画，避免普通布局刷新让高光跳回起点
            guard bounds.width != laidOutWidth else { return }
            laidOutWidth = bounds.width
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let width = bounds.width * 0.35
            gradient.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            gradient.position = CGPoint(x: -width, y: bounds.midY)
            CATransaction.commit()
            updateAnimation(force: true)
        }

        private func applyColors() {
            var resolved = color
            effectiveAppearance.performAsCurrentDrawingAppearance {
                resolved = color.usingColorSpace(.sRGB) ?? color
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gradient.colors = [resolved.withAlphaComponent(0).cgColor,
                               resolved.withAlphaComponent(0.55).cgColor,
                               resolved.withAlphaComponent(0).cgColor]
            CATransaction.commit()
        }

        private func updateAnimation(force: Bool = false) {
            guard bounds.width > 0 else { return }
            if !running {
                gradient.removeAnimation(forKey: Self.animationKey)
                return
            }
            if !force, gradient.animation(forKey: Self.animationKey) != nil { return }
            let width = bounds.width * 0.35
            let anim = CABasicAnimation(keyPath: "position.x")
            anim.fromValue = -width
            anim.toValue = bounds.width
            anim.duration = 7
            anim.autoreverses = true
            anim.repeatCount = .infinity
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            anim.isRemovedOnCompletion = false
            gradient.add(anim, forKey: Self.animationKey)
        }
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
