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
    /// 首次扫描后只自动勾选一次，之后保留用户自己的选择
    private var defaultsApplied = false
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

    func scan(keepMessage: Bool = false) {
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
        if !keepMessage { lastMessage = "正在检查已知缓存目录…" }
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
            // 首次扫描把「所有可清理项」勾上，而不是只勾 pip/SwiftPM 这类安全项：
            // 之前只勾推荐项，可清理 120 项里只勾中 2 项 17MB，用户点清理几乎看不出变化，
            // 以为功能坏了。缓存目录本身就是可再生的，默认全选更符合"腾空间"的预期。
            if !defaultsApplied {
                for index in self.items.indices {
                    self.items[index].selected = self.items[index].autoSelected
                }
                defaultsApplied = true
            }
            self.scanIssues = result.issues.map { "\($0.path)：\($0.message)" }
            self.progress = result.progress
            self.hasScanned = true
            let timing = String(format: "%.1f", result.elapsed)
            if keepMessage, let kept = self.lastMessage {
                self.lastMessage = kept
            } else if !self.scanIssues.isEmpty {
                self.lastMessage = "扫描完成（\(timing) 秒），\(self.scanIssues.count) 处读取受限；结果包含已读取的内容。"
            } else if self.items.isEmpty {
                self.lastMessage = "扫描完成（\(timing) 秒），已知缓存目录中没有发现候选。"
            } else {
                self.lastMessage = "扫描完成（\(timing) 秒）：\(self.items.count) 项，逻辑大小合计 \(self.totalSize.bytesText)。"
            }
            let autoPicked = self.items.filter(\.selected)
            OperationsLog.write("CLEAN SCAN items=\(self.items.count) issues=\(self.scanIssues.count) selected=\(autoPicked.count) selectedBytes=\(autoPicked.reduce(Int64(0)) { $0 + $1.size })")
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

    /// 勾上所有真正可清理的项（跳过被占用、只读、需要手动确认的）
    func selectAllEligible() {
        guard !busy else { return }
        for index in items.indices { items[index].selected = items[index].canSelect }
    }

    func deselectAll() {
        guard !busy else { return }
        for index in items.indices { items[index].selected = false }
    }

    /// 可选总量：让用户一眼看到"最多能清出多少"，而不是只看已勾选的 0 KB
    var selectableTotal: Int64 { items.filter(\.canSelect).reduce(0) { $0 + $1.size } }
    var selectableCount: Int { items.filter(\.canSelect).count }

    /// 勾选最大的若干项（用户显式点击才执行）
    func selectLargest(_ count: Int) {
        guard !busy else { return }
        let ranked = items.filter(\.canSelect).sorted { $0.size > $1.size }.prefix(count).map(\.id)
        for index in items.indices { items[index].selected = ranked.contains(items[index].id) }
    }

    /// 「一键清理」：没有勾选时自动勾上全部可清理项，让主按钮在任何情况下都有真实动作。
    @discardableResult
    func prepareForCleaning() -> [CacheItem] {
        guard !busy else { return [] }
        if selectedItems.isEmpty { selectAllEligible() }
        let picked = selectedItems
        if picked.isEmpty {
            lastMessage = items.isEmpty
                ? "没有可清理的候选：先点「重新扫描」，或展开扫描受限详情查看原因。"
                : "没有可勾选的缓存项：\(items.count) 项候选全部被系统占用或读取受限，详见「扫描受限详情」。"
        }
        return picked
    }

    /// 记录一次清理尝试，出问题时能直接对着日志查
    private func noteAttempt(_ items: [CacheItem]) {
        let bytes = items.reduce(Int64(0)) { $0 + $1.size }
        OperationsLog.write("CLEAN START items=\(items.count) logicalBytes=\(bytes)")
    }

    func cleanConfirmed(_ snapshot: [CacheItem]) {
        guard !busy else {
            lastMessage = "正在\(scanning ? "扫描" : "清理")，请等当前任务结束后再试。"
            OperationsLog.write("CLEAN IGNORED busy scanning=\(scanning) cleaning=\(cleaning)")
            return
        }
        guard !snapshot.isEmpty else {
            lastMessage = "没有勾选任何项目。"
            OperationsLog.write("CLEAN IGNORED empty-selection")
            return
        }
        guard snapshot.allSatisfy({ candidate in
            items.contains { $0.id == candidate.id && $0.selected && $0.canSelect && $0.snapshot == candidate.snapshot }
        }) else {
            lastMessage = "确认期间扫描结果发生了变化，已重新扫描；请确认后再次清理。"
            OperationsLog.write("CLEAN REJECT stale-snapshot n=\(snapshot.count)")
            scan()
            return
        }
        noteAttempt(snapshot)
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
            guard let self, self.cleanID == id else {
                OperationsLog.write("CLEAN ABORTED superseded")
                return
            }
            self.processMonitorTask = nil
            self.cleaning = false
            self.cleanTask = nil
            self.cleanToken = nil
            self.lastReport = report
            let removed = Set(report.outcomes.filter { $0.status == .removed }.map(\.path))
            self.items.removeAll { removed.contains($0.path) }
            OperationsLog.write("CLEAN RESULT removed=\(report.successfulCount) incomplete=\(report.outcomes.count - report.successfulCount) logicalBytes=\(report.removedBytes) cancelled=\(report.cancelled)")
            for outcome in report.outcomes where outcome.status != .removed {
                OperationsLog.write("CLEAN SKIP[\(outcome.status.rawValue)] \(outcome.path) :: \(outcome.message)")
            }
            OperationHistory.record(kind: .clean, summary: "缓存清理：成功 \(report.successfulCount) 项，未完成 \(report.outcomes.count - report.successfulCount) 项", bytes: report.removedBytes, count: report.successfulCount)
            // 报告卡在前，重新扫描在后：先给出这次动手的结论，再刷新候选。
            let incomplete = report.outcomes.count - report.successfulCount
            if report.successfulCount == 0 {
                let reason = report.outcomes.first?.message ?? "没有可执行的项目"
                self.lastMessage = "这次没有清理成功：\(reason)"
            } else {
                self.lastMessage = "已清理 \(report.successfulCount) 项，逻辑大小 \(report.removedBytes.bytesText)\(incomplete > 0 ? "；\(incomplete) 项保留（见下方逐项结果）" : "")。"
            }
            self.scan(keepMessage: true)
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
    @State private var leftovers: [SystemLeftover] = []
    @State private var leftoverMessage: String?
    @State private var leftoverBusy = false

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
            LazyVStack(alignment: .leading, spacing: Space.s200) {
                SectionTitle(title: "清理", subtitle: "查看已知缓存目录，按项选择后清理")
                summaryCard
                if !leftovers.isEmpty { systemLeftoverCard }
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
            .padding(Space.s300)
        }
        .onAppear {
            if !engine.hasScanned && !engine.scanning { engine.scan() }
            if leftovers.isEmpty && !leftoverBusy { reloadLeftovers() }
        }
        .onDisappear { engine.cancelScan() }
        .alert("永久清理所选缓存？", isPresented: $confirmClean) {
            Button("永久清理 \(confirmationItems.count) 项", role: .destructive) {
                engine.cleanConfirmed(confirmationItems)
                confirmationItems = []
            }
            Button("取消", role: .cancel) { confirmationItems = [] }
        } message: { Text(confirmationText) }
    }

    /// 按钮上看得到「点下去会发生什么」，避免点了没反应的错觉
    private var cleanButtonTitle: String {
        let picked = engine.selectedItems
        guard !picked.isEmpty else { return "全选并清理" }
        let bytes = picked.reduce(Int64(0)) { $0 + $1.size }
        return "清理 \(picked.count) 项 · \(bytes.bytesText)"
    }

    /// 家目录之外的大块占用：清理器不越界，只报告体积 + 逐项确认移除
    private var systemLeftoverCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.s100) {
                HStack {
                    Text("家目录之外的大块占用").font(Typo.f(Typo.sm, .semibold))
                    Spacer()
                    SweepButton(.quiet, title: leftoverBusy ? "检测中…" : "重新检测") { reloadLeftovers() }
                        .disabled(leftoverBusy)
                }
                Text("清理器只在你的主目录内工作，下面这些位置不会被自动清理。可移除的项目需要逐项确认，系统级项目会弹一次授权。")
                    .font(Typo.f(Typo.xs)).foregroundStyle(Theme.textMuted)
                ForEach(leftovers) { item in
                    HStack(alignment: .top, spacing: Space.s100) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(Typo.f(Typo.sm))
                            Text(item.detail).font(Typo.f(Typo.xs)).foregroundStyle(Theme.textMuted)
                            Text(item.path)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.textMuted)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Text(item.size.bytesText)
                            .font(Typo.f(Typo.sm, .medium)).monospacedDigit()
                        if item.isRemovable {
                            SweepButton(.quiet, title: item.needsAdmin ? "移除 · 需授权" : "移除") {
                                removeLeftover(item)
                            }
                            .disabled(leftoverBusy)
                        } else {
                            Text("系统自管").font(Typo.f(Typo.xs)).foregroundStyle(Theme.textMuted)
                        }
                    }
                    .padding(.vertical, Space.s50)
                    Divider().opacity(0.4)
                }
                if let leftoverMessage {
                    Text(leftoverMessage).font(Typo.f(Typo.xs)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func reloadLeftovers() {
        guard !leftoverBusy else { return }
        leftoverBusy = true
        leftoverMessage = nil
        DispatchQueue.global(qos: .utility).async {
            let items = SystemLeftovers.scan()
            DispatchQueue.main.async {
                leftovers = items
                leftoverBusy = false
                if items.isEmpty { leftoverMessage = "没有检测到家目录之外的大块残留。" }
            }
        }
    }

    private func removeLeftover(_ item: SystemLeftover) {
        leftoverBusy = true
        leftoverMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            var message: String
            do {
                try SystemLeftovers.remove(item)
                message = "已移除 \(item.title)（约 \(item.size.bytesText)）。"
                OperationsLog.write("LEFTOVER REMOVED \(item.path) bytes=\(item.size)")
            } catch {
                message = "未移除 \(item.title)：\(error.localizedDescription)"
            }
            let refreshed = SystemLeftovers.scan()
            DispatchQueue.main.async {
                leftovers = refreshed
                leftoverBusy = false
                leftoverMessage = message
            }
        }
    }

    private var confirmationText: String {
        let size = confirmationItems.reduce(Int64(0)) { $0 + $1.size }
        let names = confirmationItems.prefix(5).map { shortPath($0.path) }.joined(separator: "\n")
        let more = confirmationItems.count > 5 ? "\n另有 \(confirmationItems.count - 5) 项，均来自当前勾选。" : ""
        return "将永久删除 \(confirmationItems.count) 项缓存，逻辑大小估算 \(size.bytesText)，此操作不经过废纸篓。执行前会再次检查文件状态，变更或受限的项目会保留并报告。\n\n\(names)\(more)"
    }

    private var summaryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.s200) {
                HStack(alignment: .center, spacing: Space.s200) {
                    Image(systemName: "wind")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.white)
                        .frame(width: 60, height: 60)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                                .fill(LinearGradient(
                                    colors: [Color(hex: "#5C9BFF"), Color(hex: "#2A62DE")],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                                .overlay(
                                    RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                                        .strokeBorder(.white.opacity(0.35), lineWidth: 1))
                                .overlay(SheenOverlay(cornerRadius: Radius.xl, intensity: 0.5))
                                .shadow(color: Theme.accent.opacity(0.35), radius: 12, y: 5)
                        )
                    VStack(alignment: .leading, spacing: 5) {
                        Text("所选逻辑大小").font(Typo.f(Typo.xs)).foregroundStyle(Theme.textSecondary)
                        Text(engine.selectedTotal.sizeText)
                            .font(Typo.f(Typo.display, .semibold).monospacedDigit())
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color(hex: "#4C93FF"), Theme.accent, Color(hex: "#1D47B8")],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                            .shadow(color: Theme.accent.opacity(0.22), radius: 10, y: 4)
                            .animation(Motion.base, value: engine.selectedTotal)
                        Text("\(engine.selectedItems.count) 项已选 · 占用估算 \(engine.selectedAllocated.bytesText)")
                            .font(Typo.f(Typo.xs)).foregroundStyle(Theme.textSecondary)
                        Text("全部可选：\(engine.selectableCount) 项 · \(engine.selectableTotal.bytesText)")
                            .font(Typo.f(Typo.xs)).foregroundStyle(Theme.textMuted)
                    }
                    Spacer()
                    SweepButton(.secondary, title: "重新扫描", systemImage: "arrow.clockwise") { engine.scan() }
                        .disabled(engine.busy)
                    SweepButton(.primary, title: cleanButtonTitle, systemImage: "wind.snow") {
                        // 空选时自动勾上全部可清理项：主按钮永远有真实动作，不再出现“点了没反应”。
                        let picked = engine.prepareForCleaning()
                        guard !picked.isEmpty else { return }
                        confirmationItems = picked
                        confirmClean = true
                    }
                    .disabled(engine.busy)
                }
                Text(engine.selectedItems.isEmpty
                     ? "当前没有勾选项目：点主按钮会自动勾上全部可清理项，也可在下方逐项勾选。"
                     : "跨候选共享硬链接可能重复计入合计；APFS 克隆与快照也会影响实际释放空间。")
                    .font(Typo.f(Typo.xs)).foregroundStyle(Theme.textMuted)
            }
        }
    }

    private var selectionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    HStack(spacing: Space.s75) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.textMuted)
                        TextField("按名称或路径筛选", text: $search)
                            .textFieldStyle(.plain)
                    }
                    .font(Typo.f(Typo.sm))
                    .padding(.horizontal, Space.s100)
                    .padding(.vertical, Space.s75)
                    .background(RoundedRectangle(cornerRadius: Radius.md).fill(Theme.surfaceRaised))
                    .frame(maxWidth: 340)
                    Spacer()
                    SweepButton(.quiet, title: "全选可清理") { engine.selectAllEligible() }.disabled(engine.busy)
                    SweepButton(.quiet, title: "选最大 10 项") { engine.selectLargest(10) }.disabled(engine.busy)
                    SweepButton(.quiet, title: "全不选") { engine.deselectAll() }.disabled(engine.busy)
                }
                Text(search.isEmpty
                     ? "扫描完成后默认勾选全部可清理项；正在运行的应用缓存或扫描不完整的项目会保留。"
                     : "清理使用全部已勾选项，包含筛选结果之外的选择。")
                    .font(Typo.f(Typo.xs)).foregroundStyle(Theme.textSecondary)
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
            VStack(alignment: .leading, spacing: Space.s75) {
                HStack(spacing: Space.s100) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: Radius.md).fill(Theme.accentSoft))
                    VStack(alignment: .leading, spacing: Space.s25) {
                        Text(name).font(Typo.f(Typo.base, .semibold))
                        Text("\(items.count) 项 · \(items.reduce(Int64(0)) { $0 + $1.size }.sizeText)")
                            .font(Typo.f(Typo.xs)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    let eligible = items.filter(\.canSelect)
                    let allSelected = !eligible.isEmpty && eligible.allSatisfy(\.selected)
                    SweepButton(.quiet, title: allSelected ? "取消此组" : "选择此组") {
                        for item in eligible { engine.setSelected(item.id, !allSelected) }
                    }.disabled(engine.busy || eligible.isEmpty)
                }
                Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, Space.s50)
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
            .labelsHidden().toggleStyle(.checkbox).controlSize(.small).disabled(engine.busy || !item.canSelect)
            Image(systemName: item.canSelect ? "folder.fill" : "lock.fill")
                .font(.system(size: 13))
                .foregroundStyle(item.canSelect ? Theme.accent : Theme.textMuted)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: Radius.sm).fill(Theme.surfaceRaised))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).font(Typo.f(Typo.sm, .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if item.recommended && item.canSelect { Tag(text: "推荐", tone: .accent) }
                }
                Text(shortPath(item.path)).font(Typo.mono(Typo.xs)).foregroundStyle(Theme.textMuted)
                    .lineLimit(1).truncationMode(.middle)
                if let reason = item.reason {
                    Text(reason).font(Typo.f(Typo.xs))
                        .foregroundStyle(item.canSelect ? Theme.textSecondary : Theme.accentWarn)
                        .fixedSize(horizontal: false, vertical: true)
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
        .padding(.horizontal, Space.s75)
        .padding(.vertical, Space.s75)
        .rowBackground(selected: item.selected)
    }

    private func shortPath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
