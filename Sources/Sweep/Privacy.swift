import SwiftUI
import AppKit

// MARK: - 模型

enum PrivacyRisk {
    case safe       // 只是缓存，删除后自动重建
    case loseHistory
    case signOut    // Cookie 被清掉，需要重新登录

    var title: String {
        switch self {
        case .safe: return "安全"
        case .loseHistory: return "丢记录"
        case .signOut: return "会退出登录"
        }
    }

    var tone: TagTone {
        switch self {
        case .safe: return .accent
        case .loseHistory: return .warn
        case .signOut: return .danger
        }
    }
}

struct PrivacyItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let risk: PrivacyRisk
    let group: String
    let glyph: String
    let paths: [String]
    var clearsClipboard: Bool = false
}

enum PrivacyCatalog {
    /// 目录存在才展示，避免列出一堆不存在的浏览器
    static func items(home: String = NSHomeDirectory()) -> [PrivacyItem] {
        let fm = FileManager.default
        var out: [PrivacyItem] = []

        func exists(_ path: String) -> Bool { fm.fileExists(atPath: path) }

        func profiles(_ base: String) -> [String] {
            guard let kids = try? fm.contentsOfDirectory(atPath: base) else { return [] }
            return kids.filter { $0 == "Default" || $0.hasPrefix("Profile ") }
                .sorted { a, b in
                    if a == "Default" { return true }
                    if b == "Default" { return false }
                    return a.localizedStandardCompare(b) == .orderedAscending
                }
                .map { base + "/" + $0 }
        }

        // Chromium 系：Chrome / Edge / Brave / Arc / Chromium
        let chromium: [(String, String)] = [
            ("Google Chrome", home + "/Library/Application Support/Google/Chrome"),
            ("Microsoft Edge", home + "/Library/Application Support/Microsoft Edge"),
            ("Brave", home + "/Library/Application Support/BraveSoftware/Brave-Browser"),
            ("Arc", home + "/Library/Application Support/Arc/User Data"),
            ("Chromium", home + "/Library/Application Support/Chromium"),
        ]

        for (name, base) in chromium where exists(base) {
            let dirs = profiles(base)
            guard !dirs.isEmpty else { continue }
            let cacheFiles = dirs.flatMap { dir in
                ["Cache", "Code Cache", "GPUCache", "DawnCache", "GrShaderCache", "Service Worker/CacheStorage"]
                    .map { dir + "/" + $0 }
            }
            out.append(PrivacyItem(
                id: "\(name)-cache", title: "\(name) 缓存",
                detail: "网页图片、脚本与着色器缓存，删除后首次打开网页会稍慢一点。",
                risk: .safe, group: "浏览器", glyph: "globe", paths: cacheFiles))
            out.append(PrivacyItem(
                id: "\(name)-history", title: "\(name) 浏览记录",
                detail: "地址栏历史、常访问站点与自动补全记录。",
                risk: .loseHistory, group: "浏览器", glyph: "clock", paths: dirs.flatMap { dir in
                    ["History", "History-journal", "Top Sites", "Visited Links", "Favicons"].map { dir + "/" + $0 }
                }))
            out.append(PrivacyItem(
                id: "\(name)-cookies", title: "\(name) Cookie 与登录状态",
                detail: "清掉之后所有网站都要重新登录，网站偏好也会重置。",
                risk: .signOut, group: "浏览器", glyph: "person.crop.circle.badge.xmark", paths: dirs.flatMap { dir in
                    [dir + "/Cookies", dir + "/Network/Cookies"]
                }))
        }

        // Safari
        let safariCaches = [
            home + "/Library/Caches/com.apple.Safari",
            home + "/Library/Containers/com.apple.Safari/Data/Library/Caches",
        ]
        if safariCaches.contains(where: exists) {
            out.append(PrivacyItem(
                id: "safari-cache", title: "Safari 缓存",
                detail: "网页快照与资源缓存，重建代价很低。",
                risk: .safe, group: "浏览器", glyph: "safari", paths: safariCaches))
        }
        let safariSites = [
            home + "/Library/Safari/History.db",
            home + "/Library/Safari/History.db-wal",
            home + "/Library/Safari/History.db-shm",
            home + "/Library/Containers/com.apple.Safari/Data/Library/Safari/History.db",
        ]
        if safariSites.contains(where: exists) {
            out.append(PrivacyItem(
                id: "safari-history", title: "Safari 浏览记录",
                detail: "访问历史与最近关闭的标签页。",
                risk: .loseHistory, group: "浏览器", glyph: "clock", paths: safariSites))
        }
        let safariCookies = [
            home + "/Library/Containers/com.apple.Safari/Data/Library/Cookies",
            home + "/Library/Cookies/Cookies.binarycookies",
        ]
        if safariCookies.contains(where: exists) {
            out.append(PrivacyItem(
                id: "safari-cookies", title: "Safari Cookie 与登录状态",
                detail: "清掉之后需要重新登录各网站。",
                risk: .signOut, group: "浏览器", glyph: "person.crop.circle.badge.xmark", paths: safariCookies))
        }

        // Firefox
        let firefoxRoot = home + "/Library/Application Support/Firefox/Profiles"
        if let kids = try? fm.contentsOfDirectory(atPath: firefoxRoot), !kids.isEmpty {
            let dirs = kids.map { firefoxRoot + "/" + $0 }
            out.append(PrivacyItem(
                id: "firefox-cache", title: "Firefox 缓存",
                detail: "cache2 与启动缓存。",
                risk: .safe, group: "浏览器", glyph: "flame", paths: dirs.flatMap { dir in
                    [dir + "/cache2", dir + "/startupCache", dir + "/shader-cache"]
                }))
            out.append(PrivacyItem(
                id: "firefox-history", title: "Firefox 浏览记录",
                detail: "places.sqlite 保存的历史与书签访问记录。",
                risk: .loseHistory, group: "浏览器", glyph: "clock", paths: dirs.map { $0 + "/places.sqlite" }))
            out.append(PrivacyItem(
                id: "firefox-cookies", title: "Firefox Cookie 与登录状态",
                detail: "清掉之后需要重新登录各网站。",
                risk: .signOut, group: "浏览器", glyph: "person.crop.circle.badge.xmark", paths: dirs.map { $0 + "/cookies.sqlite" }))
        }

        // 系统痕迹
        out.append(PrivacyItem(
            id: "recent", title: "最近使用项目",
            detail: "访达与各应用共享的最近文件列表。",
            risk: .loseHistory, group: "系统", glyph: "clock.arrow.circlepath",
            paths: [home + "/Library/Application Support/com.apple.sharedfilelist"]))
        out.append(PrivacyItem(
            id: "crash", title: "崩溃与诊断报告",
            detail: "应用崩溃日志，排查完就可以清掉。",
            risk: .safe, group: "系统", glyph: "exclamationmark.triangle",
            paths: [home + "/Library/Logs/DiagnosticReports"]))
        out.append(PrivacyItem(
            id: "shell", title: "Shell 命令历史",
            detail: "zsh 与 bash 记下的命令，含曾经输入过的路径与参数。",
            risk: .loseHistory, group: "系统", glyph: "terminal",
            paths: [home + "/.zsh_history", home + "/.bash_history"]))
        out.append(PrivacyItem(
            id: "clipboard", title: "剪贴板内容",
            detail: "清空当前剪贴板，不会影响剪贴板历史应用之外的数据。",
            risk: .safe, group: "系统", glyph: "doc.on.clipboard",
            paths: [], clearsClipboard: true))

        return out
    }
}

