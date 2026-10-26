import SwiftUI
import AppKit

// MARK: - 维护任务

struct OptimizeTask: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let needsAdmin: Bool
}

enum OptimizeCatalog {
    static let tasks: [OptimizeTask] = [
        OptimizeTask(id: "dnsFlush", title: "刷新 DNS 缓存",
            detail: "重置 mDNSResponder。遇到网页打不开或刚换了代理时有用。需要输入一次管理员密码。",
            icon: "network", needsAdmin: true),
        OptimizeTask(id: "quicklook", title: "清理 Quick Look 缩略图缓存",
            detail: "删除已损坏或过期的预览图缩略缓存，Finder 下次打开会重建。",
            icon: "eye", needsAdmin: false),
        OptimizeTask(id: "userLogs", title: "修剪 30 天前的旧日志",
            detail: "删除 ~/Library/Logs 中超过 30 天未修改的日志文件，对数据零损失。",
            icon: "doc.plaintext", needsAdmin: false),
        OptimizeTask(id: "trashEmpty", title: "清空废纸篓",
            detail: "删除所有废纸篓内容，释放的空间立即生效。此操作不可恢复。",
            icon: "trash", needsAdmin: false),
        OptimizeTask(id: "downloads", title: "清理下载目录里的安装包",
            detail: "把 ~/Downloads 中的 .dmg、.pkg、.zip 安装包移入废纸篓——装完就该扔。",
            icon: "shippingbox", needsAdmin: false),
        OptimizeTask(id: "sysLogs", title: "修剪系统日志（管理员）",
            detail: "删除 /private/var/log 中 30 天以前的系统日志。需要一次管理员密码。",
            icon: "terminal", needsAdmin: true),
    ]

    /// 统一执行入口：done 会在主线程回调
    static func execute(task: OptimizeTask, done: @escaping @Sendable (String, Bool) -> Void) {
        switch task.id {
        case "dnsFlush":
            runAdmin("dscacheutil -flushcache; killall -HUP mDNSResponder", done: done)
        case "quicklook":
            let dir = NSHomeDirectory() + "/Library/Caches/com.apple.QuickLook.thumbnailcache"
            let res = Remover.remove(children(of: dir), mode: .permanent)
            done("清理了 \(res.removed) 项（\(res.failed) 项被跳过）", res.failed == 0)
        case "userLogs":
            let log = NSHomeDirectory() + "/Library/Logs"
            let old = oldFiles(in: log, days: 30)
            let res = Remover.remove(old, mode: .permanent)
            done("移除了 \(res.removed) 个旧日志文件", res.failed == 0)
        case "trashEmpty":
            let res = Remover.remove(children(of: NSHomeDirectory() + "/.Trash"), mode: .permanent)
            done("清空了 \(res.removed) 项，失败 \(res.failed) 项", res.failed == 0)
        case "downloads":
            let dl = NSHomeDirectory() + "/Downloads"
            let kids = (try? FileManager.default.contentsOfDirectory(atPath: dl)) ?? []
            let packs = kids.filter { $0.hasSuffix(".dmg") || $0.hasSuffix(".pkg") || $0.hasSuffix(".zip") }
                .map { "\(dl)/\($0)" }
            if packs.isEmpty { done("没有找到安装包", true); return }
            let res = Remover.remove(packs, mode: .trash)
            done("移走 \(res.removed) 个安装包（已放进废纸篓）", res.failed == 0)
        case "sysLogs":
            runAdmin("find /private/var/log -type f -mtime +30 -delete", done: done)
        default:
            done("未知的任务", false)
        }
    }

    static func children(of path: String) -> [String] {
        let fm = FileManager.default
        let kids = (try? fm.contentsOfDirectory(atPath: ((path as NSString).standardizingPath))) ?? []
        return kids.map { "\(path)/\($0)" }
    }

