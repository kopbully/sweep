import SwiftUI
import AppKit
import CryptoKit

// MARK: - 模型

struct DuplicateFile: Identifiable, Hashable {
    let id: String          // path
    let path: String
    let name: String
    let size: Int64
    let modified: Date?
}

struct DuplicateGroup: Identifiable, Hashable {
    let id: String          // size + 摘要
    let size: Int64
    let files: [DuplicateFile]

    var wasted: Int64 { size * Int64(max(files.count - 1, 0)) }
    /// 默认保留修改时间最早、路径最短的那一份
    var keeper: DuplicateFile? {
        files.min {
            if $0.modified != $1.modified { return ($0.modified ?? .distantFuture) < ($1.modified ?? .distantFuture) }
            return $0.path.count < $1.path.count
        }
    }
}

enum DuplicateMinimum: Int64, CaseIterable, Identifiable {
    case mb1 = 1_048_576
    case mb10 = 10_485_760
    case mb100 = 104_857_600

    var id: Int64 { rawValue }

    var title: String {
        switch self {
        case .mb1: return "1 MB"
        case .mb10: return "10 MB"
        case .mb100: return "100 MB"
        }
    }
}

// MARK: - 扫描器

enum DuplicateScanner {
    private struct Meta {
        let path: String
        let size: Int64
        let modified: Date?
    }

    static func scan(minSize: Int64,
                     roots: [String] = [NSHomeDirectory()],
                     cancellation: CleanupCancellationToken,
                     progress: @Sendable (String, Int, Int) -> Void) -> [DuplicateGroup] {
        let metas = collect(minSize: minSize, roots: roots, cancellation: cancellation) { done, total in
            progress("枚举文件", done, total)
        }
        if cancellation.isCancelled { return [] }

        // 只有同尺寸的文件才可能重复，先按大小分桶
        let bySize = Dictionary(grouping: metas, by: \.size).filter { $0.value.count > 1 }
        let candidates = bySize.values.flatMap { $0 }
        guard !candidates.isEmpty else { return [] }

        progress("初步比对", 0, candidates.count)
        let quick = parallelHash(candidates, cancellation: cancellation, limit: 65_536) { done in
            progress("初步比对", done, candidates.count)
        }
        if cancellation.isCancelled { return [] }

        var pool: [String: [Int]] = [:]
        for (index, meta) in candidates.enumerated() {
            guard let digest = quick[index] else { continue }
            pool["\(meta.size)-\(digest)", default: []].append(index)
        }

        // 摘要相同的再做整文件校验，避免哈希前缀撞车造成误删
        var verified: [(size: Int64, digest: String, indices: [Int])] = []
        let suspects = pool.filter { $0.value.count > 1 }
        let suspectFiles = suspects.values.flatMap { $0 }
        progress("精确校验", 0, suspectFiles.count)
        let full = parallelHash(suspectFiles.map { candidates[$0] },
                                cancellation: cancellation, limit: nil) { done in
            progress("精确校验", done, suspectFiles.count)
        }
        if cancellation.isCancelled { return [] }

        var fullPool: [String: [Int]] = [:]
        for (offset, index) in suspectFiles.enumerated() {
            guard let digest = full[offset] else { continue }
            let meta = candidates[index]
            fullPool["\(meta.size)-\(digest)", default: []].append(index)
        }
        for (key, indices) in fullPool where indices.count > 1 {
            let parts = key.split(separator: "-", maxSplits: 1)
            let size = Int64(parts.first ?? "0") ?? 0
            verified.append((size, String(parts.last ?? ""), indices))
        }

        progress("整理结果", 1, 1)
        return verified.map { item in
            let files = item.indices.map { candidates[$0] }.map {
                DuplicateFile(id: $0.path, path: $0.path,
                              name: ($0.path as NSString).lastPathComponent,
                              size: $0.size, modified: $0.modified)
            }.sorted { $0.path < $1.path }
            return DuplicateGroup(id: "\(item.size)-\(item.digest)", size: item.size, files: files)
        }
        .sorted { $0.wasted > $1.wasted }
    }

