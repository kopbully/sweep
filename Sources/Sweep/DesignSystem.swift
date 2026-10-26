import SwiftUI
import AppKit

// MARK: - 视觉令牌
//
// 取值来源：elayadesign/ai-design-skills 的 landing-page-design 视觉系统。
// 暗色底板只允许 #000000 / #181818 / #1F1F1F / #272727 / #313131 五档，
// 背景不做渐变（渐变只用于标题文字），动效只作用于透明度与位移，
// 圆角遵守嵌套公式 inner = outer - gap。

enum Theme {
    // 底板
    static let bg = Color(hex: "#000000")
    static let surface = Color(hex: "#181818")
    static let surfaceRaised = Color(hex: "#1F1F1F")
    static let surfaceHover = Color(hex: "#272727")
    static let border = Color(hex: "#313131")

    // 文字
    static let textPrimary = Color(hex: "#F5F5F5")
    static let textSecondary = Color(hex: "#9B9B9B")
    static let textMuted = Color(hex: "#6B6B6B")

    // 强调色（品牌绿，沿用既有识别色）
    static let accent = Color(hex: "#3ECF8E")
    static let accentSoft = Color(hex: "#3ECF8E").opacity(0.10)
    static let accentWarn = Color(hex: "#E8A33D")
    static let accentWarnSoft = Color(hex: "#E8A33D").opacity(0.14)
    static let accentDanger = Color(hex: "#E25B5B")
    static let accentDangerSoft = Color(hex: "#E25B5B").opacity(0.14)

    // 兼容既有调用点
    static let card = surface
    static let cardBorder = border

    static func healthColor(_ score: Double) -> Color {
        if score >= 80 { return accent }
        if score >= 50 { return accentWarn }
        return accentDanger
    }

    static func usageColor(_ percent: Double) -> Color {
        if percent >= 90 { return accentDanger }
        if percent >= 80 { return accentWarn }
        return accent
    }

    /// 标题渐变：暗色主题下由 #FFFFFF 过渡到 #9B9B9B，只作用于文字
    static var titleGradient: LinearGradient {
        LinearGradient(colors: [Color(hex: "#FFFFFF"), Color(hex: "#9B9B9B")],
                       startPoint: .leading, endPoint: .trailing)
    }
}

/// 字号阶梯：12 / 14 / 16 / 18 / 20 / 24 / 30
enum Typo {
    static let xs: CGFloat = 12
    static let sm: CGFloat = 14
    static let base: CGFloat = 16
    static let lg: CGFloat = 18
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let display: CGFloat = 30

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

// MARK: - 按钮

enum ButtonKind {
    case primary
    case secondary
    case quiet
    case danger
}

struct SweepButton<Label: View>: View {
    let kind: ButtonKind
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var pressed = false

    init(_ kind: ButtonKind = .secondary, action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.kind = kind
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            label()
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
                .scaleEffect(pressed ? 0.98 : 1)
                .opacity(enabled ? 1 : 0.7)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? .none : Motion.quick, value: hovering)
        .animation(reduceMotion ? .none : Motion.instant, value: pressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }

    private var foreground: Color {
        if !enabled { return Theme.textMuted }
        switch kind {
        case .primary: return Color.black
        case .secondary: return Theme.textPrimary
        case .quiet: return Theme.textSecondary
        case .danger: return Theme.textPrimary
        }
    }

    private var background: Color {
        if !enabled { return Theme.surfaceRaised }
        switch kind {
        case .primary:
            return hovering ? Theme.accent.opacity(0.86) : Theme.accent
        case .secondary:
            return hovering ? Theme.surfaceHover : Theme.surface
        case .quiet:
            return hovering ? Theme.surfaceHover : Color.clear
        case .danger:
            return hovering ? Theme.accentDanger.opacity(0.24) : Theme.accentDangerSoft
        }
    }

    private var borderColor: Color {
        switch kind {
        case .primary: return Color.clear
        case .secondary: return Theme.border
        case .quiet: return Color.clear
        case .danger: return Theme.accentDanger.opacity(0.5)
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

/// 统一面板：平底、四周描边、16 圆角
struct Panel<Content: View>: View {
    var padding: CGFloat = Space.s200
    @ViewBuilder let content: () -> Content

    init(padding: CGFloat = Space.s200, @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
    }
}

/// 页头：渐变标题 + 说明 + 右侧操作
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
                    .foregroundStyle(Theme.titleGradient)
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
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(background)
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
            Text(value)
                .font(Typo.mono(Typo.xl, .semibold))
                .foregroundStyle(tone)
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
                    .fill(color)
                    .frame(width: max(geo.size.width * CGFloat(min(max(value, 0), 1)), value > 0 ? 4 : 0))
            }
        }
        .frame(height: height)
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
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.textMuted)
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

/// 骨架屏：形状与真实布局一致，不做转圈
struct Skeleton: View {
    var height: CGFloat = 12
    var width: CGFloat? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .fill(Theme.surfaceHover)
            .frame(width: width, height: height)
            .opacity(pulse ? 0.55 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
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
                                .fill(active ? Theme.surfaceHover : Color.clear)
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
    }
}

// MARK: - 共用格式化

func shortPath(_ path: String) -> String {
    path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
}

func ratioText(_ value: Double) -> String {
    String(format: "%.1f%%", value * 100)
}
