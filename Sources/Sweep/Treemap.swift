import SwiftUI

// MARK: - 矩形树图布局（squarified treemap）

enum TreemapLayout {
    /// 输入已按权重降序排列，输出与输入等长的矩形
    static func squarify(weights: [Double], in rect: CGRect) -> [CGRect] {
        var out = [CGRect](repeating: .zero, count: weights.count)
        guard !weights.isEmpty, rect.width > 0, rect.height > 0 else { return out }
        let total = weights.reduce(0, +)
        guard total > 0 else { return out }
        let scale = (rect.width * rect.height) / total
        let areas = weights.map { $0 * scale }

        var work = rect
        var index = 0
        while index < areas.count {
            let side = min(work.width, work.height)
            guard side > 0.5 else { break }

            var row: [Int] = []
            var rowSum = 0.0
            var best = Double.infinity
            var cursor = index
            while cursor < areas.count {
                let candidateSum = rowSum + areas[cursor]
                let rowLength = candidateSum / side
                guard rowLength > 0 else { break }
                var worst = 0.0
                for j in row + [cursor] {
                    let itemSide = areas[j] / rowLength
                    guard itemSide > 0 else { continue }
                    worst = max(worst, max(itemSide / rowLength, rowLength / itemSide))
                }
                if worst <= best {
                    best = worst
                    rowSum = candidateSum
                    row.append(cursor)
                    cursor += 1
                } else {
                    break
                }
            }
            guard !row.isEmpty else { break }

            let rowLength = rowSum / side
            var offset = 0.0
            let horizontalStrip = work.width >= work.height
            for j in row {
                let itemSide = areas[j] / rowLength
                if horizontalStrip {
                    out[j] = CGRect(x: work.minX, y: work.minY + offset,
                                    width: rowLength, height: itemSide)
                } else {
                    out[j] = CGRect(x: work.minX + offset, y: work.minY,
                                    width: itemSide, height: rowLength)
                }
                offset += itemSide
            }
            if horizontalStrip {
                work = CGRect(x: work.minX + rowLength, y: work.minY,
                              width: max(work.width - rowLength, 0), height: work.height)
            } else {
                work = CGRect(x: work.minX, y: work.minY + rowLength,
                              width: work.width, height: max(work.height - rowLength, 0))
            }
            index = cursor
        }
        return out
    }
}

struct TreemapTile: Identifiable {
    let id: String
    let entry: DiskEntry?
    let label: String
    /// 实际占用：块面积与显示都以它为准
    let size: Int64
    /// 逻辑长度比实际占用多出的部分（稀疏文件），只用于提示
    let inflated: Int64
    let rect: CGRect
}

// MARK: - 矩形树图

