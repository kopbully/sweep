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
                Gradient(colors: [color.opacity(0.30), color.opacity(0.02)]),
                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))

            // 外发光：同一条线描粗一点、糊一层再压上来
            ctx.drawLayer { glow in
                glow.addFilter(.blur(radius: 2.5))
                glow.stroke(line, with: .color(color.opacity(0.45)),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            ctx.stroke(line, with: .linearGradient(
                Gradient(colors: [color.opacity(0.75), color]),
                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: size.width, y: 0)),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

            // 末点：一个小实心点加一圈光晕
            let last = pts[pts.count - 1]
            ctx.fill(Path(ellipseIn: CGRect(x: last.x - 5, y: last.y - 5, width: 10, height: 10)),
                     with: .color(color.opacity(0.22)))
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

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.surfaceHover, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(value, 0.001), 1))
                .stroke(
                    AngularGradient(
                        colors: [color.opacity(0.45), color, color.opacity(0.85)],
                        center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.5), radius: lineWidth * 0.7)
                .animation(Motion.base, value: value)
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
