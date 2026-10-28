import SwiftUI
import AppKit

// MARK: - 视觉令牌
//
// 参考 a2d2-dev/macos27-claude 的 glass.css 与 Finder 窗口层次。
// 玻璃材质由 AppKit 合成，列表与卡片保持实色以保证文字对比度。

enum Theme {
    static let bg = Color.adaptive(light: "#F4F7FC", dark: "#1C1C20")
    static let surface = Color.adaptive(light: "#FFFFFF", dark: "#29292E")
    static let surfaceRaised = Color.adaptive(light: "#EDF1F7", dark: "#34343A")
    static let surfaceHover = Color.adaptive(light: "#E3EAF4", dark: "#414148")
    static let border = Color.adaptive(light: "#DCE3ED", dark: "#42424A")
    static let chrome = Color.adaptive(light: "#EAF1FB", dark: "#24242B")
    static let chromeTint = Color.adaptive(light: "#F5F9FF", dark: "#1C1C24").opacity(0.34)
    static let shadow = Color.adaptive(light: "#233653", dark: "#000000").opacity(0.07)

    // 文字
    static let textPrimary = Color.adaptive(light: "#202C3F", dark: "#F0F0F4")
    static let textSecondary = Color.adaptive(light: "#5D6A7E", dark: "#B9B9C5")
    static let textMuted = Color.adaptive(light: "#667085", dark: "#9393A3")

    static let accent = Color.adaptive(light: "#246CDF", dark: "#78AAFF")
    static let actionFill = Color(hex: "#2869DB")
    static let selection = Color(hex: "#3070DF")
    static let accentSoft = accent.opacity(0.10)
    static let success = Color.adaptive(light: "#208458", dark: "#57C995")
    static let accentWarn = Color.adaptive(light: "#A26612", dark: "#F0B65D")
    static let accentWarnSoft = accentWarn.opacity(0.12)
    static let accentDanger = Color.adaptive(light: "#CC3945", dark: "#FF7B86")
    static let accentDangerSoft = accentDanger.opacity(0.10)

    // 兼容既有调用点
    static let card = surface
    static let cardBorder = border

    static func healthColor(_ score: Double) -> Color {
        if score >= 80 { return success }
        if score >= 50 { return accentWarn }
        return accentDanger
    }

    static func usageColor(_ percent: Double) -> Color {
        if percent >= 90 { return accentDanger }
        if percent >= 80 { return accentWarn }
        return accent
    }

}

/// 使用原生 SF 字体，与参考项目的 macOS 字体栈保持一致。
enum Typo {
    static let xs: CGFloat = 11
    static let sm: CGFloat = 13
    static let base: CGFloat = 15
    static let lg: CGFloat = 17
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 26
    static let display: CGFloat = 34

    static func f(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// 间距令牌：2 / 4 / 8 / 12 / 16 / 24 / 32 / 40 / 48
enum Space {
    static let s25: CGFloat = 2
    static let s50: CGFloat = 4
    static let s75: CGFloat = 8
    static let s100: CGFloat = 12
    static let s200: CGFloat = 16
    static let s300: CGFloat = 24
    static let s400: CGFloat = 32
    static let s500: CGFloat = 40
    static let s600: CGFloat = 48
}

/// 圆角令牌，含嵌套公式
enum Radius {
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 24

    /// 内层圆角 = 外层圆角 − 间距；结果不大于 2 时内层保持直角
    static func nested(outer: CGFloat, gap: CGFloat) -> CGFloat {
        let value = outer - gap
        return value > 2 ? value : 0
    }
}

/// 动效：统一使用 cubic-bezier(0.22, 1, 0.36, 1)，颜色类位移用短时长
enum Motion {
    static let base = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.5)
    static let quick = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.3)
    static let instant = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.18)
}

extension Color {
    static func adaptive(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(hex: hex)
        })
    }

    init(hex: String) {
        self.init(nsColor: NSColor(hex: hex))
    }
}

private extension NSColor {
    convenience init(hex: String) {
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
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

/// 只在窗口侧栏和工具栏使用系统磨砂，避免为每个列表项建立模糊层。
struct GlassSurface: View {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                Theme.chrome
            } else {
                NativeGlass(material: material, blendingMode: blendingMode)
                    .overlay(Theme.chromeTint)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct NativeGlass: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView { NSVisualEffectView() }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
    }
}

struct SweepWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.titlebarAppearsTransparent = true
            window?.isMovableByWindowBackground = true
            window?.backgroundColor = .windowBackgroundColor
        }
    }
}

// MARK: - 按钮

enum ButtonKind: Equatable {
    case primary
    case secondary
    case quiet
    case danger
}

struct SweepButton<Label: View>: View {
    let kind: ButtonKind
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var hovering = false

    init(_ kind: ButtonKind = .secondary, action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.kind = kind
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action, label: label)
            .buttonStyle(SweepButtonStyle(kind: kind, hovering: hovering))
            .onHover { hovering = $0 }
    }
}

