import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 模型与扫描

struct LargeFileItem: Identifiable, Hashable {
    let id: String          // path
    let path: String
    let name: String
    let size: Int64
    let modified: Date?
    let typeLabel: String
}

enum LargeSizeThreshold: Int64, CaseIterable, Identifiable {
    case mb100 = 104_857_600
    case mb500 = 524_288_000
    case gb1 = 1_073_741_824
    case gb5 = 5_368_709_120

    var id: Int64 { rawValue }

    var title: String {
        switch self {
        case .mb100: return "100 MB"
        case .mb500: return "500 MB"
        case .gb1: return "1 GB"
        case .gb5: return "5 GB"
        }
    }
}

enum LargeFileScanner {
    /// 这些目录由「清理」模块负责，重复列出来只会造成误删
    static var exclusions: [String] {
        let home = NSHomeDirectory()
        return [
            home + "/Library/Caches",
            home + "/Library/Logs",
            home + "/Library/Containers",
            home + "/.Trash",
        ]
    }

    /// 包类型目录跳过内部文件，避免把 .app 里的资源当成用户文件
    private static let packageExtensions: Set<String> = [
        "app", "framework", "bundle", "xcodeproj", "xcworkspace",
        "photoslibrary", "fcpbundle", "imovielibrary", "tvlibrary",
        "logicx", "band", "sparsebundle",
    ]

    static func scan(roots: [String], minSize: Int64,
                     cancellation: CleanupCancellationToken,
                     progress: @Sendable (Int, String, [LargeFileItem]) -> Void) -> [LargeFileItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey,
            .contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey, .contentTypeKey,
        ]
        var found: [LargeFileItem] = []
        var visited = 0
        let excluded = Set(exclusions.map { ($0 as NSString).standardizingPath })

        for root in roots {
            guard let en = fm.enumerator(at: URL(fileURLWithPath: root),
                                         includingPropertiesForKeys: keys,
                                         options: [.skipsHiddenFiles]) else { continue }
            while let url = en.nextObject() as? URL {
                if cancellation.isCancelled { return found }
                let std = (url.path as NSString).standardizingPath
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    if excluded.contains(std) || packageExtensions.contains(url.pathExtension.lowercased()) {
                        en.skipDescendants()
                    }
                    continue
                }
                guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
                visited += 1
                // 边扫边给结果，避免用户长时间盯着空列表
                if visited % 2000 == 0 {
                    progress(visited, std, Array(found.sorted { $0.size > $1.size }.prefix(200)))
                }
                guard let size = values?.fileSize, Int64(size) >= minSize else { continue }
                let typeLabel: String
                if let type = values?.contentType {
                    typeLabel = type.localizedDescription ?? type.identifier
                } else {
                    typeLabel = url.pathExtension.isEmpty ? "文件" : url.pathExtension.uppercased()
                }
                found.append(LargeFileItem(
                    id: std,
                    path: std,
                    name: url.lastPathComponent,
                    size: Int64(size),
                    modified: values?.contentModificationDate,
                    typeLabel: typeLabel
                ))
            }
        }
        progress(visited, "", Array(found.sorted { $0.size > $1.size }.prefix(400)))
        return Array(found.sorted { $0.size > $1.size }.prefix(400))
    }
}

// MARK: - 引擎

@MainActor
final class LargeFilesEngine: ObservableObject {
    @Published var threshold: LargeSizeThreshold = .mb500
    @Published private(set) var items: [LargeFileItem] = []
    @Published private(set) var selected: Set<String> = []
    @Published private(set) var scanning = false
    @Published private(set) var hasScanned = false
    @Published private(set) var filesVisited = 0
    @Published private(set) var currentPath = ""
    @Published private(set) var message: String?
    @Published var search = ""

    private var task: Task<Void, Never>?
    private var token: CleanupCancellationToken?

    var totalSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var selectedItems: [LargeFileItem] { items.filter { selected.contains($0.id) } }
    var overallSize: Int64 { items.reduce(0) { $0 + $1.size } }

