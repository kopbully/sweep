import SwiftUI

enum Theme {
    static let bg = Color(hex: "#101216")
    static let card = Color(hex: "#181B21")
    static let cardBorder = Color(hex: "#262B33")
    static let textPrimary = Color(hex: "#E9ECF1")
    static let textSecondary = Color(hex: "#8B93A1")
    static let accent = Color(hex: "#3ECF8E")
    static let accentWarn = Color(hex: "#E8A33D")
    static let accentDanger = Color(hex: "#E25B5B")

    static func healthColor(_ score: Double) -> Color {
        if score >= 80 { return accent }
        if score >= 50 { return accentWarn }
        return accentDanger
    }
}

extension Color {
    init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        let r, g, b: Double
        if h.count == 6 {
            r = Double((v >> 16) & 0xFF) / 255
            g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255
        } else {
            r = 0.5; g = 0.5; b = 0.5
        }
        self = Color(red: r, green: g, blue: b)
    }
}

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
                .stroke(Theme.cardBorder, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(value, 0.001), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: value)
        }
    }
}

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(14)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.cardBorder, lineWidth: 1))
    }
}

struct SectionTitle: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        }
    }
}
