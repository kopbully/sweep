import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 结构化操作记录

enum OperationKind: String, CaseIterable, Identifiable {
    case clean, trash, delete, optimize, privacy, duplicate, largeFile, startup, memory, uninstall, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clean: return "缓存清理"
        case .trash: return "移入废纸篓"
        case .delete: return "永久删除"
        case .optimize: return "系统优化"
        case .privacy: return "隐私清理"
        case .duplicate: return "重复文件"
        case .largeFile: return "大文件"
        case .startup: return "启动项"
        case .memory: return "内存"
        case .uninstall: return "应用卸载"
        case .system: return "其他"
        }
    }

    var glyph: String {
        switch self {
        case .clean: return "wind"
        case .trash: return "trash"
        case .delete: return "trash.slash"
        case .optimize: return "bolt.horizontal"
        case .privacy: return "hand.raised"
        case .duplicate: return "doc.on.doc"
        case .largeFile: return "doc.zipper"
        case .startup: return "power"
        case .memory: return "memorychip"
        case .uninstall: return "xmark.bin"
        case .system: return "info.circle"
        }
    }

    var tone: TagTone {
        switch self {
        case .delete, .duplicate, .largeFile: return .warn
        case .privacy: return .danger
        case .system: return .neutral
        default: return .accent
        }
    }
}

struct OperationRecord: Identifiable {
    let id: String
    let date: Date?
    let rawTime: String
    let kind: OperationKind
    let summary: String
    let bytes: Int64?
    let count: Int?
}

enum OperationHistory {
    static var directory: String { RuntimePaths.logDirectory }
    static var jsonPath: String { directory + "/history.jsonl" }
    static var legacyLogPath: String { OperationsLog.logPath }