private struct SweepButtonStyle: ButtonStyle {
    let kind: ButtonKind
    let hovering: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.f(Typo.sm, .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, Space.s100)
            .padding(.vertical, Space.s75)
            .background(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .shadow(color: kind == .primary && enabled ? Theme.accent.opacity(hovering ? 0.38 : 0.18) : .clear,
                    radius: hovering ? 10 : 4, y: hovering ? 3 : 2)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(enabled ? 1 : 0.55)
            .animation(reduceMotion ? .none : Motion.quick, value: hovering)
            .animation(reduceMotion ? .none : Motion.instant, value: configuration.isPressed)
    }

    private var foreground: Color {
        if !enabled { return Theme.textMuted }
        switch kind {
        case .primary: return Color.white
        case .secondary: return Theme.textPrimary
        case .quiet: return Theme.textSecondary
        case .danger: return Theme.accentDanger
        }
    }

    private var background: Color {
        if !enabled { return Theme.surfaceRaised }
        switch kind {
        case .primary:
            return hovering ? Theme.selection : Theme.actionFill
        case .secondary:
            return hovering ? Theme.surfaceHover : Theme.surface
        case .quiet:
            return hovering ? Theme.surfaceHover : Color.clear
        case .danger:
            return hovering ? Theme.accentDanger.opacity(0.16) : Theme.accentDangerSoft
        }
    }

    private var borderColor: Color {
        switch kind {
        case .primary: return Color.clear
        case .secondary: return Theme.border
        case .quiet: return Color.clear
        case .danger: return Theme.accentDanger.opacity(0.22)
        }
    }
}

extension SweepButton where Label == Text {
    init(_ kind: ButtonKind = .secondary, title: String, action: @escaping () -> Void) {
        self.init(kind, action: action) { Text(title) }
    }
}

extension SweepButton where Label == HStack<TupleView<(Image, Text)>> {
    init(_ kind: ButtonKind = .secondary, title: String, systemImage: String, action: @escaping () -> Void) {
        self.init(kind, action: action) {
            HStack(spacing: Space.s50) {
                Image(systemName: systemImage)
                Text(title)
            }
        }
    }
}

// MARK: - 容器与标题

/// 统一内容面板：与玻璃侧栏分层的清晰阅读表面。
/// 表面留一点点通透（0.94），让底下的环境光在页边泛出来；描边是左上偏蓝的渐变，
/// 比一圈死灰线更有一点“受光”的感觉。`lift` 用在统计与主操作卡片上，悬停时抬起来。
struct Panel<Content: View>: View {
    var padding: CGFloat = Space.s200
    var lift: Bool = false
    @ViewBuilder let content: () -> Content

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(padding: CGFloat = Space.s200, lift: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding
        self.lift = lift
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack {
                    // 磨砂底 + 一层自适应实色，兼顾通透和文字对比度
                    RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                        .fill(Theme.surface.opacity(0.55))
                    if lift {
                        RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Theme.accent.opacity(hovering ? 0.09 : 0.03), .clear],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Theme.accent.opacity(lift && hovering ? 0.35 : 0.18),
                                     Theme.border, Theme.border],
                            startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1)
            )
            .shadow(color: Theme.shadow, radius: hovering && lift ? 18 : 10, y: hovering && lift ? 8 : 3)
            .offset(y: hovering && lift ? -1.5 : 0)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? .none : Motion.quick, value: hovering)
    }
}

/// 页头：实色标题 + 说明 + 右侧操作。
struct PageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let actions: () -> Actions

    init(_ title: String, subtitle: String, @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions
    }

    var body: some View {
        HStack(alignment: .top, spacing: Space.s300) {
            VStack(alignment: .leading, spacing: Space.s75) {
                Text(title)
                    .font(Typo.f(Typo.xxl, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Typo.f(Typo.sm))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(3)
                    .frame(maxWidth: 680, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.s200)
            HStack(spacing: Space.s75) { actions() }
                .padding(.top, Space.s25)
        }
    }
}

/// 小节标题
struct GroupTitle: View {
    let text: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: Space.s75) {
            Text(text)
                .font(Typo.f(Typo.sm, .semibold))
                .foregroundStyle(Theme.textPrimary)
            if let trailing {
                Text(trailing)
                    .font(Typo.mono(Typo.xs))
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer()
        }
    }
}

// MARK: - 标签 / 指标 / 进度 / 状态

enum TagTone {
    case neutral, accent, warn, danger
}

struct Tag: View {
    let text: String
    var tone: TagTone = .neutral
    var icon: String? = nil

    var body: some View {
        HStack(spacing: Space.s25) {
            if let icon {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            }
            Text(text).font(Typo.f(Typo.xs, .medium))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, Space.s75)
        .padding(.vertical, Space.s25)
        .background(
            Capsule().fill(background)
        )
    }

