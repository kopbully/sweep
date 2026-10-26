import SwiftUI
import AppKit

private final class CleanupRunningBundleIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var identifiers: Set<String>

    init(_ identifiers: Set<String>) { self.identifiers = identifiers }

    var current: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return identifiers
    }

    func update(_ identifiers: Set<String>) {
        lock.lock()
        self.identifiers = identifiers
        lock.unlock()
    }
}

private final class CleanupRunningProcessNames: @unchecked Sendable {
    private let lock = NSLock()
    private var names: Set<String>?

    init(_ names: Set<String>?) { self.names = names }

    var current: Set<String>? {
        lock.lock()
        defer { lock.unlock() }
        return names
    }

    func update(_ names: Set<String>?) {
        lock.lock()
        self.names = names
        lock.unlock()
    }
}

@MainActor
final class CleanEngine: ObservableObject {
    @Published private(set) var items: [CacheItem] = []
    @Published private(set) var scanning = false
    @Published private(set) var cleaning = false
    @Published private(set) var hasScanned = false
    @Published private(set) var progress: CleanupProgress?
    @Published private(set) var scanIssues: [String] = []
    @Published private(set) var lastMessage: String?
    @Published private(set) var lastReport: CleanupReport?

    private var scanID = UUID()
    private var cleanID = UUID()
    private var scanToken: CleanupCancellationToken?
    private var cleanToken: CleanupCancellationToken?
    private var scanTask: Task<Void, Never>?
    private var cleanTask: Task<Void, Never>?
    private var processMonitorTask: Task<Void, Never>?
    private let categories: [CleanCategory]
    private let home: String

    init(categories: [CleanCategory] = CleanCatalog.categories, home: String = NSHomeDirectory()) {
        self.categories = categories
        self.home = home
    }