struct TreemapView: View {
    let entries: [DiskEntry]
    var onSelect: (DiskEntry) -> Void
    var onReveal: (DiskEntry) -> Void = { _ in }
    var onTrash: (DiskEntry) -> Void = { _ in }
    @State private var hovered: String?
    @State private var appeared = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let rects = TreemapLayout.squarify(weights: weights, in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(baseTiles.enumerated()), id: \.element.id) { index, tile in
                    let rect = index < rects.count ? rects[index] : .zero
                    tileView(tile, rect: rect, index: index)
                }
            }
            .onAppear {
                guard !reduceMotion else { appeared = true; return }
                withAnimation(Motion.base) { appeared = true }
            }
        }
        .frame(height: 520)
        // 换一层目录就换一批块，用 id 重建来重播入场动画
        .id(signature)
    }

    /// 只取条目数与首项路径：足以区分「换了一层」，又不会因为体积抖动反复重建
    private var signature: String { "\(entries.count)-\(entries.first?.path ?? "")" }

    private var baseTiles: [TreemapTile] {
        // 纯稀疏条目占用为 0，也要留在图里（面积按最小权重给一点），否则会凭空消失
        let sorted = entries.filter { $0.size > 0 || $0.footprint > 0 }
            .sorted { $0.footprint > $1.footprint }
        let head = Array(sorted.prefix(24))
        let tail = sorted.dropFirst(24)
        var out = head.map {
            TreemapTile(id: $0.id, entry: $0, label: $0.name,
                        size: $0.footprint, inflated: $0.inflated, rect: .zero)
        }
        if !tail.isEmpty {
            out.append(TreemapTile(id: "__rest", entry: nil,
                                   label: "其他 \(tail.count) 项",
                                   size: tail.reduce(Int64(0)) { $0 + $1.footprint },
                                   inflated: tail.reduce(Int64(0)) { $0 + $1.inflated },
                                   rect: .zero))
        }
        return out
    }

    private var weights: [Double] {
        baseTiles.map { Double(max($0.size, 1)) }
    }

    @ViewBuilder
    private func tileView(_ tile: TreemapTile, rect: CGRect, index: Int) -> some View {
        let isHovered = hovered == tile.id
        let dimmed = hovered != nil && !isHovered
        let color = color(for: tile, index: index)
        let scale = (appeared ? 1 : 0.9) * (isHovered ? 1.04 : 1)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(color)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .strokeBorder(isHovered ? Color.white.opacity(0.9) : Theme.bg.opacity(0.6),
                                      lineWidth: isHovered ? 2 : 1)
                )
                .shadow(color: isHovered ? Color.black.opacity(0.18) : .clear,
                        radius: isHovered ? 4 : 0, x: 0, y: isHovered ? 1 : 0)
            if rect.width > 72 && rect.height > 30 {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tile.label)
                        .font(Typo.f(Typo.xs, .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(rect.height > 62 ? 2 : 1)
                    if rect.height > 54 {
                        Text(tile.size.bytesText)
                            .font(Typo.mono(Typo.xs))
                            .foregroundStyle(Theme.textPrimary.opacity(isHovered ? 0.9 : 0.72))
                    }
                }
                .padding(.horizontal, Space.s75)
                .padding(.vertical, Space.s50)
            }
        }
        .frame(width: max(rect.width - 2, 0), height: max(rect.height - 2, 0))
        .offset(x: rect.minX + 1, y: rect.minY + 1)
        .scaleEffect(scale)
        .opacity(appeared ? (dimmed ? 0.5 : 1) : 0)
        .zIndex(isHovered ? 2 : 1)
        .onHover { hovering in
            withAnimation(Motion.quick) { hovered = hovering ? tile.id : nil }
        }
        .onTapGesture {
            if let entry = tile.entry { onSelect(entry) }
        }
        .contextMenu {
            if let entry = tile.entry {
                if entry.isDirectory { Button("进入") { onSelect(entry) } }
                Button("在访达中显示") { onReveal(entry) }
                Divider()
                Button("移入废纸篓…", role: .destructive) { onTrash(entry) }
            }
        }
        .help(tile.inflated > 0
              ? "\(tile.label) · 占用 \(tile.size.bytesText)（逻辑长度 \((tile.size + tile.inflated).bytesText)）"
              : "\(tile.label) · \(tile.size.bytesText)")
        .animation(reduceMotion ? .none : Motion.quick, value: hovered)
        .animation(reduceMotion ? .none : Motion.base.delay(Double(min(index, 20)) * 0.02),
                   value: appeared)
    }

    /// 青 → 蓝 → 紫的色相环，比单一强调色的透明度阶梯更容易分辨相邻块
    private static let hues: [Double] = [0.50, 0.58, 0.66, 0.54, 0.70, 0.62, 0.47, 0.68]

    private func color(for tile: TreemapTile, index: Int) -> Color {
        guard tile.entry != nil else { return Theme.surfaceHover }
        // 深浅外观分别控制明度，保证小字号名称在区块上仍可读。
        let ramp: [Double] = colorScheme == .dark
            ? [0.60, 0.52, 0.45, 0.40, 0.35, 0.31, 0.28, 0.25]
            : [0.94, 0.88, 0.82, 0.76, 0.71, 0.66, 0.62, 0.58]
        let slot = index % Self.hues.count
        return Color(hue: Self.hues[slot],
                     saturation: colorScheme == .dark ? 0.44 : 0.38,
                     brightness: ramp[index % ramp.count])
    }
}