    static func oldFiles(in path: String, days: Int) -> [String] {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: ((path as NSString).standardizingPath)) else { return [] }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        var result: [String] = []
        for case let sub as String in en {
            let full = ((path as NSString).standardizingPath) + "/" + sub
            var st = stat()
            guard stat(full, &st) == 0 else { continue }
            let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            if mtime < cutoff { result.append(full) }
        }
        return result
    }
}

/// 通过 AppleScript 提权执行 shell 命令
private func runAdmin(_ shell: String, done: @escaping @Sendable (String, Bool) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var output = "完成"
        var ok = true
        if let script = NSAppleScript(source:
            "do shell script \"\(escaped)\" with administrator privileges") {
            var error: NSDictionary? = nil
            let desc = script.executeAndReturnError(&error)
            if let e = error {
                ok = false
                output = "被取消或失败：\((e["NSLocalizedDescriptionKey"] as? String) ?? "未知错误")"
            } else {
                output = "完成"
            }
        }
        DispatchQueue.main.async { done(output, ok) }
    }
}

// MARK: - 视图

struct OptimizeView: View {
    @StateObject private var engine = OptimizeRunner()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(title: "优化", subtitle: "六个安全的维护动作。合并执行前会逐条显示结果")

                runAllCard

                if engine.runningTask != nil {
                    Card {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("正在执行：\(engine.runningTask ?? "")")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }

                ForEach(OptimizeCatalog.tasks) { task in
                    taskCard(task)
                }
            }
            .padding(20)
        }
        .background(Theme.bg)
    }

    private var runAllCard: some View {
        Card {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("一键维护")
                        .font(.system(size: 21, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text("免费任务会自动运行；需要管理员密码的任务会先弹出系统授权窗口。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    engine.runAll()
                } label: {
                    Label("开始一键维护", systemImage: "bolt.horizontal.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .foregroundStyle(.black)
                .disabled(engine.runningTask != nil)
            }
        }
    }

    private func taskCard(_ task: OptimizeTask) -> some View {
        Card {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Theme.bg)
                        .frame(width: 34, height: 34)
                    Image(systemName: task.icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(task.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        if task.needsAdmin {
                            Text("需要密码")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.accentWarn)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.accentWarn.opacity(0.12)))
                        }
                    }
                    Text(task.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let msg = engine.results[task.id] {
                        Text(msg)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.accent)
                    }
                }
                Spacer()
                Button {
                    engine.run(task: task)
                } label: {
                    Text(engine.results[task.id] != nil ? "再跑一次" : "运行")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.bordered)
                .disabled(engine.runningTask != nil)
            }
        }
    }
}

final class OptimizeRunner: ObservableObject {
    @Published var runningTask: String? = nil
    @Published var results: [String: String] = [:]

    func run(task: OptimizeTask) {
        guard runningTask == nil else { return }
        runningTask = task.title
        DispatchQueue.global(qos: .userInitiated).async {
            OptimizeCatalog.execute(task: task) { [weak self] msg, _ in
                DispatchQueue.main.async {
                    self?.results[task.id] = msg
                    self?.runningTask = nil
                }
            }
        }
    }

    func runAll() {
        guard runningTask == nil else { return }
        let freeTasks = OptimizeCatalog.tasks.filter { !$0.needsAdmin }
        runningTask = "一键维护"
        executeChain(freeTasks, index: 0) { [weak self] in
            DispatchQueue.main.async { self?.runningTask = nil }
        }
    }

    private func executeChain(_ tasks: [OptimizeTask], index: Int, last: @escaping () -> Void) {
        guard index < tasks.count else { last(); return }
        let task = tasks[index]
        DispatchQueue.global(qos: .userInitiated).async {
            OptimizeCatalog.execute(task: task) { [weak self] msg, _ in
                DispatchQueue.main.async {
                    self?.results[task.id] = msg
                }
                self?.executeChain(tasks, index: index + 1, last: last)
            }
        }
    }
}