    var busy: Bool { scanning || cleaning }
    var selectedItems: [CacheItem] { items.filter { $0.selected && $0.canSelect } }
    var selectedTotal: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var selectedAllocated: Int64 { selectedItems.reduce(0) { $0 + $1.allocatedSize } }
    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    func scan() {
        guard !busy else { return }
        let id = UUID()
        scanID = id
        let token = CleanupCancellationToken()
        scanToken = token
        let previous = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let running = runningBundleIDs()
        let categories = categories
        let home = home
        scanning = true
        progress = nil
        lastMessage = "正在检查已知缓存目录…"
        scanTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                CleanupScanner.scan(categories: categories, home: home, runningBundleIDs: running, cancellation: token) { info in
                    Task { @MainActor [weak self] in
                        guard let self, self.scanID == id, self.scanning else { return }
                        self.progress = info
                    }
                }
            }.value
            guard let self, self.scanID == id, !Task.isCancelled else { return }
            self.scanning = false
            self.scanTask = nil
            self.scanToken = nil
            if result.cancelled {
                self.lastMessage = "扫描已取消，保留上次完成的结果。"
                return
            }
            self.items = result.items.map { item in
                var updated = item
                if let old = previous[item.id], old.snapshot == item.snapshot, item.canSelect {
                    updated.selected = old.selected
                }
                return updated
            }
            self.scanIssues = result.issues.map { "\($0.path)：\($0.message)" }
            self.progress = result.progress
            self.hasScanned = true
            let timing = String(format: "%.1f", result.elapsed)
            if !self.scanIssues.isEmpty {
                self.lastMessage = "扫描完成（\(timing) 秒），\(self.scanIssues.count) 处读取受限；结果包含已读取的内容。"
            } else if self.items.isEmpty {
                self.lastMessage = "扫描完成（\(timing) 秒），已知缓存目录中没有发现候选。"
            } else {
                self.lastMessage = "扫描完成（\(timing) 秒）：\(self.items.count) 项，逻辑大小合计 \(self.totalSize.bytesText)。"
            }
            OperationsLog.write("CLEAN SCAN items=\(self.items.count) issues=\(self.scanIssues.count)")
        }
    }

    func cancelScan() {
        guard scanning else { return }
        scanToken?.cancel()
        scanTask?.cancel()
        scanID = UUID()
        scanning = false
        progress = nil
        lastMessage = "扫描已取消，保留上次完成的结果。"
    }

    func setSelected(_ id: String, _ selected: Bool) {
        guard !busy, let index = items.firstIndex(where: { $0.id == id }), items[index].canSelect else { return }
        items[index].selected = selected
    }

    func selectRecommended() {
        guard !busy else { return }
        for index in items.indices { items[index].selected = items[index].canSelect && items[index].recommended }
    }

    func deselectAll() {
        guard !busy else { return }
        for index in items.indices { items[index].selected = false }
    }

    func cleanConfirmed(_ snapshot: [CacheItem]) {
        guard !busy, !snapshot.isEmpty else { return }
        guard snapshot.allSatisfy({ candidate in
            items.contains { $0.id == candidate.id && $0.selected && $0.canSelect && $0.snapshot == candidate.snapshot }
        }) else {
            lastMessage = "选择或扫描结果已变化，请重新确认。"
            return
        }
        cleaning = true
        progress = nil
        let id = UUID()
        cleanID = id
        let token = CleanupCancellationToken()
        cleanToken = token
        let running = CleanupRunningBundleIDs(runningBundleIDs())
        let guardedTitles = Set(categories.filter { CleanupProcessActivity.guardedNames(for: $0.id) != nil }.map(\.title))
        let needsProcessMonitor = snapshot.contains { guardedTitles.contains($0.category) }
        let processNames = CleanupRunningProcessNames(needsProcessMonitor ? [] : nil)
        if needsProcessMonitor {
            processMonitorTask = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    processNames.update(CleanupProcessActivity.currentNames())
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        let categories = categories
        let home = home
        lastMessage = "正在重新检查 \(snapshot.count) 个所选目标…"
        let runningMonitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.cleanID == id, self.cleaning else { return }
                running.update(self.runningBundleIDs())
            }
        }
        let processMonitor = processMonitorTask
        cleanTask = Task { [weak self] in
            if needsProcessMonitor {
                let latest = await Task.detached(priority: .utility) {
                    CleanupProcessActivity.currentNames()
                }.value
                processNames.update(latest)
            }
            let report = await Task.detached(priority: .userInitiated) {
                CleanupExecutor.clean(items: snapshot, categories: categories, home: home,
                                      runningBundleIDs: running.current,
                                      runningBundleIDsProvider: { running.current },
                                      runningProcessNamesProvider: { processNames.current },
                                      cancellation: token, progress: { info in
                    Task { @MainActor [weak self] in
                        guard let self, self.cleanID == id, self.cleaning else { return }
                        self.progress = info
                    }
                })
            }.value
            runningMonitor.cancel()
            processMonitor?.cancel()
            guard let self, self.cleanID == id else { return }
            self.processMonitorTask = nil
            self.cleaning = false
            self.cleanTask = nil
            self.cleanToken = nil
            self.lastReport = report
            let removed = Set(report.outcomes.filter { $0.status == .removed }.map(\.path))
            self.items.removeAll { removed.contains($0.path) }
            OperationsLog.write("CLEAN RESULT removed=\(report.successfulCount) incomplete=\(report.outcomes.count - report.successfulCount) logicalBytes=\(report.removedBytes) cancelled=\(report.cancelled)")
            OperationHistory.record(kind: .clean, summary: "缓存清理：成功 \(report.successfulCount) 项，未完成 \(report.outcomes.count - report.successfulCount) 项", bytes: report.removedBytes, count: report.successfulCount)
            // Refresh candidates without replacing the completed operation report.
            self.scan()
        }
    }

    func cancelCleaning() {
        guard cleaning else { return }
        cleanToken?.cancel()
        lastMessage = "当前目标处理结束后停止后续清理。"
    }

    private func runningBundleIDs() -> Set<String> {
        var ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        ids.insert("com.sweep.macos")
        return ids
    }

    deinit {
        scanToken?.cancel()
        cleanToken?.cancel()
        scanTask?.cancel()
        processMonitorTask?.cancel()
    }
}

@MainActor
struct CleanView: View {
    @ObservedObject var engine: CleanEngine
    @State private var search = ""
    @State private var confirmClean = false
    @State private var confirmationItems: [CacheItem] = []

