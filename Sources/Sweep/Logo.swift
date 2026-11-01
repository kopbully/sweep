import SwiftUI
import AppKit

/// App 内品牌标记：与 App 图标是同一张 CoreGraphics 绘图（IconArt），渲染一次后缓存。
struct SweepLogo: View {
    var size: CGFloat = 40
    /// 兼容旧调用点；投影已画在图标本身里
    var shadow: Bool = true

    private static let image: NSImage = {
        let px = 256
        guard let cg = IconArt.render(pixels: px) else { return NSImage() }
        return NSImage(cgImage: cg, size: NSSize(width: px, height: px))
    }()

    var body: some View {
        Image(nsImage: Self.image)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .frame(width: size, height: size)
            .accessibilityLabel("Sweep")
    }
}

/// 单色版：用在浅底上的小标记
struct SweepGlyph: View {
    var size: CGFloat = 16
    var color: Color = Theme.accent

    var body: some View {
        Canvas { ctx, canvasSize in
            let k = canvasSize.width / IconArt.canvas
            ctx.scaleBy(x: k, y: k)
            ctx.fill(Path(IconArt.track()), with: .color(color.opacity(0.3)))
            ctx.fill(Path(IconArt.sweepArc()), with: .color(color))
            ctx.fill(Path(IconArt.sparkle()), with: .color(color))
        }
        .frame(width: size, height: size)
    }
}
