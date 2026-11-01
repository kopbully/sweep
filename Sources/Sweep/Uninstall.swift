import SwiftUI
import AppKit

// MARK: - 数据模型

struct InstalledApp: Identifiable, Hashable {
    let id: String                  // = path
    let name: String                // 去掉 .app 的显示名
    let path: String
    let bundleID: String
    let version: String
    let size: Int64
    let lastModified: Date
    /// 所在目录不可写（多数是 /Applications 下的装机应用），删除时要过一次系统授权
    let needsAuth: Bool
}

struct AppObject: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let size: Int64
}

// MARK: - 引擎

final class UninstallEngine: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var loading = false
    @Published var selectedPaths: Set<String> = []
    @Published var leftoversForApp: [AppObject] = []
    @Published var leftoverAppName: String? = nil
    @Published var scanningLeftovers = false
    @Published var lastMessage: String? = nil
    @Published var lastMessageIsWarning = false

    private let lock = NSLock()

    /// 残留的候选目录：全部在用户域内，删除只需进废纸篓，不动系统目录
    static let leftoverDirs: [String] = [
        "Library/Application Support",
        "Library/Caches",
        "Library/Containers",
        "Library/Group Containers",
        "Library/Application Scripts",
        "Library/HTTPStorages",
        "Library/WebKit",
        "Library/Logs",
        "Library/Saved Application State",
        "Library/Preferences",
        "Library/Cookies",
        "Library/LaunchAgents",
    ]

    var selectedApps: [InstalledApp] { apps.filter { selectedPaths.contains($0.id) } }
    var totalSelected: Int64 { selectedApps.reduce(0) { $0 + $1.size } }
    var installedTotal: Int64 { apps.reduce(0) { $0 + $1.size } }

    // MARK: 选择

    func toggle(_ id: String) {
        if selectedPaths.contains(id) { selectedPaths.remove(id) } else { selectedPaths.insert(id) }
    }

    func selectAll(_ list: [InstalledApp]) {
        selectedPaths.formUnion(list.map(\.id))
    }

    func clearSelection() { selectedPaths.removeAll() }

    // MARK: 扫描

    func load() {
        guard !loading else { return }
        loading = true
        let ownPath = Bundle.main.bundlePath
        let ownID = Bundle.main.bundleIdentifier ?? "com.sweep.macos"

        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var bundles: [String] = []
            for root in ["/Applications", NSHomeDirectory() + "/Applications"] {
                guard let kids = try? fm.contentsOfDirectory(atPath: root) else { continue }
                for kid in kids.sorted() {
                    let full = root + "/" + kid
                    if kid.hasSuffix(".app") { bundles.append(full); continue }
                    // Utilities、厂商目录里再翻一层
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue,
                          let sub = try? fm.contentsOfDirectory(atPath: full) else { continue }
                    for s in sub.sorted() where s.hasSuffix(".app") { bundles.append(full + "/" + s) }
                }
            }

            var list: [InstalledApp] = []
            DispatchQueue.concurrentPerform(iterations: bundles.count) { i in
                let full = bundles[i]
                if let app = Self.inspect(path: full) {
                    self.lock.lock()
                    list.append(app)
                    self.lock.unlock()
                }
            }
            // 自己不能被列进卸载清单：删掉自己的进程正跑在它上面
            let cleaned = list.filter { $0.path != ownPath && $0.bundleID != ownID }

            DispatchQueue.main.async {
                self.apps = cleaned.sorted { $0.size > $1.size }
                self.selectedPaths = self.selectedPaths.filter { id in cleaned.contains { $0.id == id } }
                self.loading = false
            }
        }
    }

    /// 读取单个 .app 的元信息。为了验证脚本能复用，这里不做 private。
    static func inspect(path full: String) -> InstalledApp? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { return nil }

        var bundleID = ""
        var version = ""
        if let data = fm.contents(atPath: full + "/Contents/Info.plist"),
           let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            bundleID = (dict["CFBundleIdentifier"] as? String) ?? ""
            version = (dict["CFBundleShortVersionString"] as? String)
                ?? (dict["CFBundleVersion"] as? String) ?? ""
        }
        let attrs = try? fm.attributesOfItem(atPath: full)
        let modified = (attrs?[.modificationDate] as? Date) ?? .distantPast
        let parent = (full as NSString).deletingLastPathComponent
        let writable = fm.isWritableFile(atPath: parent)

        return InstalledApp(
            id: full,
            name: ((full as NSString).lastPathComponent as NSString).deletingPathExtension,
            path: full,
            bundleID: bundleID,
            version: version,
            size: Sizer.footprint(full),
            lastModified: modified,
            needsAuth: !writable
        )
    }

    // MARK: 残留

    func loadLeftovers(for app: InstalledApp) {
        leftoverAppName = app.name
        leftoversForApp = []
        scanningLeftovers = true
        DispatchQueue.global(qos: .userInitiated).async {
            let list = Self.findLeftovers(app: app)
            DispatchQueue.main.async {
                self.leftoversForApp = list
                self.scanningLeftovers = false
            }
        }
    }

    /// 残留匹配：Bundle ID 精确或按 `.` 分段；应用名只接受完全同名或以分隔符续写的目录，
    /// 避免 "Code" 命中 "Code Cache" 这类无辜目录
    static func matches(_ kid: String, bundleID: String, baseName: String) -> Bool {
        let k = kid.lowercased()
        let b = bundleID.lowercased()
        if b.count >= 4 {
            if k == b || k.hasPrefix(b + ".") || k.hasPrefix(b + "-") { return true }
        }
        let n = baseName.lowercased()
        guard n.count >= 3 else { return false }
        if k == n { return true }
        for sep in [".", " ", "-", "_"] where k.hasPrefix(n + sep) { return true }
        return false
    }

    static func findLeftovers(app: InstalledApp) -> [AppObject] {
        let baseName = (app.name as NSString).deletingPathExtension
        var found: [AppObject] = []
        var seen = Set<String>()
        for rel in leftoverDirs {
            let dir = NSHomeDirectory() + "/" + rel
            guard let kids = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for kid in kids where matches(kid, bundleID: app.bundleID, baseName: baseName) {
                let full = dir + "/" + kid
                guard seen.insert(full).inserted else { continue }
                // 0 字节的空目录/空 plist 也算残留：留着比清掉更碍事
                found.append(AppObject(path: full, size: Sizer.footprint(full)))
            }
        }
        return found.sorted { $0.size > $1.size }
    }

    // MARK: 卸载

    /// 卸载结果的账本
    struct Summary {
        var trashed = 0
        var adminRemoved = 0
        var failed: [String] = []
        var appBytes: Int64 = 0
        var leftoverCount = 0
        var leftoverBytes: Int64 = 0

        var total: Int64 { appBytes + leftoverBytes }
        var isWarning: Bool { adminRemoved > 0 || !failed.isEmpty }

        var message: String {
            var parts: [String] = []
            if trashed > 0 { parts.append("\(trashed) 个应用已进废纸篓，可恢复") }
            if adminRemoved > 0 { parts.append("\(adminRemoved) 个需要管理员授权，已永久删除") }
            if !failed.isEmpty {
                parts.append("\(failed.count) 个没能删掉：\(failed.prefix(2).joined(separator: "、"))")
            }
            if leftoverCount > 0 { parts.append("带走残留 \(leftoverCount) 项 · \(leftoverBytes.bytesText)") }
            return parts.isEmpty ? "没有需要处理的应用。" : parts.joined(separator: "；") + "。"
        }
    }

    /// 真正的删除动作，同步执行；调用方负责放到后台队列。
    /// 应用本体 → 废纸篓（可恢复）；目录不可写时退回一次管理员删除（不可恢复，界面上会说明）。
    /// 残留一律进废纸篓。
    static func perform(_ targets: [InstalledApp]) -> Summary {
        var s = Summary()

        for app in targets {
            if !app.bundleID.isEmpty {
                NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
                    .first?.terminate()
            }

            let url = URL(fileURLWithPath: app.path)
            var trashedURL: NSURL?
            if (try? FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)) != nil {
                if let destination = trashedURL as URL? { Remover.trashObserver?(app.path, destination) }
                s.trashed += 1
                s.appBytes += app.size
                OperationsLog.write("TRASH(app) \(app.path)")
            } else {
                do {
                    try Remover.adminRemove(app.path)
                    s.adminRemoved += 1
                    s.appBytes += app.size
                } catch {
                    s.failed.append(app.name)
                    OperationsLog.write("FAIL(uninstall) \(app.path): \(error.localizedDescription)")
                }
            }

            let leftovers = findLeftovers(app: app)
            guard !leftovers.isEmpty else { continue }
            let res = Remover.remove(leftovers.map(\.path), mode: .trash)
            s.leftoverCount += res.removed
            if res.removed > 0 { s.leftoverBytes += leftovers.reduce(0) { $0 + $1.size } }
        }

        // 记录写在 perform 里：UI 与验证脚本走的是同一条链路，历史才不会漏
        OperationHistory.record(kind: .uninstall,
                                summary: "卸载 \(targets.count) 个应用：\(targets.map(\.name).prefix(4).joined(separator: "、"))",
                                bytes: s.total,
                                count: targets.count)
        return s
    }

    func uninstallSelected() {
        guard !loading else { return }
        loading = true
        lastMessage = nil
        let targets = selectedApps

        DispatchQueue.global(qos: .userInitiated).async {
            let summary = Self.perform(targets)

            DispatchQueue.main.async {
                self.loading = false
                self.selectedPaths.removeAll()
                self.leftoversForApp = []
                self.leftoverAppName = nil
                self.lastMessage = summary.message
                self.lastMessageIsWarning = summary.isWarning
                self.load()
            }
        }
    }
}

