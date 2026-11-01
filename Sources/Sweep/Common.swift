import Foundation
import AppKit

// MARK: - 字节/时间格式化

extension Int64 {
    var bytesText: String {
        if self < 1024 && self >= 0 { return "\(self) B" }
        return ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }

    /// 0 字节时显示占位符，避免出现 "Zero KB" 这种不自然的读数
    var sizeText: String {
        self <= 0 ? "—" : bytesText
    }
}

func relativeDate(_ date: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    f.locale = Locale(identifier: "zh_CN")
    return f.localizedString(for: date, relativeTo: Date())
}

// MARK: - 危险路径保护清单

enum PathSafety {
    /// 绝对不允许触碰的路径（无论请求来自哪个模块）
    static let protected: [String] = [
        "/", "/System", "/Library", "/private", "/etc", "/var", "/usr", "/bin", "/sbin",
        "/Applications", "/Users", "/dev", "/cores", "/opt", "/Volumes",
        NSHomeDirectory() + "/Library",
        NSHomeDirectory() + "/Desktop",
        NSHomeDirectory() + "/Documents",
        NSHomeDirectory() + "/Movies",
        NSHomeDirectory() + "/Music",
        NSHomeDirectory() + "/Pictures",
        NSHomeDirectory() + "/Public",
        NSHomeDirectory() + "/.ssh",
        NSHomeDirectory() + "/.gnupg",
    ]

    /// 永久删除仅允许发生在这些白名单前缀之下（缓存/日志/开发工具/Trash）
    static let permanentAllowed: [String] = [
        NSHomeDirectory() + "/Library/Caches",
        NSHomeDirectory() + "/Library/Logs",
        NSHomeDirectory() + "/Library/Developer",
        NSHomeDirectory() + "/Library/HTTPStorages",
        NSHomeDirectory() + "/Library/WebKit",
        NSHomeDirectory() + "/Library/Saved Application State",
        NSHomeDirectory() + "/Library/Cookies",
        NSHomeDirectory() + "/.Trash",
        NSHomeDirectory() + "/.npm",
        NSHomeDirectory() + "/.cache",
        NSHomeDirectory() + "/.gradle",
        NSHomeDirectory() + "/.m2",
        NSHomeDirectory() + "/.cargo",
        // VS Code 只放行明确的缓存目录，设置/插件/工作区仍在保护范围内
        NSHomeDirectory() + "/Library/Application Support/Code/Cache",
        NSHomeDirectory() + "/Library/Application Support/Code/CachedData",
        NSHomeDirectory() + "/Library/Application Support/Code/GPUCache",
        NSHomeDirectory() + "/Library/Application Support/Code/Code Cache",
        // pnpm 内容寻址仓库（用户显式审阅后才可清理）
        NSHomeDirectory() + "/Library/pnpm/store",
        "/private/var/log",
    ]

    /// 该路径是否允许永久删除（严格白名单）
    static func canDelete(_ path: String) -> Bool {
        let p = (path as NSString).standardizingPath
        if isProtected(p) { return false }
        return permanentAllowed.contains { p == $0 || p.hasPrefix($0 + "/") }
    }

    /// 该路径是否允许移入废纸篓（浏览模式下用户明确点击的文件；范围更宽但可恢复）
    static func canTrash(_ path: String) -> Bool {
        let p = (path as NSString).standardizingPath
        if isProtected(p) { return false }
        guard p.hasPrefix((NSHomeDirectory() as NSString).standardizingPath + "/") else { return false }
        return true
    }

    static func isProtected(_ p: String) -> Bool {
        for banned in protected {
            let b = (banned as NSString).standardizingPath
            if p == b { return true }
            // 根目录 "…" 只参与精确匹配：它的字符串前缀就是 "/"，
            // 若参与前缀匹配会把每一条绝对路径都判为受保护，删除闸门将永久失效。
            if b == "/" { continue }
            if p.hasPrefix(b) && b.hasSuffix("/") { return true } // 根目录 "/"+前缀
        }
        return false
    }
}