    /// 记录一次结构化操作；失败不影响主流程
    static func record(kind: OperationKind, summary: String,
                       bytes: Int64? = nil, count: Int? = nil) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var payload: [String: Any] = [
            "ts": Date().timeIntervalSince1970,
            "kind": kind.rawValue,
            "summary": summary,
        ]
        if let bytes { payload["bytes"] = bytes }
        if let count { payload["count"] = count }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let line = String(data: data, encoding: .utf8) else { return }
        try? (line + "\n").append(to: URL(fileURLWithPath: jsonPath))
    }

    /// 合并结构化记录与旧版纯文本日志。
    /// 结构化记录出现之后，旧日志里的同一条操作会被重复计入，
    /// 因此只保留早于第一条结构化记录的旧日志。
    static func load() -> [OperationRecord] {
        let structured = loadJSON()
        let legacy = loadLegacy()
        let cutoff = structured.compactMap(\.date).min()
        let kept = legacy.filter { record in
            guard let cutoff, let date = record.date else { return true }
            return date < cutoff
        }
        return (structured + kept).sorted {
            ($0.date ?? .distantPast) > ($1.date ?? .distantPast)
        }
    }

    private static func loadJSON() -> [OperationRecord] {
        guard let text = try? String(contentsOfFile: jsonPath, encoding: .utf8) else { return [] }
        var out: [OperationRecord] = []
        for (index, line) in text.split(separator: "\n").enumerated() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let summary = obj["summary"] as? String else { continue }
            let ts = (obj["ts"] as? Double) ?? 0
            let kind = OperationKind(rawValue: (obj["kind"] as? String) ?? "") ?? .system
            let date = ts > 0 ? Date(timeIntervalSince1970: ts) : nil
            out.append(OperationRecord(
                id: "json-\(index)-\(ts)",
                date: date,
                rawTime: date.map(HistoryFormat.clock) ?? "",
                kind: kind,
                summary: summary,
                bytes: obj["bytes"] as? Int64 ?? (obj["bytes"] as? Int).map(Int64.init),
                count: obj["count"] as? Int
            ))
        }
        return out
    }

    private static func loadLegacy() -> [OperationRecord] {
        guard let text = try? String(contentsOfFile: legacyLogPath, encoding: .utf8) else { return [] }
        var out: [OperationRecord] = []
        for (index, line) in text.split(separator: "\n").enumerated() {
            let raw = String(line)
            guard let open = raw.firstIndex(of: "["), let close = raw.firstIndex(of: "]") else { continue }
            let stamp = String(raw[raw.index(after: open)..<close])
            let body = String(raw[raw.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }
            let date = HistoryFormat.parse(stamp)
            // 旧日志的行首是动作标记，标记之后才是正文
            let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            let mark = String(parts.first ?? "")
            let rest = parts.count > 1 ? String(parts[1]) : ""
            // 只有扫描统计和悬浮窗心跳的日志不是用户操作，不进入历史
            let upperBody = body.uppercased()
            let noiseMarks: Set<String> = ["READY", "POINTER_ENTER", "POINTER_LEAVE", "HEARTBEAT", "PING"]
            if noiseMarks.contains(mark.uppercased()) { continue }
            if upperBody.hasPrefix("BLACKHOLE") { continue }
            if upperBody.contains(" SCAN ") { continue }
            out.append(OperationRecord(
                id: "log-\(index)-\(stamp)",
                date: date,
                rawTime: stamp,
                kind: HistoryFormat.kind(for: mark),
                summary: rest.isEmpty ? body : rest,
                bytes: nil,
                count: nil
            ))
        }
        return out
    }

    static func exportCSV(_ records: [OperationRecord], to url: URL) throws {
        var lines = ["时间,类型,摘要,字节,数量"]
        for r in records {
            let time = r.date.map(HistoryFormat.iso) ?? r.rawTime
            let summary = r.summary.replacingOccurrences(of: "\"", with: "\"\"")
            lines.append("\"\(time)\",\"\(r.kind.title)\",\"\(summary)\",\(r.bytes.map(String.init) ?? ""),\(r.count.map(String.init) ?? "")")
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func clear() {
        try? FileManager.default.removeItem(atPath: jsonPath)
        try? FileManager.default.removeItem(atPath: legacyLogPath)
    }
}

enum HistoryFormat {
    private static let formats = [
        "yyyy/M/d HH:mm:ss", "yyyy/M/d h:mm:ss a",
        "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss",
        "M/d/yy h:mm:ss a", "d/M/yy HH:mm:ss", "yy/M/d HH:mm:ss",
    ]

    private static let parsers: [DateFormatter] = formats.map { f in
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_US_POSIX")
        d.dateFormat = f
        return d
    }

    static func parse(_ text: String) -> Date? {
        for p in parsers {
            if let d = p.date(from: text) { return d }
        }
        return nil
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    static func iso(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    static func kind(for mark: String) -> OperationKind {
        let m = mark.uppercased()
        if m.hasPrefix("CLEAN") { return .clean }
        if m.hasPrefix("ADMIN-DELETE") || m.hasPrefix("DELETE") { return .delete }
        if m.hasPrefix("TRASH") { return .trash }
        if m.hasPrefix("OPTIMIZE") { return .optimize }
        if m.hasPrefix("PRIVACY") { return .privacy }
        if m.hasPrefix("DUP") { return .duplicate }
        if m.hasPrefix("LARGE") { return .largeFile }
        if m.hasPrefix("STARTUP") { return .startup }
        if m.hasPrefix("MEMORY") { return .memory }
        return .system
    }
}

// MARK: - 引擎

@MainActor
final class HistoryEngine: ObservableObject {
    @Published private(set) var records: [OperationRecord] = []
    @Published var filter: OperationKind? = nil
    @Published var search = ""

    func reload() {
        records = OperationHistory.load()
    }

    var filtered: [OperationRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return records.filter { record in
            if let filter, record.kind != filter { return false }
            guard !query.isEmpty else { return true }
            return record.summary.localizedCaseInsensitiveContains(query)
        }
    }

    var groups: [(day: Date?, title: String, records: [OperationRecord])] {
        let calendar = Calendar.current
        var buckets: [Date: [OperationRecord]] = [:]
        var undated: [OperationRecord] = []
        for record in filtered {
            if let date = record.date {
                buckets[calendar.startOfDay(for: date), default: []].append(record)
            } else {
                undated.append(record)
            }
        }
        var out: [(Date?, String, [OperationRecord])] = buckets.keys.sorted(by: >).map { day in
            (day, HistoryEngine.dayTitle(day), buckets[day] ?? [])
        }
        if !undated.isEmpty { out.append((nil, "时间未识别", undated)) }
        return out
    }

    var releasedTotal: Int64 {
        filtered.compactMap(\.bytes).reduce(0, +)
    }

    var todayCount: Int {
        let today = Calendar.current.startOfDay(for: Date())
        return records.filter { record in
            guard let date = record.date else { return false }
            return Calendar.current.startOfDay(for: date) == today
        }.count
    }

    func export(to url: URL) -> String {
        do {
            try OperationHistory.exportCSV(filtered, to: url)
            OperationHistory.record(kind: .system, summary: "导出操作历史 \(filtered.count) 条")
            reload()
            return "已导出 \(filtered.count) 条记录"
        } catch {
            return "导出失败：\(error.localizedDescription)"
        }
    }

    static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M 月 d 日 EEEE"
        return f.string(from: day)
    }
}

// MARK: - 视图

struct HistoryView: View {
    @StateObject private var engine = HistoryEngine()
    @State private var message: String?

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s300) {
                Color.clear.frame(height: 0).id("history-top")
                PageHeader("操作历史", subtitle: "本机每一次删除、清理与系统改动都记录在这里，按时间倒序排列。") {
                    SweepButton(.secondary, title: "刷新", systemImage: "arrow.clockwise") {
                        engine.reload()
                    }
                    SweepButton(.primary, title: "导出", systemImage: "square.and.arrow.up") { export() }
                        .disabled(engine.filtered.isEmpty)
                }

                HStack(spacing: Space.s100) {
                    MetricTile(title: "记录总数", value: "\(engine.records.count)", caption: "含旧版日志解析")
                    MetricTile(title: "今日操作", value: "\(engine.todayCount)", caption: "今天发生的改动")
                    MetricTile(title: "当前筛选释放", value: engine.releasedTotal.sizeText,
                               caption: "仅结构化记录带容量", tone: Theme.accent)
                }

                filterBar
                content
                if let message {
                    Text(message).font(Typo.f(Typo.xs)).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(Space.s300)
        }
        .pageSurface()
        .onAppear {
            engine.reload()
            DispatchQueue.main.async { proxy.scrollTo("history-top", anchor: .top) }
        }
        }
    }

    private var filterBar: some View {
        HStack(spacing: Space.s75) {
            chip("全部", active: engine.filter == nil) { engine.filter = nil }
            ForEach(OperationKind.allCases) { kind in
                if engine.records.contains(where: { $0.kind == kind }) {
                    chip(kind.title, active: engine.filter == kind) { engine.filter = kind }
                }
            }
            Spacer()
            HStack(spacing: Space.s50) {
                Image(systemName: "magnifyingglass")
                    .font(Typo.f(Typo.xs))
                    .foregroundStyle(Theme.textMuted)
                TextField("搜索记录", text: $engine.search)
                    .textFieldStyle(.plain)
                    .font(Typo.f(Typo.xs))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 160)
            }
            .padding(.horizontal, Space.s75)
            .padding(.vertical, Space.s50)
            .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Theme.surfaceRaised))
        }
    }

    private func chip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typo.f(Typo.xs, .medium))
                .foregroundStyle(active ? Color.white : Theme.textSecondary)
                .padding(.horizontal, Space.s100)
                .padding(.vertical, Space.s50)
                .background(
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .fill(active ? Theme.actionFill : Theme.surfaceRaised)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        if engine.records.isEmpty {
            Panel {
                EmptyState(icon: "clock.arrow.circlepath",
                           title: "还没有操作记录",
                           message: "清理缓存、删除文件或运行优化任务之后，这里会自动留下记录。") {
                    SweepButton(.secondary, title: "打开日志目录", systemImage: "folder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: OperationHistory.directory)
                    }
                }
            }
        } else if engine.filtered.isEmpty {
            Panel {
                EmptyState(icon: "line.3.horizontal.decrease.circle",
                           title: "没有匹配的记录",
                           message: "换个类型或清空搜索词再试一次。").frame(height: 180)
            }
        } else {
            ForEach(Array(engine.groups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: Space.s75) {
                    GroupTitle(text: group.title, trailing: "\(group.records.count) 条")
                    Panel(padding: Space.s75) {
                        VStack(spacing: 0) {
                            ForEach(Array(group.records.enumerated()), id: \.element.id) { index, record in
                                row(record)
                                if index < group.records.count - 1 {
                                    Rectangle().fill(Theme.border).frame(height: 1)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func row(_ record: OperationRecord) -> some View {
        HStack(alignment: .top, spacing: Space.s100) {
            Image(systemName: record.kind.glyph)
                .font(Typo.f(Typo.xs, .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 16)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: Space.s25) {
                Text(record.summary)
                    .font(Typo.f(Typo.sm))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Space.s75) {
                    Tag(text: record.kind.title, tone: record.kind.tone)
                    if let count = record.count { Tag(text: "\(count) 项") }
                    if let bytes = record.bytes { Tag(text: bytes.bytesText, tone: .accent) }
                }
            }
            Spacer(minLength: Space.s100)
            Text(record.rawTime)
                .font(Typo.mono(Typo.xs))
                .foregroundStyle(Theme.textMuted)
        }
        .padding(.horizontal, Space.s100)
        .padding(.vertical, Space.s75)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Sweep-操作历史.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        message = engine.export(to: url)
    }
}