    private var filtered: [CacheItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return engine.items }
        return engine.items.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query) }
    }

    private var grouped: [(String, [CacheItem])] {
        let order = CleanCatalog.categories.map(\.title)
        return Dictionary(grouping: filtered, by: \.category)
            .sorted { a, b in
                let left = order.firstIndex(of: a.key) ?? Int.max
                let right = order.firstIndex(of: b.key) ?? Int.max
                return left == right ? a.key < b.key : left < right
            }
            .map { ($0.key, $0.value) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                SectionTitle(title: "清理", subtitle: "查看已知缓存目录，按项选择后清理")
                summaryCard
                if engine.busy { progressCard }
                if let report = engine.lastReport { resultCard(report) }
                if let message = engine.lastMessage {
                    Text(message).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                if !engine.scanIssues.isEmpty { issuesCard }
                selectionCard
                if filtered.isEmpty && !engine.busy {
                    Card {
                        Text(engine.items.isEmpty ? "没有可显示的缓存候选。扫描受限时可展开上方详情。" : "没有匹配的条目。")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 20)
                    }
                }
                ForEach(grouped, id: \.0) { category, items in categoryCard(category, items) }
            }
            .padding(20)
        }
        .background(Theme.bg)
        .onAppear { if !engine.hasScanned && !engine.scanning { engine.scan() } }
        .onDisappear { engine.cancelScan() }
        .alert("永久清理所选缓存？", isPresented: $confirmClean) {
            Button("永久清理 \(confirmationItems.count) 项", role: .destructive) {
                engine.cleanConfirmed(confirmationItems)
                confirmationItems = []
            }
            Button("取消", role: .cancel) { confirmationItems = [] }
        } message: { Text(confirmationText) }
    }

    private var confirmationText: String {
        let size = confirmationItems.reduce(Int64(0)) { $0 + $1.size }
        let names = confirmationItems.prefix(5).map { shortPath($0.path) }.joined(separator: "\n")
        let more = confirmationItems.count > 5 ? "\n另有 \(confirmationItems.count - 5) 项，均来自当前勾选。" : ""
        return "将永久删除 \(confirmationItems.count) 项缓存，逻辑大小估算 \(size.bytesText)，此操作不经过废纸篓。执行前会再次检查文件状态，变更或受限的项目会保留并报告。\n\n\(names)\(more)"
    }

    private var summaryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 20) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("所选逻辑大小").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        Text(engine.selectedTotal.sizeText)
                            .font(Typo.mono(Typo.xxl, .semibold)).foregroundStyle(Theme.accent)
                        Text("\(engine.selectedItems.count) 项已选 · 占用估算 \(engine.selectedAllocated.bytesText)")
                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    SweepButton(.secondary, title: "重新扫描", systemImage: "arrow.clockwise") { engine.scan() }
                        .disabled(engine.busy)
                    SweepButton(.primary, title: "清理所选", systemImage: "wind.snow") {
                        confirmationItems = engine.selectedItems
                        confirmClean = true
                    }
                    .disabled(engine.selectedItems.isEmpty || engine.busy)
                }
                Text("跨候选共享硬链接可能重复计入合计；APFS 克隆与快照也会影响实际释放空间。")
                    .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var selectionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    TextField("按名称或路径筛选", text: $search)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                    Spacer()
                    SweepButton(.quiet, title: "选择推荐项") { engine.selectRecommended() }.disabled(engine.busy)
                    SweepButton(.quiet, title: "全不选") { engine.deselectAll() }.disabled(engine.busy)
                }
                Text(search.isEmpty ? "默认不勾选；正在运行的应用缓存或扫描不完整的项目会保留。" : "清理使用全部已勾选项，包含筛选结果之外的选择。")
                    .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var progressCard: some View {
        Card {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text(engine.progress?.phase ?? (engine.scanning ? "正在扫描" : "正在检查并清理"))
                        .font(.system(size: 12, weight: .medium))
                    if let info = engine.progress {
                        Text("已检查 \(info.filesScanned) 个文件 · 目标 \(info.targetsCompleted)/\(info.targetsTotal)")
                            .font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                        Text(shortPath(info.currentPath)).font(.system(size: 10))
                            .foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                Button(engine.scanning ? "取消扫描" : "停止后续清理") {
                    if engine.scanning { engine.cancelScan() } else { engine.cancelCleaning() }
                }.buttonStyle(.bordered)
            }
        }
    }

    private func resultCard(_ report: CleanupReport) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                let incomplete = report.outcomes.count - report.successfulCount
                Text(report.cancelled ? "清理已停止" : (incomplete == 0 ? "清理完成" : "清理部分完成"))
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
                Text("成功 \(report.successfulCount) 项 · 未完成 \(incomplete) 项（其中已消失 \(report.missingCount) 项） · 逻辑大小 \(report.removedBytes.bytesText) · 磁盘回收估算 \(report.estimatedReclaimedBytes.bytesText)")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                DisclosureGroup("逐项结果（\(report.outcomes.count)）") {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(report.outcomes.enumerated()), id: \.offset) { _, outcome in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: outcome.status == .removed ? "checkmark.circle" : "info.circle")
                                    .foregroundStyle(outcome.status == .removed ? Theme.accent : Theme.accentWarn)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(shortPath(outcome.path)).lineLimit(2).truncationMode(.middle)
                                    Text(outcome.message).foregroundStyle(Theme.textSecondary)
                                }.font(.system(size: 10))
                            }
                        }
                    }.padding(.top, 7)
                }.font(.system(size: 11))
            }
        }
    }

    private var issuesCard: some View {
        Card {
            DisclosureGroup("扫描受限详情（\(engine.scanIssues.count)）") {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(engine.scanIssues.enumerated()), id: \.offset) { _, issue in
                        Text(shortPath(issue)).font(.system(size: 10)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                    }
                }.padding(.top, 7)
            }.font(.system(size: 12)).foregroundStyle(Theme.accentWarn)
        }
    }

    private func categoryCard(_ name: String, _ items: [CacheItem]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(name).font(.system(size: 14, weight: .semibold))
                    Text("\(items.count) 项 · \(items.reduce(Int64(0)) { $0 + $1.size }.sizeText)")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    let eligible = items.filter(\.canSelect)
                    let allSelected = !eligible.isEmpty && eligible.allSatisfy(\.selected)
                    SweepButton(.quiet, title: allSelected ? "取消此组" : "选择此组") {
                        for item in eligible { engine.setSelected(item.id, !allSelected) }
                    }.disabled(engine.busy || eligible.isEmpty)
                }
                LazyVStack(spacing: 4) { ForEach(items) { item in itemRow(item) } }
            }
        }
    }

    private func itemRow(_ item: CacheItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("选择 \(item.name)", isOn: Binding(
                get: { engine.items.first { $0.id == item.id }?.selected ?? false },
                set: { engine.setSelected(item.id, $0) }
            ))
            .labelsHidden().controlSize(.mini).disabled(engine.busy || !item.canSelect)
            Image(systemName: item.canSelect ? "folder.fill" : "lock.fill")
                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary).padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).font(Typo.f(Typo.sm, .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if item.recommended && item.canSelect { Tag(text: "推荐", tone: .accent) }
                }
                Text(shortPath(item.path)).font(Typo.mono(Typo.xs)).foregroundStyle(Theme.textMuted)
                    .lineLimit(1).truncationMode(.middle)
                if let reason = item.reason {
                    Text(reason).font(Typo.f(Typo.xs)).foregroundStyle(Theme.accentWarn).fixedSize(horizontal: false, vertical: true)
                }
                if item.hasExternalHardLinks {
                    Text("包含共享硬链接，移除后释放量可能较少").font(Typo.f(Typo.xs)).foregroundStyle(Theme.textMuted)
                }
            }
            Spacer(minLength: 8)
            SweepButton(.quiet, title: "显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            }
            VStack(alignment: .trailing, spacing: 3) {
                Text(item.size.sizeText).font(Typo.mono(Typo.sm, .medium))
                Text("占用 \(item.allocatedSize.sizeText)").font(Typo.f(Typo.xs)).foregroundStyle(Theme.textMuted)
            }.frame(width: 92, alignment: .trailing)
        }
        .padding(.vertical, 5)
    }

    private func shortPath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