// MARK: - 引擎

@MainActor
final class PrivacyEngine: ObservableObject {
    struct Row: Identifiable {
        let item: PrivacyItem
        let size: Int64
        var id: String { item.id }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var selected: Set<String> = []
    @Published private(set) var measuring = false
    @Published private(set) var cleaning = false
    @Published private(set) var message: String?

    private var task: Task<Void, Never>?

    var groups: [(String, [Row])] {
        let order = ["浏览器", "系统"]
        return Dictionary(grouping: rows, by: { $0.item.group })
            .sorted { (order.firstIndex(of: $0.key) ?? 9) < (order.firstIndex(of: $1.key) ?? 9) }
            .map { ($0.key, $0.value) }
    }

    var selectedRows: [Row] { rows.filter { selected.contains($0.id) } }
    var selectedBytes: Int64 { selectedRows.reduce(0) { $0 + $1.size } }
    var totalBytes: Int64 { rows.reduce(0) { $0 + $1.size } }

    func refresh() {
        guard !measuring else { return }
        measuring = true
        let items = PrivacyCatalog.items()
        task = Task { [weak self] in
            let sized = await Task.detached(priority: .utility) {
                items.map { item -> (PrivacyItem, Int64) in
                    var total: Int64 = 0
                    for path in item.paths {
                        total += Sizer.sizeIfPresent(path)
                    }
                    return (item, total)
                }
            }.value
            guard let self else { return }
            self.rows = sized.map { Row(item: $0.0, size: $0.1) }
            self.measuring = false
            // 默认勾选安全项，涉及登录与历史的需要用户自己决定
            self.selected = Set(self.rows.filter { $0.item.risk == .safe }.map(\.id))
            self.message = "共 \(self.rows.count) 个可清理目标，安全项已默认勾选。"
            OperationsLog.write("PRIVACY SCAN items=\(self.rows.count) bytes=\(self.totalBytes)")
        }
    }

