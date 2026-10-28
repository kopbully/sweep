import CoreGraphics
import Foundation

// MARK: - 图标几何（唯一来源）
//
// 坐标系：左上原点、y 向下、画布 1024×1024，与 SwiftUI Canvas 一致；
// CoreGraphics 渲染时翻转成 y 向下，因此两边共用同一套数字。
//
//   · 底板：824×824 内容区居中，圆角比例对齐 macOS 图标模板
//   · 标记：一条自笔尖收细、到头部放大的清扫弧 —— 像彗星掠过磁盘
//   · 头部单独画圆头，锥形笔画不必在曲率最大的地方硬撑宽度
//
// 笔画用“中心线 + 逐点法线偏移”构造。偏移量按曲率半径截断，
// 否则内侧会在弯道处翻折，填出来就是一条自我交叉的细线。

enum IconArt {
    static let canvas: CGFloat = 1024
    /// macOS 图标规范：内容区 824×824，四周各留 100
    static let content: CGRect = CGRect(x: 100, y: 100, width: 824, height: 824)

    // MARK: 底板

    /// 底板轮廓：824×824 内容区 + 0.2255 的圆角（≈185pt，与 macOS 图标模板一致）。
    /// 早先试过超椭圆（n=5），边角比系统图标更“方”，缩小后尤其明显。
    static func squircle(in rect: CGRect = content, radius: CGFloat? = nil) -> CGPath {
        let r = radius ?? rect.width * 0.2255
        let p = CGMutablePath()
        p.addRoundedRect(in: rect, cornerWidth: r, cornerHeight: r)
        return p
    }

    // MARK: 主标记

    /// 清扫弧的中心线：左下起笔，向右上收势
    static let spine: (CGPoint, CGPoint, CGPoint, CGPoint) = (
        CGPoint(x: 284, y: 734),
        CGPoint(x: 296, y: 542),
        CGPoint(x: 486, y: 466),
        CGPoint(x: 704, y: 318)
    )

    static let headWidth: CGFloat = 136
    /// 起笔留一点厚度：缩到 16pt 时完全收成一点的细线会直接消失
    static let tailWidth: CGFloat = 2

    /// 标记本体，按子路径返回：圆头与笔画绕向不一定一致，
    /// 合成一条路径再用 nonzero 填充会在重叠处挖出空洞，所以分开填。
    /// variant 0 只有一道主笔，1 在下方多一道平行余风。
    static func mark(variant: Int = 0) -> [CGPath] {
        var parts: [CGPath] = []

        // 主笔：宽度从 tailWidth 长到 headWidth，末端由圆头接住
        parts.append(tapered(along: spine, samples: 220, roundStart: false) { t in
            tailWidth + (headWidth - tailWidth) * pow(t, 1.45)
        })
        let head = point(spine, 1)
        let headPath = CGMutablePath()
        headPath.addEllipse(in: CGRect(x: head.x - headWidth / 2, y: head.y - headWidth / 2,
                                       width: headWidth, height: headWidth))
        parts.append(headPath)

        if variant == 1 {
            // 余风：沿主笔法线下方错开，中段最粗、两头收尖
            let trail = offsetSpine(from: 0.16, to: 0.80, distance: 104)
            parts.append(tapered(along: trail, samples: 120, roundStart: true) { t in
                max(2, 34 * sin(.pi * t))
            })
        }
        return parts
    }

    // MARK: 笔画构造

    /// 沿三次贝塞尔生成锥形笔画；宽度逐点截断到曲率半径的 72%，避免内侧翻折
    static func tapered(
        along c: (CGPoint, CGPoint, CGPoint, CGPoint),
        samples: Int,
        roundStart: Bool,
        width: (CGFloat) -> CGFloat
    ) -> CGPath {
        var pts: [CGPoint] = [], tans: [CGPoint] = [], ws: [CGFloat] = []
        for i in 0...samples {
            let t = CGFloat(i) / CGFloat(samples)
            pts.append(point(c, t))
            tans.append(tangent(c, t))
            ws.append(width(t))
        }
        return ribbon(points: pts, tangents: tans, widths: ws, roundStart: roundStart, roundEnd: false)
    }