    var filtered: [LargeFileItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query)
        }
    }

    func scan() {
        guard !scanning else { return }
        let minSize = threshold.rawValue
        let token = CleanupCancellationToken()
        self.token = token
        scanning = true
        filesVisited = 0
        currentPath = ""
        selected = []
        message = "正在按大小过滤 \(threshold.title) 以上的文件…"
        let roots = [NSHomeDirectory()]
        task = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                LargeFileScanner.scan(roots: roots, minSize: minSize, cancellation: token) { visited, path, partial in
                    Task { @MainActor [weak self] in
                        guard let self, self.scanning else { return }
                        self.filesVisited = visited
                        self.currentPath = path
                        if !partial.isEmpty { self.items = partial }
                    }
                }
            }.value
            guard let self else { return }
            self.scanning = false
            self.hasScanned = true
            self.token = nil
            guard !token.isCancelled else {
                self.message = "扫描已停止，保留上次结果。"
                return
            }
            self.items = result
            self.message = result.isEmpty
                ? "没有超过 \(self.threshold.title) 的单文件。可以调低门槛再看一次。"
                : "找到 \(result.count) 个文件，合计 \(self.overallSize.bytesText)。"
            OperationsLog.write("LARGE SCAN min=\(minSize) found=\(result.count) visited=\(self.filesVisited)")
        }
    }

    func cancel() {
        token?.cancel()
        task?.cancel()
        scanning = false
        message = "扫描已停止，保留上次结果。"
    }

    func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    func selectAllVisible() {
        selected = Set(filtered.map(\.id))
    }

    func clearSelection() { selected = [] }

    func trashSelected() {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        let bytes = targets.reduce(Int64(0)) { $0 + $1.size }
        let result = Remover.remove(targets.map(\.path), mode: .trash)
        // 以文件是否仍然存在为准，避免失败项被误当作已移除
        let survivors = Set(targets.filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.id))
        items.removeAll { !survivors.contains($0.id) }
        selected = []
        message = "已移入废纸篓 \(result.removed) 个文件，约 \(bytes.bytesText)；\(result.failed) 个因权限被跳过。"
        OperationHistory.record(kind: .largeFile,
                                summary: "大文件清理：移入废纸篓 \(result.removed) 个文件",
                                bytes: bytes, count: result.removed)
    }

    func reveal(_ item: LargeFileItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }
}

// MARK: - 视图

