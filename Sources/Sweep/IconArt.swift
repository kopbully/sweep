import CoreGraphics
import Foundation

// MARK: - 图标（唯一来源）
//
// App 图标与侧栏 Logo 都由这里的 CoreGraphics 代码画出，Scripts/make_icon.swift
// 只负责导出各尺寸 PNG / .icns，App 内则把同一张图渲染成位图显示。
//
// 坐标系：左上原点、y 向下、画布 1024×1024（渲染时统一翻转）。
//
// 设计：
//   · 底板：Big Sur 图标网格的 824×824 圆角方块，系统蓝自上而下加深，顶部一层极淡的受光
//   · 标记：一圈半透明“磁盘”轨道 + 一段白色清扫弧（约 3/4 圈，圆头），
//           中心一颗四角星表示“清理干净”。只有白色与蓝色两种墨色，16px 下仍可辨认。

enum IconArt {
    static let canvas: CGFloat = 1024
    /// macOS 图标规范：内容区 824×824，四周各留 100
    static let content = CGRect(x: 100, y: 100, width: 824, height: 824)
    static let center = CGPoint(x: 512, y: 512)

    // 几何参数
    static let ringRadius: CGFloat = 248
    static let ringWidth: CGFloat = 74
    /// 清扫弧：从 12 点方向顺时针扫过的角度
    static let sweepDegrees: CGFloat = 268
    static let sparkleRadius: CGFloat = 128

    /// 底板轮廓：824×824 内容区 + 0.2255 圆角（≈185pt），对齐 macOS 图标模板
    static func squircle(in rect: CGRect = content, radius: CGFloat? = nil) -> CGPath {
        let r = radius ?? rect.width * 0.2255
        let p = CGMutablePath()
        p.addRoundedRect(in: rect, cornerWidth: r, cornerHeight: r)
        return p
    }

    /// 完整圆环轨道（描边路径）
    static func track() -> CGPath {
        let p = CGMutablePath()
        p.addEllipse(in: CGRect(x: center.x - ringRadius, y: center.y - ringRadius,
                                width: ringRadius * 2, height: ringRadius * 2))
        return p.copy(strokingWithWidth: ringWidth, lineCap: .butt, lineJoin: .round, miterLimit: 10)
    }

    /// 清扫弧：12 点起、顺时针（y 向下坐标中角度递增即顺时针），圆头
    static func sweepArc() -> CGPath {
        let start = -CGFloat.pi / 2
        let end = start + sweepDegrees * .pi / 180
        let p = CGMutablePath()
        p.addArc(center: center, radius: ringRadius, startAngle: start, endAngle: end, clockwise: false)
        return p.copy(strokingWithWidth: ringWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
    }

    /// 四角星：四个尖端由向心的二次曲线连接，腰身收得较细，显得利落
    static func sparkle(at c: CGPoint = center, radius r: CGFloat = sparkleRadius, waist: CGFloat = 0.16) -> CGPath {
        let p = CGMutablePath()
        let tips = [CGPoint(x: c.x, y: c.y - r), CGPoint(x: c.x + r, y: c.y),
                    CGPoint(x: c.x, y: c.y + r), CGPoint(x: c.x - r, y: c.y)]
        let w = r * waist
        let controls = [CGPoint(x: c.x + w, y: c.y - w), CGPoint(x: c.x + w, y: c.y + w),
                        CGPoint(x: c.x - w, y: c.y + w), CGPoint(x: c.x - w, y: c.y - w)]
        p.move(to: tips[0])
        for i in 0..<4 {
            p.addQuadCurve(to: tips[(i + 1) % 4], control: controls[i])
        }
        p.closeSubpath()
        return p
    }

    // MARK: 绘制

    /// 在“左上原点、y 向下、1024 画布”的上下文里画整枚图标
    static func draw(in ctx: CGContext) {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
            CGColor(colorSpace: srgb, components: [
                CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                CGFloat(hex & 0xFF) / 255, a])!
        }
        let board = squircle()

        // 底板投影：系统图标网格下方有一层很淡的落影
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 22, color: color(0x000000, 0.22))
        ctx.addPath(board)
        ctx.setFillColor(color(0x1F5AE8))
        ctx.fillPath()
        ctx.restoreGState()

        // 底板：系统蓝自上而下加深
        ctx.saveGState()
        ctx.addPath(board)
        ctx.clip()
        let bg = CGGradient(colorsSpace: srgb,
                            colors: [color(0x4FA3FF), color(0x2C74F6), color(0x1A48D4)] as CFArray,
                            locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
        // 顶部受光
        let sheen = CGGradient(colorsSpace: srgb,
                               colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)] as CFArray,
                               locations: [0, 1])!
        ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 520), options: [])
        ctx.restoreGState()

        // 内描边：顶部亮、底部隐，浅色桌面上也有清晰轮廓
        ctx.saveGState()
        ctx.addPath(squircle(in: content.insetBy(dx: 1.5, dy: 1.5)))
        ctx.setLineWidth(3)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let rim = CGGradient(colorsSpace: srgb,
                             colors: [color(0xFFFFFF, 0.35), color(0xFFFFFF, 0.05)] as CFArray,
                             locations: [0, 1])!
        ctx.drawLinearGradient(rim, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
        ctx.restoreGState()

        // 轨道
        ctx.addPath(track())
        ctx.setFillColor(color(0xFFFFFF, 0.20))
        ctx.fillPath()

        // 白色标记（清扫弧 + 星），带一层柔和的蓝色落影
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 26, color: color(0x0A2A8C, 0.35))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(color(0xFFFFFF))
        ctx.addPath(sweepArc())
        ctx.fillPath()
        ctx.addPath(sparkle())
        ctx.fillPath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// 渲染成指定像素的位图（sRGB、带透明）
    static func render(pixels: Int) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = CGFloat(pixels) / canvas
        ctx.translateBy(x: 0, y: CGFloat(pixels))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high
        draw(in: ctx)
        return ctx.makeImage()
    }
}