    func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    func cleanSelected() {
        let targets = selectedRows
        guard !targets.isEmpty else { return }
        cleaning = true
        var removedBytes: Int64 = 0
        var removedPaths = 0
        var failed = 0
        var clearedClipboard = false
        for row in targets {
            if row.item.clearsClipboard {
                NSPasteboard.general.clearContents()
                clearedClipboard = true
            }
            guard !row.item.paths.isEmpty else { continue }
            // 白名单只放行本条目自己声明的路径
            let result = Remover.remove(row.item.paths, mode: .permanent, extraAllow: row.item.paths)
            removedPaths += result.removed
            failed += result.failed
            removedBytes += row.size
        }
        cleaning = false
        OperationHistory.record(kind: .privacy,
                                summary: "隐私清理：\(targets.map(\.item.title).joined(separator: "、"))",
                                bytes: removedBytes, count: targets.count)
        OperationsLog.write("PRIVACY CLEAN items=\(targets.count) paths=\(removedPaths) bytes=\(removedBytes) clipboard=\(clearedClipboard)")
        message = "已处理 \(targets.count) 项，删除 \(removedPaths) 个路径，约 \(removedBytes.bytesText)；\(failed) 个被跳过（可能正被占用）。"
        refresh()
    }
}

// MARK: - 视图

struct PrivacyView: View {
    @StateObject private var engine = PrivacyEngine()
    @State private var confirmClean = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s300) {
                PageHeader("隐私清理", subtitle: "浏览器与系统留下的痕迹。默认只勾选缓存类，涉及登录状态和历史记录的条目光看说明再决定，删除后不可恢复。") {
                    SweepButton(.secondary, title: "重新检测", systemImage: "arrow.clockwise") { engine.refresh() }
                        .disabled(engine.measuring || engine.cleaning)
                    SweepButton(.primary, title: "清理所选", systemImage: "hand.raised") { confirmClean = true }
                        .disabled(engine.selected.isEmpty || engine.cleaning)
                }

                HStack(spacing: Space.s100) {
                    MetricTile(title: "可清理总量", value: engine.totalBytes.sizeText, caption: "\(engine.rows.count) 个目标")
                    MetricTile(title: "已选", value: engine.selectedBytes.sizeText,
                               caption: "\(engine.selected.count) 项", tone: Theme.accent)
                    MetricTile(title: "含登录状态", value: "\(engine.rows.filter { $0.item.risk == .signOut }.count)",
                               caption: "清掉需重新登录", tone: Theme.accentDanger)
                }

                if engine.measuring {
                    Panel {
                        VStack(alignment: .leading, spacing: Space.s75) {
                            HStack { Skeleton(height: 12, width: 160); Spacer(); Skeleton(height: 12, width: 60) }
                            Skeleton(height: 12, width: 260)
                        }
                    }
                }

                ForEach(engine.groups, id: \.0) { group, rows in
                    VStack(alignment: .leading, spacing: Space.s75) {
                        GroupTitle(text: group, trailing: "\(rows.count) 项")
                        Panel(padding: Space.s75) {
                            VStack(spacing: 0) {
                                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                    itemRow(row)
                                    if index < rows.count - 1 {
                                        Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 34)
                                    }
                                }
                            }
                        }
                    }
                }

                if let message = engine.message {
                    Text(message).font(Typo.f(Typo.xs)).foregroundStyle(Theme.textSecondary)
                }

                Panel {
                    HStack(alignment: .top, spacing: Space.s100) {
                        Image(systemName: "info.circle").font(Typo.f(Typo.sm)).foregroundStyle(Theme.textMuted)
                        Text("浏览器运行时部分文件会被锁定，清理前先退出浏览器成功率更高。隐私清理走永久删除，不经过废纸篓。")
                            .font(Typo.f(Typo.xs)).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Space.s300)
        }
        .pageSurface()
        .onAppear { if engine.rows.isEmpty && !engine.measuring { engine.refresh() } }
        .alert("永久清除所选痕迹？", isPresented: $confirmClean) {
            Button("永久清除", role: .destructive) { engine.cleanSelected() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(confirmText)
        }
    }

    private var confirmText: String {
        var lines = ["共 \(engine.selected.count) 项，约 \(engine.selectedBytes.bytesText)，删除后不进入废纸篓。"]
        let signOut = engine.selectedRows.filter { $0.item.risk == .signOut }
        if !signOut.isEmpty {
            lines.append("其中 \(signOut.map(\.item.title).joined(separator: "、")) 会清除登录状态，相关网站需要重新登录。")
        }
        return lines.joined(separator: "\n\n")
    }

    private func itemRow(_ row: PrivacyEngine.Row) -> some View {
        HStack(alignment: .top, spacing: Space.s100) {
            Button { engine.toggle(row.id) } label: {
                Image(systemName: engine.selected.contains(row.id) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(engine.selected.contains(row.id) ? Theme.accent : Theme.textMuted)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

            Image(systemName: row.item.glyph)
                .font(Typo.f(Typo.sm))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: Space.s25) {
                HStack(spacing: Space.s75) {
                    Text(row.item.title).font(Typo.f(Typo.sm, .medium)).foregroundStyle(Theme.textPrimary)
                    Tag(text: row.item.risk.title, tone: row.item.risk.tone)
                }
                Text(row.item.detail).font(Typo.f(Typo.xs)).foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.s100)
            Text(row.item.clearsClipboard ? "—" : row.size.sizeText)
                .font(Typo.mono(Typo.xs, .medium)).foregroundStyle(Theme.textSecondary)
                .frame(width: 78, alignment: .trailing)
        }
        .padding(.horizontal, Space.s100)
        .padding(.vertical, Space.s75)
        .rowBackground(selected: engine.selected.contains(row.id))
    }
}
