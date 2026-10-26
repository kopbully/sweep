import SwiftUI

/// 迷你趋势图（sparkline）
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
            var path = Path()
            path.addLines(pts)
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            var fill = Path()
            fill.addLines(pts)
            fill.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: size.height))
            fill.addLine(to: CGPoint(x: pts[0].x, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(color.opacity(0.12)))
        }
    }

    private func points(size: CGSize) -> [CGPoint] {
        guard data.count > 1 else { return [] }
        let maxV = max(data.max() ?? 1, 0.0001)
        let w = size.width / CGFloat(data.count - 1)
        return data.enumerated().map { i, v in
            CGPoint(x: CGFloat(i) * w, y: size.height - CGFloat(v / maxV) * (size.height - 2) - 1)
        }
    }
}

/// 环形进度仪表
struct GaugeRing: View {
    let value: Double          // 0...1
    let color: Color
    let lineWidth: CGFloat = 6

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.surfaceHover, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(value, 0.001), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
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