// MARK: - 删除帮助（把删除策略集中在一处）

enum Remover {
    enum Mode {
        case trash      // 进废纸篓，可恢复
        case permanent  // 永久删除
    }

    /// 测试钩子：每次成功移入废纸篓时回调 (原路径, 废纸篓中的位置)，
    /// 让验收脚本能找回自己的夹具而无需读取受隐私保护的 ~/.Trash 目录。
    nonisolated(unsafe) static var trashObserver: ((String, URL) -> Void)?

    /// 返回是否有失败项。调用方负责先确认。
    /// extraAllow 用于隐私清理等场景：只放行调用方自己声明的具体路径，
    /// 不影响全局白名单，也不会绕过 exact 级保护（如 ~/Library 本身）。
    @discardableResult
    static func remove(_ paths: [String], mode: Mode, extraAllow: [String] = []) -> (removed: Int, failed: Int) {
        var removed = 0
        var failed = 0
        let allow = extraAllow.map { ($0 as NSString).standardizingPath }
        for path in paths {
            let std = (path as NSString).standardizingPath
            let explicitlyAllowed = allow.contains { std == $0 || std.hasPrefix($0 + "/") }
            let base = (mode == .permanent) ? PathSafety.canDelete(std) : PathSafety.canTrash(std)
            let allowed = (base || explicitlyAllowed) && !PathSafety.isProtected(std)
            guard allowed else {
                OperationsLog.write("SKIP(protected) \(path)")
                failed += 1
                continue
            }
            let url = URL(fileURLWithPath: (path as NSString).standardizingPath)
            let nsTarget = NSURL(fileURLWithPath: url.path)
            var resultURL: NSURL?
            switch mode {
            case .trash:
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: &resultURL)
                    if let destination = resultURL as URL? { trashObserver?(url.path, destination) }
                    removed += 1
                    OperationsLog.write("TRASH \(url.path)")
                } catch {
                    failed += 1
                    OperationsLog.write("FAIL(trash) \(url.path): \(error.localizedDescription)")
                }
            case .permanent:
                do {
                    try FileManager.default.removeItem(at: url)
                    removed += 1
                    OperationsLog.write("DELETE \(url.path)")
                } catch {
                    failed += 1
                    OperationsLog.write("FAIL(delete) \(url.path): \(error.localizedDescription)")
                }
            }
        }
        return (removed, failed)
    }

    enum AdminRemovalError: LocalizedError {
        case refused(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .refused(let path): return "拒绝以管理员身份删除受保护或不明确的路径：\(path)"
            case .failed(let message): return message
            }
        }
    }

    /// 管理员删除前的路径闸门：必须是规范化的绝对路径、至少两级深、不在保护清单上。
    static func adminRemovalAllowed(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        let std = (path as NSString).standardizingPath
        guard std == path || std + "/" == path else { return false }   // 不接受 ..、//、~ 等需要解释的写法
        guard std.split(separator: "/").count >= 2 else { return false }
        if PathSafety.isProtected(std) { return false }
        let home = (NSHomeDirectory() as NSString).standardizingPath
        if std == home { return false }
        return true
    }

    /// 生成 `rm -rf -- '<path>'` 的 AppleScript 源码。
    /// shell 层用单引号包裹并把内部单引号写成 '\''；AppleScript 字符串层再转义 \ 与 "。
    /// 旧实现只做了后者，路径里带单引号（如 "Bob's App.app"）就能拆开引号、注入额外参数。
    static func adminRemovalScript(_ path: String) -> String {
        let shellQuoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = "/bin/rm -rf -- " + shellQuoted
        let appleScriptEscaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(appleScriptEscaped)\" with administrator privileges"
    }

    /// 需要管理员权限的删除（仅用于卸载 /Applications 下不可写的应用等明确场景）。
    /// 失败或用户取消授权时抛错，调用方不会再把它误记为“已删除”。
    static func adminRemove(_ path: String) throws {
        guard adminRemovalAllowed(path) else {
            OperationsLog.write("SKIP(admin-protected) \(path)")
            throw AdminRemovalError.refused(path)
        }
        guard let script = NSAppleScript(source: adminRemovalScript(path)) else {
            throw AdminRemovalError.failed("无法创建授权脚本")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "授权或删除失败"
            OperationsLog.write("FAIL(admin-delete) \(path): \(message)")
            throw AdminRemovalError.failed(message)
        }
        OperationsLog.write("ADMIN-DELETE \(path)")
    }
}

