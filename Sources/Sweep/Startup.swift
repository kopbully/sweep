import AppKit
import SwiftUI

// MARK: - 数据模型

/// 一条开机/登录自启项。只有用户级 LaunchAgent 可以被 Sweep 停用，
/// 系统级与 LaunchDaemon 只读展示（它们需要管理员权限，Sweep 不做提权）。
struct LaunchItem: Identifiable, Hashable {
    enum Scope: String {
        case userAgent, globalAgent, daemon

        var title: String {
            switch self {
            case .userAgent: return "用户代理"
            case .globalAgent: return "系统代理"
            case .daemon: return "系统守护"
            }
        }

        var needsAdmin: Bool { self != .userAgent }
    }

    let id: String            // = plist 路径
    let label: String
    let scope: Scope
    let path: String
    let program: String
    let runAtLoad: Bool
    let loaded: Bool
    let restoredFromDisabledStore: Bool

    var manageable: Bool { scope == .userAgent }
    var isEnabled: Bool { restoredFromDisabledStore || loaded }
}

/// plist 解析与 launchctl 输出解析，独立出来便于回归测试。
enum LaunchPlist {
    static func disabledStoreDirectory(home: String = NSHomeDirectory()) -> String {
        home + "/Library/Application Support/Sweep/disabled-launch-agents"
    }

    /// 解析单个 LaunchAgent/Daemon plist。软链与不可读文件返回 nil。
    static func parse(url: URL) -> (label: String, program: String, runAtLoad: Bool)? {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        if values?.isSymbolicLink == true { return nil }
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any] else { return nil }
        let label = (dict["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
        let program: String
        if let path = dict["Program"] as? String {
            program = path
        } else if let args = dict["ProgramArguments"] as? [String], let first = args.first {
            program = first
        } else {
            program = "（未声明可执行文件）"
        }
        return (label, program, (dict["RunAtLoad"] as? Bool) ?? false)
    }

    /// 解析 `launchctl list` 输出中的 label 集合（首行是表头 PID/Status/Label）。
    static func loadedLabels(from output: String) -> Set<String> {
        var labels = Set<String>()
        for (index, line) in output.split(separator: "\n").enumerated() {
            if index == 0 { continue }
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard let last = columns.last else { continue }
            let label = String(last).trimmingCharacters(in: .whitespaces)
            if !label.isEmpty, label != "Label" { labels.insert(label) }
        }
        return labels
    }
}

// MARK: - 扫描 / 启停引擎

final class StartupEngine: ObservableObject {
    @Published private(set) var items: [LaunchItem] = []
    @Published private(set) var scanning = false
    @Published private(set) var busyLabel: String?
    @Published var message = "扫描 ~/Library/LaunchAgents 与系统 LaunchAgents / LaunchDaemons"

    private let home = NSHomeDirectory()
    private let fileManager = FileManager.default

    func scan() {
        guard !scanning else { return }
        scanning = true
        items = []
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = self.loadedLabels()
            var found: [LaunchItem] = []
            for (directory, scope) in self.searchDirectories() {
                found += self.items(in: directory, scope: scope, loaded: loaded)
            }
            let disabled = self.disabledItems(loaded: loaded)
            let sorted = (found + disabled).sorted {
                let rank = { (scope: LaunchItem.Scope) in
                    switch scope {
                    case .userAgent: return 0
                    case .globalAgent: return 1
                    case .daemon: return 2
                    }
                }
                if $0.scope != $1.scope { return rank($0.scope) < rank($1.scope) }
                return $0.label.localizedStandardCompare($1.label) == .orderedAscending
            }
            DispatchQueue.main.async {
                self.items = sorted
                self.scanning = false
                let on = sorted.filter(\.isEnabled).count
                self.message = "共 \(sorted.count) 项自启，其中 \(on) 项已启用"
                OperationsLog.write("STARTUP SCAN items=\(sorted.count) enabled=\(on)")
            }
        }
    }