    private static func collect(minSize: Int64,
                                roots: [String],
                                cancellation: CleanupCancellationToken,
                                tick: @Sendable (Int, Int) -> Void) -> [Meta] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
                                      .isDirectoryKey, .isSymbolicLinkKey]
        let excluded = Set(LargeFileScanner.exclusions.map { ($0 as NSString).standardizingPath })
        var metas: [Meta] = []
        var visited = 0
        for root in roots {
        guard let en = fm.enumerator(at: URL(fileURLWithPath: root),
                                     includingPropertiesForKeys: keys,
                                     options: [.skipsHiddenFiles]) else { continue }
        while let url = en.nextObject() as? URL {
            if cancellation.isCancelled { return metas }
            let std = (url.path as NSString).standardizingPath
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if excluded.contains(std) { en.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            visited += 1
            if visited % 500 == 0 { tick(visited, 0) }
            guard let size = values?.fileSize, Int64(size) >= minSize else { continue }
            metas.append(Meta(path: std, size: Int64(size), modified: values?.contentModificationDate))
        }
        }
        tick(visited, 0)
        return metas
    }

    /// limit 为 nil 时对整文件做 SHA256，否则只读首尾各 limit 字节
    private static func parallelHash(_ files: [Meta],
                                     cancellation: CleanupCancellationToken,
                                     limit: Int?,
                                     progress: @Sendable (Int) -> Void) -> [String?] {
        var results = [String?](repeating: nil, count: files.count)
        let lock = NSLock()
        var done = 0
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            if cancellation.isCancelled { return }
            let digest = hash(files[index], limit: limit)
            lock.lock()
            results[index] = digest
            done += 1
            let current = done
            lock.unlock()
            if current % 24 == 0 { progress(current) }
        }
        progress(files.count)
        return results
    }

    private static func hash(_ meta: Meta, limit: Int?) -> String? {
        guard let handle = FileHandle(forReadingAtPath: meta.path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        if let limit, meta.size > Int64(limit * 2) {
            guard let head = try? handle.read(upToCount: limit) else { return nil }
            hasher.update(data: head)
            if (try? handle.seek(toOffset: UInt64(meta.size - Int64(limit)))) != nil,
               let tail = try? handle.read(upToCount: limit) {
                hasher.update(data: tail)
            }
        } else {
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 引擎

@MainActor
final class DuplicatesEngine: ObservableObject {
    @Published var minimum: DuplicateMinimum = .mb1
    @Published private(set) var groups: [DuplicateGroup] = []
    @Published private(set) var selected: Set<String> = []
    @Published private(set) var scanning = false
    @Published private(set) var hasScanned = false
    @Published private(set) var phase = ""
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var message: String?

    private var task: Task<Void, Never>?
    private var token: CleanupCancellationToken?

    var groupCount: Int { groups.count }
    var duplicateCount: Int { groups.reduce(0) { $0 + $1.files.count } }
    var wasted: Int64 { groups.reduce(0) { $0 + $1.wasted } }
    var selectedBytes: Int64 {
        let all = groups.flatMap(\.files)
        return all.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    func scan() {
        guard !scanning else { return }
        let minSize = minimum.rawValue
        let token = CleanupCancellationToken()
        self.token = token
        scanning = true
        phase = "枚举文件"
        completed = 0
        total = 0
        selected = []
        message = "正在按大小分组，随后逐字节校验。"
        task = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                DuplicateScanner.scan(minSize: minSize, cancellation: token) { phase, done, all in
                    Task { @MainActor [weak self] in
                        guard let self, self.scanning else { return }
                        self.phase = phase
                        self.completed = done
                        self.total = all
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
            self.groups = result
            self.selected = Set(result.flatMap { group in
                group.files.filter { $0.id != group.keeper?.id }.map(\.id)
            })
            self.message = result.isEmpty
                ? "没有发现重复文件。"
                : "发现 \(result.count) 组重复，可释放约 \(self.wasted.bytesText)。默认保留每组最早的一份。"
            OperationsLog.write("DUP SCAN groups=\(result.count) min=\(minSize)")
        }
    }

    func cancel() {
        token?.cancel()
        task?.cancel()
        scanning = false
        message = "扫描已停止，保留上次结果。"
    }

    func toggle(_ path: String) {
        if selected.contains(path) { selected.remove(path) } else { selected.insert(path) }
    }

    func isKeeper(_ file: DuplicateFile, in group: DuplicateGroup) -> Bool {
        group.keeper?.id == file.id
    }

    func trashSelected() {
        let paths = Array(selected)
        guard !paths.isEmpty else { return }
        let bytes = selectedBytes
        let result = Remover.remove(paths, mode: .trash)
        let removed = Set(paths.filter { !FileManager.default.fileExists(atPath: $0) })
        groups = groups.compactMap { group in
            let left = group.files.filter { !removed.contains($0.path) }
            guard left.count > 1 else { return nil }
            return DuplicateGroup(id: group.id, size: group.size, files: left)
        }
        selected = selected.subtracting(removed)
        message = "已移入废纸篓 \(result.removed) 个副本，约 \(bytes.bytesText)；\(result.failed) 个被跳过。"
        OperationHistory.record(kind: .duplicate,
                                summary: "重复文件清理：移除 \(result.removed) 个副本",
                                bytes: bytes, count: result.removed)
    }

    func reveal(_ file: DuplicateFile) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
    }
}

// MARK: - 视图

struct DuplicatesView: View {
    @StateObject private var engine = DuplicatesEngine()
    @State private var confirmTrash = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s300) {
                PageHeader("重复文件", subtitle: "先按大小分桶，再比对首尾摘要，最后整文件校验。只有内容完全一致的文件才会被归为一组，默认保留每组修改时间最早的一份。") {
                    if engine.scanning {
                        SweepButton(.secondary, title: "停止", systemImage: "stop") { engine.cancel() }
                    } else {
                        SweepButton(.primary, title: "开始查找", systemImage: "doc.on.doc") { engine.scan() }
                    }
                }

                controls
                if engine.scanning { progressPanel }
                if let message = engine.message {
                    Text(message).font(Typo.f(Typo.xs)).foregroundStyle(Theme.textSecondary)
                }
                results
            }
            .padding(Space.s300)
        }
        .pageSurface()
        .onDisappear { engine.cancel() }
        .alert("移除所选副本？", isPresented: $confirmTrash) {
            Button("移入废纸篓", role: .destructive) { engine.trashSelected() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将移走 \(engine.selected.count) 个副本，约 \(engine.selectedBytes.bytesText)。每组至少保留一份，文件进入废纸篓可恢复。")
        }
    }

    private var controls: some View {
        Panel {
            HStack(spacing: Space.s200) {
                VStack(alignment: .leading, spacing: Space.s50) {
                    Text("最小体积").font(Typo.f(Typo.xs)).foregroundStyle(Theme.textSecondary)
                    SegmentedBar(items: DuplicateMinimum.allCases,
                                 title: { $0.title },
                                 selection: $engine.minimum)
                }
                Spacer()
                MetricSummary(title: "重复组", value: "\(engine.groupCount)")
                MetricSummary(title: "可释放", value: engine.wasted.sizeText)
                SweepButton(.danger, title: "移除所选副本", systemImage: "trash") {
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
                    Text(engine.phase).font(Typo.f(Typo.sm, .medium)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(engine.total > 0 ? "\(engine.completed) / \(engine.total)" : "\(engine.completed)")
                        .font(Typo.mono(Typo.xs)).foregroundStyle(Theme.textSecondary)
                }
                ProgressBar(value: engine.total > 0 ? Double(engine.completed) / Double(engine.total) : 0.15)
                Text("整文件校验会读取全部内容，大文件较多时需要一些时间。")
                    .font(Typo.f(Typo.xs)).foregroundStyle(Theme.textMuted)
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        if engine.groups.isEmpty {
            Panel {
                if engine.scanning {
                    EmptyState(icon: "doc.on.doc",
                               title: "正在比对",
                               message: "先按大小分桶，再读取内容做精确校验。")
                } else if engine.hasScanned {
                    EmptyState(icon: "doc.on.doc",
                               title: "没有发现重复文件",
                               message: "不低于 \(engine.minimum.title) 的文件里，没有内容完全一致的副本。")
                } else {
                    EmptyState(icon: "doc.on.doc",
                               title: "还没有开始查找",
                               message: "整文件校验需要读取内容，不会自动开始。确认门槛后点击开始查找，过程中随时可以停止。") {
                        SweepButton(.primary, title: "开始查找", systemImage: "magnifyingglass") {
                            engine.scan()
                        }
                    }
                }
            }
        } else {
            ForEach(engine.groups) { group in
                groupPanel(group)
            }
        }
    }

    private func groupPanel(_ group: DuplicateGroup) -> some View {
        Panel(padding: Space.s75) {
            VStack(spacing: 0) {
                HStack(spacing: Space.s75) {
                    Text("\(group.files.count) 份相同内容")
                        .font(Typo.f(Typo.sm, .semibold)).foregroundStyle(Theme.textPrimary)
                    Tag(text: "每份 \(group.size.bytesText)", tone: .neutral)
                    Tag(text: "可省 \(group.wasted.bytesText)", tone: .accent)
                    Spacer()
                }
                .padding(.horizontal, Space.s100)
                .padding(.vertical, Space.s75)

                ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                    fileRow(file, group: group)
                    if index < group.files.count - 1 {
                        Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 28)
                    }
                }
            }
        }
    }

    private func fileRow(_ file: DuplicateFile, group: DuplicateGroup) -> some View {
        let keeper = engine.isKeeper(file, in: group)
        return HStack(spacing: Space.s100) {
            if keeper {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 14)
            } else {
                Button { engine.toggle(file.id) } label: {
                    Image(systemName: engine.selected.contains(file.id) ? "checkmark.square.fill" : "square")
                        .font(.system(size: 13))
                        .foregroundStyle(engine.selected.contains(file.id) ? Theme.accent : Theme.textMuted)
                }
                .buttonStyle(.plain)
                .frame(width: 14)
            }
            VStack(alignment: .leading, spacing: Space.s25) {
                HStack(spacing: Space.s50) {
                    Text(file.name).font(Typo.f(Typo.sm, .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if keeper { Tag(text: "保留", tone: .accent) }
                }
                Text(shortPath(file.path))
                    .font(Typo.mono(Typo.xs)).foregroundStyle(Theme.textMuted)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: Space.s100)
            Text(file.modified.map(relativeDate) ?? "—")
                .font(Typo.f(Typo.xs)).foregroundStyle(Theme.textSecondary)
            SweepButton(.quiet, title: "显示", action: { engine.reveal(file) })
        }
        .padding(.horizontal, Space.s100)
        .padding(.vertical, Space.s75)
        .rowBackground(selected: !keeper && engine.selected.contains(file.id))
    }
}