struct LargeFilesView: View {
    @StateObject private var engine = LargeFilesEngine()
    @State private var confirmTrash = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s300) {
                PageHeader("大文件", subtitle: "按体积找出单个文件，而不是目录。只统计 \(thresholdHint) 以上的普通文件，隐藏目录与本机缓存不在范围内。") {
                    if engine.scanning {
                        SweepButton(.secondary, title: "停止", systemImage: "stop") { engine.cancel() }
                    } else {
                        SweepButton(.primary, title: "开始扫描", systemImage: "magnifyingglass") { engine.scan() }
                            .pulseGlow(engine.items.isEmpty)
                    }
                }

                controls
                if engine.scanning { progressPanel }
                if let message = engine.message {
                    Text(message).font(Typo.f(Typo.xs)).foregroundStyle(Theme.textSecondary)
                }
                listPanel
            }
            .padding(Space.s300)
        }
        .pageSurface()
        .onAppear { if !engine.hasScanned && !engine.scanning { engine.scan() } }
        .onDisappear { engine.cancel() }
        .alert("把所选文件移入废纸篓？", isPresented: $confirmTrash) {
            Button("移入废纸篓", role: .destructive) { engine.trashSelected() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("共 \(engine.selectedItems.count) 个文件，合计 \(engine.totalSize.bytesText)。文件会进入废纸篓，可以恢复；系统盘受保护路径不会被处理。")
        }
    }

    private var thresholdHint: String {
        engine.threshold.title
    }

    private var controls: some View {
        Panel {
            HStack(spacing: Space.s200) {
                VStack(alignment: .leading, spacing: Space.s50) {
                    Text("体积门槛").font(Typo.f(Typo.xs)).foregroundStyle(Theme.textSecondary)
                    SegmentedBar(items: LargeSizeThreshold.allCases,
                                 title: { $0.title },
                                 selection: $engine.threshold)
                }
                Spacer()
                MetricSummary(title: "匹配文件", value: "\(engine.items.count)")
                MetricSummary(title: "合计", value: engine.overallSize.sizeText)
                SweepButton(.secondary, title: "全选", systemImage: "checkmark.circle") {
                    engine.selectAllVisible()
                }
                .disabled(engine.filtered.isEmpty || engine.scanning)
                SweepButton(.danger, title: "移入废纸篓", systemImage: "trash") {
                    confirmTrash = true
                }
                .disabled(engine.selected.isEmpty || engine.scanning)
            }
        }
    }

    private var progressPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: Space.s100) {
                HStack {
                    Text("正在遍历文件").font(Typo.f(Typo.sm, .medium)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("已检查 \(engine.filesVisited) 个文件")
                        .font(Typo.mono(Typo.xs)).foregroundStyle(Theme.textSecondary)
                }
                ProgressBar(value: 0.35, color: Theme.accent) // 遍历总量未知，展示活动态
                Text(shortPath(engine.currentPath))
                    .font(Typo.mono(Typo.xs)).foregroundStyle(Theme.textMuted)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: Space.s100) {
                    Skeleton(height: 10, width: 180)
                    Skeleton(height: 10, width: 120)
                }
            }
        }
    }

    @ViewBuilder
    private var listPanel: some View {
        Panel(padding: Space.s75) {
            HStack(spacing: Space.s75) {
                HStack(spacing: Space.s50) {
                    Image(systemName: "magnifyingglass").font(Typo.f(Typo.xs)).foregroundStyle(Theme.textMuted)
                    TextField("按文件名或路径筛选", text: $engine.search)
                        .textFieldStyle(.plain)
                        .font(Typo.f(Typo.xs))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 240)
                }
                .padding(.horizontal, Space.s75)
                .padding(.vertical, Space.s50)
                .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Theme.surfaceRaised))
                Spacer()
                if !engine.selected.isEmpty {
                    Text("已选 \(engine.selected.count) 项 · \(engine.totalSize.bytesText)")
                        .font(Typo.f(Typo.xs)).foregroundStyle(Theme.textSecondary)
                    SweepButton(.quiet, title: "清空选择", action: { engine.clearSelection() })
                }
            }
            .padding(.horizontal, Space.s100)
            .padding(.vertical, Space.s75)

            if engine.scanning && engine.items.isEmpty {
                VStack(alignment: .leading, spacing: Space.s100) {
                    ForEach(0..<5, id: \.self) { _ in
                        HStack(spacing: Space.s100) {
                            Skeleton(height: 12, width: 14)
                            VStack(alignment: .leading, spacing: Space.s50) {
                                Skeleton(height: 12, width: 180)
                                Skeleton(height: 10, width: 320)
                            }
                            Spacer()
                            Skeleton(height: 12, width: 60)
                        }
                    }
                }
                .padding(Space.s200)
            } else if engine.filtered.isEmpty {
                EmptyState(icon: "doc.zipper",
                           title: engine.items.isEmpty ? "没有超过门槛的文件" : "没有匹配的文件",
                           message: engine.items.isEmpty
                               ? "把门槛调低一档，或者点开始扫描重新统计。缓存类文件请去「清理」模块。"
                               : "换个关键词再试一次。").frame(height: 220)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(engine.filtered.enumerated()), id: \.element.id) { index, item in
                        row(item)
                            .staggerIn(index)
                        if index < engine.filtered.count - 1 {
                            Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 28)
                        }
                    }
                }
            }
        }
    }

    private func row(_ item: LargeFileItem) -> some View {
        HStack(spacing: Space.s100) {
            Button { engine.toggle(item.id) } label: {
                Image(systemName: engine.selected.contains(item.id) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(engine.selected.contains(item.id) ? Theme.accent : Theme.textMuted)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: Space.s25) {
                Text(item.name)
                    .font(Typo.f(Typo.sm, .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(shortPath(item.path))
                    .font(Typo.mono(Typo.xs))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: Space.s100)
            Tag(text: item.typeLabel)
            Text(item.modified.map(relativeDate) ?? "—")
                .font(Typo.f(Typo.xs)).foregroundStyle(Theme.textSecondary)
                .frame(width: 80, alignment: .trailing)
            Text(item.size.bytesText)
                .font(Typo.mono(Typo.sm, .medium))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 88, alignment: .trailing)
            SweepButton(.quiet, title: "显示", action: { engine.reveal(item) })
        }
        .padding(.horizontal, Space.s100)
        .padding(.vertical, Space.s75)
        .rowBackground(selected: engine.selected.contains(item.id))
    }
}

/// 小指标，用于面板右上角
struct MetricSummary: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .trailing, spacing: Space.s25) {
            Text(title).font(Typo.f(Typo.xs)).foregroundStyle(Theme.textSecondary)
            TickerText(text: value, font: Typo.f(Typo.sm, .semibold), color: Theme.textPrimary)
        }
    }
}