    private var foreground: Color {
        switch tone {
        case .neutral: return Theme.textSecondary
        case .accent: return Theme.accent
        case .warn: return Theme.accentWarn
        case .danger: return Theme.accentDanger
        }
    }

    private var background: Color {
        switch tone {
        case .neutral: return Theme.surfaceRaised
        case .accent: return Theme.accentSoft
        case .warn: return Theme.accentWarnSoft
        case .danger: return Theme.accentDangerSoft
        }
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    var caption: String? = nil
    var tone: Color = Theme.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s50) {
            Text(title)
                .font(Typo.f(Typo.xs))
                .foregroundStyle(Theme.textSecondary)
            TickerText(text: value, font: Typo.f(Typo.xxl, .semibold), color: tone)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let caption {
                Text(caption)
                    .font(Typo.f(Typo.xs))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.s200)
        .background(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .fill(Theme.surfaceRaised)
                .overlay(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                        .fill(LinearGradient(colors: [tone.opacity(0.10), .clear],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                }
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(tone.opacity(0.12), lineWidth: 1)
        )
    }
}

struct ProgressBar: View {
    let value: Double        // 0...1
    var color: Color = Theme.accent
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceHover)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.65), color],
                            startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(width: max(geo.size.width * CGFloat(min(max(value, 0), 1)), value > 0 ? 4 : 0))
                    // 只留一层薄薄的外发光，半径过半就把下方的说明文字糊住了
                    .shadow(color: color.opacity(0.28), radius: max(1.5, height * 0.5), x: 0, y: 0)
            }
        }
        .frame(height: height)
        .animation(Motion.base, value: value)
    }
}

struct EmptyState<Action: View>: View {
    let icon: String
    let title: String
    let message: String
    @ViewBuilder let action: () -> Action

    init(icon: String, title: String, message: String, @ViewBuilder action: @escaping () -> Action = { EmptyView() }) {
        self.icon = icon
        self.title = title
        self.message = message
        self.action = action
    }

    var body: some View {
        VStack(spacing: Space.s100) {
            Image(systemName: icon)
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(Theme.accent)
                .frame(width: 60, height: 60)
                .background(
                    ZStack {
                        PulseHalo()
                        RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                            .fill(Theme.accentSoft)
                    }
                )
                .padding(.bottom, Space.s50)
            Text(title)
                .font(Typo.f(Typo.base, .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(Typo.f(Typo.sm))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
            action().padding(.top, Space.s50)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.s500)
    }
}

/// 骨架屏：形状与真实布局一致，一道高光缓慢扫过，不做转圈
struct Skeleton: View {
    var height: CGFloat = 12
    var width: CGFloat? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(Theme.surfaceHover)
                .overlay {
                    LinearGradient(colors: [.clear, .white.opacity(0.55), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.55)
                        .offset(x: sweep ? geo.size.width : -geo.size.width * 0.55)
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                        sweep = true
                    }
                }
        }
        .frame(width: width, height: height)
    }
}

/// 行悬停高亮
struct RowBackground: ViewModifier {
    var selected: Bool = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(selected ? Theme.accentSoft : (hovering ? Theme.surfaceRaised : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(selected ? Theme.accent.opacity(0.18) : .clear, lineWidth: 1)
            )
            .onHover { hovering = $0 }
            .animation(reduceMotion ? .none : Motion.quick, value: hovering)
    }
}

extension View {
    func rowBackground(selected: Bool = false) -> some View {
        modifier(RowBackground(selected: selected))
    }

    /// 页面统一留白与底色
    func pageSurface() -> some View {
        self.background(Theme.bg)
    }

    /// 细描边
    func hairline(_ color: Color = Theme.border) -> some View {
        overlay(Rectangle().fill(color).frame(height: 1), alignment: .bottom)
    }
}

// MARK: - 分段控件

struct SegmentedBar<Item: Hashable>: View {
    let items: [Item]
    let title: (Item) -> String
    @Binding var selection: Item

    var body: some View {
        HStack(spacing: Space.s25) {
            ForEach(items, id: \.self) { item in
                let active = item == selection
                Button {
                    withAnimation(Motion.quick) { selection = item }
                } label: {
                    Text(title(item))
                        .font(Typo.f(Typo.xs, .medium))
                        .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, Space.s100)
                        .padding(.vertical, Space.s50)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                                .fill(active ? Theme.surface : Color.clear)
                                .shadow(color: active ? Theme.shadow : .clear, radius: 2, y: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Space.s25)
        .background(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .fill(Theme.surfaceRaised)
        )
        .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Theme.border, lineWidth: 1))
    }
}

// MARK: - 共用格式化

func shortPath(_ path: String) -> String {
    path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
}

func ratioText(_ value: Double) -> String {
    String(format: "%.1f%%", value * 100)
}