    /// 取主笔的一段，沿法线整体偏移，作为“余风”的中心线
    static func offsetSpine(from t0: CGFloat, to t1: CGFloat, distance: CGFloat, samples: Int = 120)
        -> (CGPoint, CGPoint, CGPoint, CGPoint) {
        var pts: [CGPoint] = []
        for i in 0...samples {
            let t = t0 + (t1 - t0) * CGFloat(i) / CGFloat(samples)
            let p = point(spine, t), n = normal(tangent(spine, t))
            pts.append(CGPoint(x: p.x + n.x * distance, y: p.y + n.y * distance))
        }
        // 用首末点与原切线方向反推两条控制柄，够近似即可
        let a = pts[0], d = pts[samples]
        let ta = tangent(spine, t0), td = tangent(spine, t1)
        let k = (d.x - a.x) * ta.x + (d.y - a.y) * ta.y
        let c1 = CGPoint(x: a.x + ta.x * k * 0.55, y: a.y + ta.y * k * 0.55)
        let c2 = CGPoint(x: d.x - td.x * k * 0.45, y: d.y - td.y * k * 0.45)
        return (a, c1, c2, d)
    }

    /// 用中心线采样点拼出闭合轮廓：左缘 → 圆头 → 右缘 → 起笔圆头
    static func ribbon(
        points: [CGPoint], tangents: [CGPoint], widths: [CGFloat],
        roundStart: Bool, roundEnd: Bool
    ) -> CGPath {
        let n = points.count - 1
        // 曲率半径截断
        var half: [CGFloat] = []
        for i in 0...n {
            let lo = max(0, i - 1), hi = min(n, i + 1)
            let chord = hypot(points[hi].x - points[lo].x, points[hi].y - points[lo].y)
            let a0 = atan2(tangents[lo].y, tangents[lo].x)
            let a1 = atan2(tangents[hi].y, tangents[hi].x)
            var dTheta = abs(a1 - a0)
            if dTheta > .pi { dTheta = 2 * .pi - dTheta }
            let radius = dTheta < 1e-5 ? .greatestFiniteMagnitude : chord / dTheta
            half.append(min(widths[i] / 2, radius * 0.72))
        }

        let path = CGMutablePath()
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in 0...n {
            let nr = normal(tangents[i])
            left.append(CGPoint(x: points[i].x + nr.x * half[i], y: points[i].y + nr.y * half[i]))
            right.append(CGPoint(x: points[i].x - nr.x * half[i], y: points[i].y - nr.y * half[i]))
        }

        path.move(to: left[0])
        for p in left.dropFirst() { path.addLine(to: p) }
        if roundEnd {
            appendCap(path, center: points[n], radius: half[n], tangent: tangents[n], forward: true)
        }
        for p in right.reversed() { path.addLine(to: p) }
        if roundStart {
            appendCap(path, center: points[0], radius: half[0], tangent: tangents[0], forward: false)
        }
        path.closeSubpath()
        return path
    }

    /// 半圆端帽：从一侧绕过前进方向到另一侧
    private static func appendCap(_ path: CGMutablePath, center: CGPoint, radius: CGFloat,
                                  tangent: CGPoint, forward: Bool, steps: Int = 36) {
        guard radius > 0.3 else {
            path.addLine(to: CGPoint(x: center.x, y: center.y))
            return
        }
        let base = atan2(tangent.y, tangent.x) + (forward ? .pi / 2 : -.pi / 2)
        let dir: CGFloat = forward ? -1 : 1
        for i in 1...steps {
            let a = base + dir * .pi * CGFloat(i) / CGFloat(steps)
            path.addLine(to: CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius))
        }
    }

    // MARK: 贝塞尔基础

    static func point(_ c: (CGPoint, CGPoint, CGPoint, CGPoint), _ t: CGFloat) -> CGPoint {
        let mt = 1 - t
        let a = mt * mt * mt, b = 3 * mt * mt * t, d = 3 * mt * t * t, e = t * t * t
        return CGPoint(
            x: a * c.0.x + b * c.1.x + d * c.2.x + e * c.3.x,
            y: a * c.0.y + b * c.1.y + d * c.2.y + e * c.3.y
        )
    }

    static func tangent(_ c: (CGPoint, CGPoint, CGPoint, CGPoint), _ t: CGFloat) -> CGPoint {
        let mt = 1 - t
        let dx = 3 * mt * mt * (c.1.x - c.0.x) + 6 * mt * t * (c.2.x - c.1.x) + 3 * t * t * (c.3.x - c.2.x)
        let dy = 3 * mt * mt * (c.1.y - c.0.y) + 6 * mt * t * (c.2.y - c.1.y) + 3 * t * t * (c.3.y - c.2.y)
        let len = max(sqrt(dx * dx + dy * dy), 0.0001)
        return CGPoint(x: dx / len, y: dy / len)
    }

    /// 法线 = 切线顺时针 90°（y 向下坐标系）
    static func normal(_ t: CGPoint) -> CGPoint { CGPoint(x: -t.y, y: t.x) }
}