// MARK: - 只读诊断
//
// SWEEP_UNINSTALL_PROBE=<.app 路径>：打印这台应用会被判定为残留的目录，不做任何删除。
// SWEEP_UNINSTALL_PROBE_APPLY=1：额外真的走一遍卸载（仅限 ~/Applications 下的应用），
// 用来在拿不到辅助功能权限的环境里核对匹配规则与删除链路。

enum UninstallDiagnostics {
    static func run(appPath: String, apply: Bool) {
        guard let app = UninstallEngine.inspect(path: appPath) else {
            print("PROBE: 不是 .app 包 — \(appPath)")
            return
        }
        print("PROBE app=\(app.name) bundle=\(app.bundleID) version=\(app.version) "
              + "size=\(app.size) needsAuth=\(app.needsAuth)")

        let leftovers = UninstallEngine.findLeftovers(app: app)
        print("PROBE leftovers=\(leftovers.count) bytes=\(leftovers.reduce(0) { $0 + $1.size })")
        for item in leftovers {
            print("PROBE   \(item.size)\t\(item.path)")
        }

        guard apply else { return }
        let userApps = NSHomeDirectory() + "/Applications/"
        guard app.path.hasPrefix(userApps) else {
            print("PROBE: 只对 \(userApps) 下的应用执行，已跳过")
            return
        }
        let summary = UninstallEngine.perform([app])
        print("PROBE applied trashed=\(summary.trashed) admin=\(summary.adminRemoved) "
              + "failed=\(summary.failed.count) leftovers=\(summary.leftoverCount) "
              + "bytes=\(summary.total)")
        print("PROBE message=\(summary.message)")
    }
}

