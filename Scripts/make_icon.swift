import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// 把 IconArt 画成 .icns。几何与 App 内 Logo 共用同一份代码。
//
//   swiftc -O -parse-as-library Sources/Sweep/IconArt.swift Scripts/make_icon.swift -o .build/make_icon
//   .build/make_icon .build/AppIcon.iconset          # 整套尺寸，可直接 iconutil -c icns
//   .build/make_icon /tmp/preview.png 1024 1         # 单张预览，用来挑方案

@main
struct IconGen {
    /// iconset 要的 1x / 2x 成对尺寸
    static let variants: [(px: Int, name: String)] = [
        (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
    ]

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let target = args.first else {
            print("usage: make_icon <out.iconset|out.png> [size] [variant]")
            exit(2)
        }
        let variant = args.count > 2 ? Int(args[2]) ?? 0 : 0

        if target.hasSuffix(".png") {
            let px = args.count > 1 ? Int(args[1]) ?? 1024 : 1024
            guard let image = render(pixels: px, variant: variant) else { exit(1) }
            write(image, to: URL(fileURLWithPath: target))
            print("wrote \(target) \(px)px")
            return
        }

        try? FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        for item in variants {
            guard let image = render(pixels: item.px, variant: variant) else { exit(1) }
            let url = URL(fileURLWithPath: target).appendingPathComponent(item.name)
            write(image, to: url)
        }
        print("wrote \(variants.count) images to \(target)")
    }

    // MARK: - 绘制

    static func render(pixels: Int, variant: Int) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
            bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // 统一成“左上原点、y 向下”的坐标系，与 IconArt 的画布一致
        let scale = CGFloat(pixels) / IconArt.canvas
        ctx.translateBy(x: 0, y: CGFloat(pixels))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high

        draw(in: ctx, variant: variant)
        return ctx.makeImage()
    }

    static func draw(in ctx: CGContext, variant: Int) {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

        // 底板：左上一束光扫过的蓝
        ctx.saveGState()
        ctx.addPath(IconArt.squircle())
        ctx.clip()
        let bg = CGGradient(colorsSpace: srgb, colors: [
            CGColor(red: 0.60, green: 0.83, blue: 1.00, alpha: 1),
            CGColor(red: 0.20, green: 0.48, blue: 0.96, alpha: 1),
            CGColor(red: 0.08, green: 0.25, blue: 0.80, alpha: 1),
        ] as CFArray, locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(bg,
                               start: CGPoint(x: 140, y: 90),
                               end: CGPoint(x: 900, y: 940),
                               options: [])
        // 左上柔光
        let glow = CGGradient(colorsSpace: srgb, colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow,
                               startCenter: CGPoint(x: 330, y: 250), startRadius: 0,
                               endCenter: CGPoint(x: 330, y: 250), endRadius: 620,
                               options: [])
        // 底部压深，避免整块发飘
        let shade = CGGradient(colorsSpace: srgb, colors: [
            CGColor(red: 0.04, green: 0.10, blue: 0.32, alpha: 0),
            CGColor(red: 0.04, green: 0.10, blue: 0.32, alpha: 0.26),
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(shade,
                               start: CGPoint(x: 512, y: 520),
                               end: CGPoint(x: 512, y: 924),
                               options: [])
        ctx.restoreGState()

        // 内描边：极淡的白圈，浅色桌面上也有轮廓
        ctx.addPath(IconArt.squircle(in: IconArt.content.insetBy(dx: 2, dy: 2)))
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.28))
        ctx.setLineWidth(3)
        ctx.strokePath()

        // 标记：白色锥形清扫弧。各子路径分别填充——圆头与笔画的绕向不一致，
        // 合成一条路径会按 nonzero 规则在重叠处挖出空洞。
        let mark = IconArt.mark(variant: variant)

        // 先按并集轮廓投影，再让白色笔画把深色本体盖住，只留下外溢的阴影
        let silhouette = CGMutablePath()
        for part in mark { silhouette.addPath(part) }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 34,
                      color: CGColor(red: 0.02, green: 0.10, blue: 0.38, alpha: 0.26))
        ctx.setFillColor(CGColor(red: 0.06, green: 0.16, blue: 0.45, alpha: 1))
        ctx.addPath(silhouette)
        ctx.fillPath()
        ctx.restoreGState()

        let ink = CGGradient(colorsSpace: srgb, colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.90),
            CGColor(red: 1, green: 1, blue: 1, alpha: 1.0),
        ] as CFArray, locations: [0, 1])!
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        for part in mark {
            ctx.saveGState()
            ctx.addPath(part)
            ctx.clip()
            ctx.drawLinearGradient(ink,
                                   start: CGPoint(x: 284, y: 734),
                                   end: CGPoint(x: 704, y: 318),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    // MARK: - 落盘

    static func write(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