// MARK: - 目录/文件大小统计

enum Sizer {
    private struct FileIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    /// 一次遍历同时得到的两种口径
    ///
    /// `logical` 是文件内容长度之和（st_size）；`allocated` 是实际占用的磁盘块
    /// （st_blocks × 512，与 `du` 同一口径）。稀疏文件、APFS 克隆、压缩文件
    /// 会让两者相差极大——Docker 的 Docker.raw 逻辑 228 GB、实际只占 0.23 GB，
    /// 拿逻辑值当"占用"会把一个目录虚报成比整块盘还大。
    struct Measure {
        var logical: Int64 = 0
        var allocated: Int64 = 0
    }

    /// 递归测量；不跟随符号链接；同一顶层树内硬链接只计一次
    static func measure(_ path: String) -> Measure {
        let root = (path as NSString).standardizingPath
        var rootStat = stat()
        guard lstat(root, &rootStat) == 0 else { return Measure() }
        let kind = rootStat.st_mode & S_IFMT
        if kind == S_IFREG {
            return Measure(logical: Int64(rootStat.st_size),
                           allocated: Int64(rootStat.st_blocks) * 512)
        }
        guard kind == S_IFDIR else { return Measure() }
        guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: root),
                                                      includingPropertiesForKeys: [],
                                                      options: []) else { return Measure() }
        var measure = Measure(allocated: Int64(rootStat.st_blocks) * 512)
        var seenInodes = Set<FileIdentity>()
        for case let url as URL in en {
            var st = stat()
            guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { continue }
            if st.st_nlink > 1 {
                let identity = FileIdentity(device: st.st_dev, inode: st.st_ino)
                if !seenInodes.insert(identity).inserted { continue }
            }
            measure.logical += Int64(st.st_size)
            measure.allocated += Int64(st.st_blocks) * 512
        }
        return measure
    }

    /// 递归逻辑大小（若路径不存在返回 0）
    static func size(_ path: String) -> Int64 {
        measure(path).logical
    }

    /// 递归实际占用（若路径不存在返回 0）
    static func allocated(_ path: String) -> Int64 {
        measure(path).allocated
    }

    /// 同上，语义更明确：界面上凡是「占多少空间 / 能腾出多少」都取这个值
    static func footprint(_ path: String) -> Int64 {
        measure(path).allocated
    }

    /// 目录的递归大小（若路径不存在返回 0）
    static func sizeIfPresent(_ path: String) -> Int64 {
        size(path)
    }
}

// MARK: - 操作日志

/// 运行期路径：测试可以改写到临时目录，避免污染真实日志与历史
enum RuntimePaths {
    nonisolated(unsafe) static var logDirectoryOverride: String?

    static var logDirectory: String {
        logDirectoryOverride ?? NSHomeDirectory() + "/Library/Logs/Sweep"
    }
}

enum OperationsLog {
    private static var dir: String { RuntimePaths.logDirectory }
    static var logPath: String { dir + "/operations.log" }

    static func write(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
        try? ("[\(ts)] \(line)\n").append(to: URL(fileURLWithPath: logPath))
    }
}

extension String {
    func append(to url: URL) throws {
        if let fh = FileHandle(forWritingAtPath: url.path) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try fh.write(contentsOf: data(using: .utf8) ?? Data())
        } else {
            let body = hasSuffix("\n") ? self : self + "\n"
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - ~/ 展开

extension String {
    var expandingTilde: String {
        (self as NSString).expandingTildeInPath
    }
}
