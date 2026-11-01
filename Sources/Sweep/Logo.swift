import SwiftUI

/// App 内品牌标记。几何与 .icns 出自同一个 `IconArt`，改一处两边一起变。
/// 侧边栏用 40pt，其余地方可按需缩放。
struct SweepLogo: View {
    var size: CGFloat = 40
    /// 是否投影到底色上（侧边栏要，标题栏里的小图不需要）
    var shadow: Bool = true

    var body: some View {
        Canvas { ctx, canvasSize in
            let k = canvasSize.width / IconArt.canvas
            ctx.scaleBy(x: k, y: k)

            // 底板：与 icns 同一套蓝
            ctx.fill(Path(IconArt.squircle()), with: .linearGradient(boardInk,
                startPoint: CGPoint(x: 140, y: 90),
                endPoint: CGPoint(x: 900, y: 940)))
            // 左上柔光
            ctx.fill(Path(IconArt.squircle()), with: .radialGradient(
                Gradient(colors: [.white.opacity(0.30), .white.opacity(0)]),
                center: CGPoint(x: 330, y: 250), startRadius: 0, endRadius: 620))

            let parts = IconArt.mark(variant: 0)

            // 先投影再覆盖，只留外溢的一份阴影
            if shadow {
                ctx.drawLayer { layer in
                    layer.addFilter(.shadow(color: Color(hex: "#04103C").opacity(0.30),
                                            radius: 26, x: 0, y: 10))
                    for part in parts {
                        layer.fill(Path(part), with: .color(Color(hex: "#0F2560")))
                    }
                }
            }

            for part in parts {
                ctx.drawLayer { layer in
                    layer.clip(to: Path(part))
                    layer.fill(Path(CGRect(x: 0, y: 0, width: IconArt.canvas, height: IconArt.canvas)),
                               with: .linearGradient(markInk,
                                   startPoint: CGPoint(x: 284, y: 734),
                                   endPoint: CGPoint(x: 704, y: 318)))
                }
            }

            // 一道极淡的内描边，浅色底上也有轮廓
            ctx.stroke(Path(IconArt.squircle(in: IconArt.content.insetBy(dx: 2, dy: 2))),
                       with: .color(.white.opacity(0.26)),
                       lineWidth: 3)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Sweep")
    }

    private var boardInk: Gradient {
        Gradient(stops: [
            .init(color: Color(hex: "#99D4FF"), location: 0),
            .init(color: Color(hex: "#337AF5"), location: 0.55),
            .init(color: Color(hex: "#1440CC"), location: 1),
        ])
    }

    private var markInk: Gradient {
        Gradient(colors: [.white.opacity(0.90), .white])
    }
}

/// 单色版：用在浅底上的小标记（如面包屑、关于页）
struct SweepGlyph: View {
    var size: CGFloat = 16
    var color: Color = Theme.accent

    var body: some View {
        Canvas { ctx, canvasSize in
            let k = canvasSize.width / IconArt.canvas
            ctx.scaleBy(x: k, y: k)
            for part in IconArt.mark(variant: 0) {
                ctx.fill(Path(part), with: .color(color))
            }
        }
        .frame(width: size, height: size)
    }
}