// MARK: - 视图

struct UninstallView: View {
    @ObservedObject var engine: UninstallEngine
    @State private var search = ""
    @State private var confirmUninstall = false

    private var filtered: [InstalledApp] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return engine.apps }
        return engine.apps.filter {
            $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s200) {
                PageHeader("卸载", subtitle: "应用本体搬进废纸篓，顺手把散落的残留一起收走") {
                    SweepButton(.secondary, title: "刷新应用", systemImage: "arrow.clockwise") {
                        engine.load()
                    }
                    .disabled(engine.loading)
                }

                controls
                if let message = engine.lastMessage { resultPanel(message) }
                listPanel
                if engine.leftoverAppName != nil { leftoverPanel }
            }
            .padding(Space.s300)
        }
        .onAppear { if engine.apps.isEmpty && !engine.loading { engine.load() } }
        .alert("确认卸载？", isPresented: $confirmUninstall) {
            Button("卸载所选", role: .destructive) { engine.uninstallSelected() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(confirmText)
        }
    }

    private var confirmText: String {
        let names = engine.selectedApps.prefix(3).map(\.name).joined(separator: "、")
        let more = engine.selectedPaths.count > 3 ? "等 \(engine.selectedPaths.count) 个应用" : ""
        let auth = engine.selectedApps.contains { $0.needsAuth }
            ? "其中有应用位于受保护目录，会向你请求一次管理员授权。"
            : ""
        return "\(names)\(more)，合计 \(engine.totalSelected.bytesText)。应用本体与发现的残留都会移到废纸篓，可以随时恢复。\(auth)"
    }

    // MARK: 顶部统计与操作

    private var controls: some View {
        Panel(lift: true) {
            HStack(alignment: .center, spacing: Space.s300) {
                selectionGauge

                Rectangle().fill(Theme.border).frame(width: 1, height: 30)

                metric(title: "已装应用", value: "\(engine.apps.count) 个")
                metric(title: "合计占用", value: engine.installedTotal.sizeText)

                Spacer(minLength: Space.s200)

                SweepButton(.quiet, title: "全选", systemImage: "checkmark.circle") {
                    engine.selectAll(filtered)
                }
                .disabled(filtered.isEmpty || engine.loading)
                SweepButton(.quiet, title: "清空", systemImage: "xmark.circle") {
                    engine.clearSelection()
                }
                .disabled(engine.selectedPaths.isEmpty)
                SweepButton(.danger, title: "卸载所选", systemImage: "trash") {
                    confirmUninstall = true
                }
                .pulseGlow(engine.loading, color: Theme.accentDanger)
                .disabled(engine.selectedPaths.isEmpty || engine.loading)
            }
        }
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: Space.s25) {
            Text(title)
                .font(Typo.f(Typo.xs))
                .foregroundStyle(Theme.textSecondary)
            TickerText(text: value, font: Typo.f(Typo.sm, .semibold), color: Theme.textPrimary)
        }
        .fixedSize()
    }

    /// 已选占比：一圈渐变环 + 数字，比单行文字更能看出“要清掉多少”
    private var selectionGauge: some View {
        let ratio = engine.installedTotal > 0
            ? Double(engine.totalSelected) / Double(engine.installedTotal) : 0
        return HStack(spacing: Space.s100) {
            ZStack {
                GaugeRing(value: ratio, color: Theme.accent, lineWidth: 4.5)
                    .frame(width: 38, height: 38)
                Text("\(Int((ratio * 100).rounded()))%")
                    .font(Typo.f(Typo.xs, .semibold).monospacedDigit())
                    .foregroundStyle(ratio > 0 ? Theme.textPrimary : Theme.textMuted)
            }
            VStack(alignment: .leading, spacing: Space.s25) {
                Text("已选")
                    .font(Typo.f(Typo.xs))
                    .foregroundStyle(Theme.textSecondary)
                TickerText(text: "\(engine.selectedPaths.count) 个 · \(engine.totalSelected.sizeText)",
                           font: Typo.f(Typo.sm, .semibold),
                           color: Theme.textPrimary)
            }
        }
        .fixedSize()
    }

    private func resultPanel(_ message: String) -> some View {
        Panel {
            HStack(alignment: .top, spacing: Space.s100) {
                Image(systemName: engine.lastMessageIsWarning ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(engine.lastMessageIsWarning ? Theme.accentWarn : Theme.success)
                Text(message)
                    .font(Typo.f(Typo.xs))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: 列表

    private var listPanel: some View {
        Panel(padding: Space.s75) {
            HStack(spacing: Space.s75) {
                HStack(spacing: Space.s50) {
                    Image(systemName: "magnifyingglass")
                        .font(Typo.f(Typo.xs))
                        .foregroundStyle(Theme.textMuted)
                    TextField("按应用名或 Bundle ID 搜索", text: $search)
                        .textFieldStyle(.plain)
                        .font(Typo.f(Typo.xs))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 240)
                }
                .padding(.horizontal, Space.s75)
                .padding(.vertical, Space.s50)
                .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Theme.surfaceRaised))

                Spacer()

                if engine.loading {
                    HStack(spacing: Space.s50) {
                        ProgressView().controlSize(.small)
                        Text("正在读取应用与体积…")
                            .font(Typo.f(Typo.xs))
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    Text("\(filtered.count) 个应用")
                        .font(Typo.f(Typo.xs))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, Space.s100)
            .padding(.vertical, Space.s75)

            if engine.loading && engine.apps.isEmpty {
                VStack(alignment: .leading, spacing: Space.s100) {
                    ForEach(0..<6, id: \.self) { _ in
                        HStack(spacing: Space.s100) {
                            Skeleton(height: 24, width: 24)
                            VStack(alignment: .leading, spacing: Space.s50) {
                                Skeleton(height: 12, width: 160)
                                Skeleton(height: 10, width: 260)
                            }
                            Spacer()
                            Skeleton(height: 12, width: 64)
                        }
                    }
                }
                .padding(Space.s200)
            } else if filtered.isEmpty {
                EmptyState(icon: "xmark.bin",
                           title: engine.apps.isEmpty ? "没有找到可卸载的应用" : "没有匹配的应用",
                           message: engine.apps.isEmpty
                               ? "扫描范围是 /Applications 与 ~/Applications。"
                               : "换个关键词再试一次。")
                    .frame(height: 220)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, app in
                        row(app)
                            .staggerIn(index)
                        if index < filtered.count - 1 {
                            Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 40)
                        }
                    }
                }
            }
        }
    }

    private func row(_ app: InstalledApp) -> some View {
        let selected = engine.selectedPaths.contains(app.id)
        return HStack(spacing: Space.s100) {
            Button { engine.toggle(app.id) } label: {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Theme.accent : Theme.textMuted)
            }
            .buttonStyle(.plain)

            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .frame(width: 26, height: 26)
                .scaleEffect(selected ? 1.06 : 1)
                .animation(Motion.quick, value: selected)

            VStack(alignment: .leading, spacing: Space.s25) {
                HStack(spacing: Space.s75) {
                    Text(app.name)
                        .font(Typo.f(Typo.sm, .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if !app.version.isEmpty {
                        Text(app.version)
                            .font(Typo.f(Typo.xs))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceRaised))
                    }
                    if app.needsAuth { Tag(text: "需授权") }
                }
                Text(shortPath(app.path))
                    .font(Typo.mono(Typo.xs))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: Space.s100)

            Text(app.lastModified == .distantPast ? "—" : relativeDate(app.lastModified))
                .font(Typo.f(Typo.xs))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 78, alignment: .trailing)

            Text(app.size.bytesText)
                .font(Typo.mono(Typo.sm, .medium))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 84, alignment: .trailing)

            SweepButton(.quiet, title: "残留", systemImage: "doc.text.magnifyingglass") {
                engine.loadLeftovers(for: app)
            }
        }
        .padding(.horizontal, Space.s100)
        .padding(.vertical, Space.s75)
        .rowBackground(selected: selected)
        .contentShape(Rectangle())
        .onTapGesture { engine.toggle(app.id) }
    }

    private func shortPath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    // MARK: 残留预览

    private var leftoverPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: Space.s100) {
                HStack(spacing: Space.s75) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                    Text("\(engine.leftoverAppName ?? "") 的残留")
                        .font(Typo.f(Typo.base, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if engine.scanningLeftovers {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("\(engine.leftoversForApp.count) 项 · \(engine.leftoversForApp.reduce(0) { $0 + $1.size }.sizeText)")
                            .font(Typo.f(Typo.xs))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                if !engine.scanningLeftovers && engine.leftoversForApp.isEmpty {
                    Text("没有发现残留。应用可能直接写在容器里，或者之前已经清理过。")
                        .font(Typo.f(Typo.xs))
                        .foregroundStyle(Theme.textSecondary)
                }

                ForEach(engine.leftoversForApp) { item in
                    HStack(spacing: Space.s100) {
                        Image(systemName: "doc")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textMuted)
                        Text(shortPath(item.path))
                            .font(Typo.mono(Typo.xs))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: Space.s100)
                        Text(item.size.bytesText)
                            .font(Typo.mono(Typo.xs))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 72, alignment: .trailing)
                        SweepButton(.quiet, title: "显示") {
                            NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                        }
                    }
                    .padding(.vertical, 2)
                }

                Text("这些残留会在卸载时一起进废纸篓，不用单独操作。")
                    .font(Typo.f(Typo.xs))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.top, Space.s25)
            }
        }
    }
}