    /// 停用：先从 launchd 卸载，再把 plist 移到 Sweep 自己的停用目录（不删除，可恢复）。
    /// 启用：把 plist 移回原目录并重新 bootstrap。
    func setEnabled(_ item: LaunchItem, enabled: Bool) {
        guard item.manageable, busyLabel == nil else { return }
        busyLabel = item.label
        message = enabled ? "正在启用 \(item.label)…" : "正在停用 \(item.label)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = enabled ? self.enable(item) : self.disable(item)
            DispatchQueue.main.async {
                self.busyLabel = nil
                self.message = result
                self.scan()
            }
        }
    }

    func revealInFinder(_ item: LaunchItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }

    // MARK: 内部

    private func searchDirectories() -> [(String, LaunchItem.Scope)] {
        [
            (home + "/Library/LaunchAgents", .userAgent),
            ("/Library/LaunchAgents", .globalAgent),
            ("/Library/LaunchDaemons", .daemon),
        ]
    }

    private func plistFiles(in directory: String) -> [URL] {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory)) ?? []
        return names
            .filter { $0.hasSuffix(".plist") && !$0.hasPrefix(".") }
            .sorted()
            .map { URL(fileURLWithPath: directory).appendingPathComponent($0) }
    }

    private func items(in directory: String, scope: LaunchItem.Scope, loaded: Set<String>) -> [LaunchItem] {
        guard scope != .userAgent || fileManager.fileExists(atPath: directory) else { return [] }
        return plistFiles(in: directory).compactMap { url in
            guard let parsed = LaunchPlist.parse(url: url) else { return nil }
            return LaunchItem(id: url.path, label: parsed.label, scope: scope, path: url.path,
                              program: parsed.program, runAtLoad: parsed.runAtLoad,
                              loaded: loaded.contains(parsed.label), restoredFromDisabledStore: false)
        }
    }

    private func disabledItems(loaded: Set<String>) -> [LaunchItem] {
        let directory = LaunchPlist.disabledStoreDirectory(home: home)
        return plistFiles(in: directory).compactMap { url in
            guard let parsed = LaunchPlist.parse(url: url) else { return nil }
            return LaunchItem(id: url.path, label: parsed.label, scope: .userAgent,
                              path: url.path, program: parsed.program, runAtLoad: parsed.runAtLoad,
                              loaded: loaded.contains(parsed.label), restoredFromDisabledStore: true)
        }
    }

    private func loadedLabels() -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return LaunchPlist.loadedLabels(from: String(decoding: data, as: UTF8.self))
    }

    @discardableResult
    private func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func disable(_ item: LaunchItem) -> String {
        let store = LaunchPlist.disabledStoreDirectory(home: home)
        do {
            try fileManager.createDirectory(atPath: store, withIntermediateDirectories: true)
            let target = URL(fileURLWithPath: store).appendingPathComponent((item.path as NSString).lastPathComponent)
            if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
            _ = launchctl(["bootout", "gui/\(getuid())/\(item.label)"])
            try fileManager.moveItem(atPath: item.path, toPath: target.path)
            OperationsLog.write("STARTUP DISABLE label=\(item.label)")
            return "已停用 \(item.label)，可在本页重新启用"
        } catch {
            OperationsLog.write("STARTUP DISABLE_FAIL label=\(item.label) reason=\(error.localizedDescription)")
            return "停用失败：\(error.localizedDescription)"
        }
    }

    private func enable(_ item: LaunchItem) -> String {
        let homeAgents = home + "/Library/LaunchAgents"
        do {
            try fileManager.createDirectory(atPath: homeAgents, withIntermediateDirectories: true)
            let target = URL(fileURLWithPath: homeAgents).appendingPathComponent((item.path as NSString).lastPathComponent)
            if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
            try fileManager.moveItem(atPath: item.path, toPath: target.path)
            _ = launchctl(["bootstrap", "gui/\(getuid())", target.path])
            OperationsLog.write("STARTUP ENABLE label=\(item.label)")
            return "已启用 \(item.label)"
        } catch {
            OperationsLog.write("STARTUP ENABLE_FAIL label=\(item.label) reason=\(error.localizedDescription)")
            return "启用失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 视图

struct StartupView: View {
    @StateObject private var engine = StartupEngine()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                SectionTitle(title: "启动项", subtitle: "登录或开机时自动运行的后台程序；用户级可停用，系统级仅展示")
                Spacer()
                Button {
                    engine.scan()
                } label: {
                    Label(engine.scanning ? "扫描中…" : "重新扫描", systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .disabled(engine.scanning)
            }

            Text(engine.message)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)

            if engine.items.isEmpty && !engine.scanning {
                Card {
                    Text("未发现自启项，或该目录需要完全磁盘访问权限")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(engine.items) { item in
                            row(item)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(18)
        .onAppear { if engine.items.isEmpty { engine.scan() } }
    }

    private func row(_ item: LaunchItem) -> some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(item.isEnabled ? Theme.accent : Theme.textSecondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.label)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(item.scope.title)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(item.manageable ? Theme.accent : Theme.accentWarn)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background((item.manageable ? Theme.accent : Theme.accentWarn).opacity(0.12))
                            .clipShape(Capsule())
                        if item.runAtLoad {
                            Text("RunAtLoad")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        if item.restoredFromDisabledStore {
                            Text("已停用")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.accentWarn)
                        }
                    }
                    Text(item.program)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if item.manageable {
                    Button(item.restoredFromDisabledStore ? "启用" : "停用") {
                        engine.setEnabled(item, enabled: item.restoredFromDisabledStore)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(engine.busyLabel != nil)
                } else {
                    Text("需管理员")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                }

                Button {
                    engine.revealInFinder(item)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("在 Finder 中显示")
            }
        }
    }
}
