import SwiftUI

/// 迷你趋势图（sparkline）：渐变面积 + 轻微外发光 + 末点脉冲
struct Sparkline: View {
    let data: [Double]
    var color: Color = Theme.accent

    var body: some View {
        canvas
            .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 28)
    }

    private var canvas: some View {
        Canvas { ctx, size in
            let pts = points(size: size)
            guard pts.count > 1 else { return }

            var line = Path()
            line.addLines(pts)

            // 面积：从线到基线，越往下越透
            var fill = Path()
            fill.addLines(pts)
            fill.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: size.height))
            fill.addLine(to: CGPoint(x: pts[0].x, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(
                Gradient(colors: [color.opacity(0.16), color.opacity(0.0)]),
                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))

            ctx.stroke(line, with: .color(color),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

            // 末点：一个小实心点标出当前值
            let last = pts[pts.count - 1]
            ctx.fill(Path(ellipseIn: CGRect(x: last.x - 2, y: last.y - 2, width: 4, height: 4)),
                     with: .color(color))
        }
    }

    private func points(size: CGSize) -> [CGPoint] {
        guard data.count > 1 else { return [] }
        let maxV = max(data.max() ?? 1, 0.0001)
        let w = size.width / CGFloat(data.count - 1)
        return data.enumerated().map { i, v in
            CGPoint(x: CGFloat(i) * w, y: size.height - CGFloat(v / maxV) * (size.height - 4) - 2)
        }
    }
}

/// 环形进度仪表：渐变描边 + 外发光，数值变化时有过渡
struct GaugeRing: View {
    let value: Double          // 0...1
    let color: Color
    var lineWidth: CGFloat = 6
    /// 实时监控每秒都会改值；若每次都播 0.5s 的过渡，窗口有一半时间在逐帧重绘
    /// （阴影 + 磨砂面板），监控页可因此多出 10%+ CPU。实时场景传 false。
    var animated: Bool = true

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.surfaceHover, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(value, 0.001), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(animated ? Motion.base : nil, value: value)
        }
    }
}

/// 兼容旧调用点的卡片容器，样式交给设计系统
struct Card<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        Panel(padding: Space.s200) { content }
    }
}

/// 兼容旧调用点的标题，样式交给设计系统
struct SectionTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        PageHeader(title, subtitle: subtitle)
    }
}
