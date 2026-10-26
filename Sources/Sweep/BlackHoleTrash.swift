import AppKit
import Foundation

struct BlackHoleTrashResult: Sendable {
    let id: String
    let ok: Bool
    let error: String?
    let destination: URL?
}

enum BlackHoleTrash {
    static func canonicalURL(_ url: URL) -> URL {
        let normalized = url.standardizedFileURL
        // Resolve parent aliases, but move a final symlink itself rather than its target.
        return normalized.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(normalized.lastPathComponent)
    }

    static func validationError(for url: URL) -> String? {
        guard url.isFileURL else { return "请拖入本机文件或文件夹" }
        let path = canonicalURL(url).path
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        let exactProtected = PathSafety.protected.map { ($0 as NSString).standardizingPath }
        if path == home || exactProtected.contains(path) { return "此目录受保护，请选择其中的具体文件" }
        for root in [home + "/.ssh", home + "/.gnupg", home + "/.Trash"] {
            if path == root || path.hasPrefix(root + "/") { return "此位置受保护" }
        }
        let allowedRoots = [home, "/Applications", "/Volumes"]
        guard allowedRoots.contains(where: { path.hasPrefix($0 + "/") }) else {
            return "此系统位置不接受拖放回收" }
        let app = Bundle.main.bundleURL.path
        if app.hasSuffix(".app"), path == app || path.hasPrefix(app + "/") || app.hasPrefix(path + "/") {
            return "请保留正在运行的 Sweep" }
        var st = stat()
        guard lstat(path, &st) == 0 else { return "文件已不存在或没有访问权限" }
        return nil
    }

    static func candidates(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        let unique = urls.filter(\.isFileURL).map(canonicalURL).filter { seen.insert($0.path).inserted }
        return unique.filter { item in
            !unique.contains { parent in
                guard parent != item, item.path.hasPrefix(parent.path + "/"),
                      validationError(for: parent) == nil else { return false }
                var st = stat()
                return lstat(parent.path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
            }
        }
    }

    static func moveToTrash(_ urls: [URL]) -> [BlackHoleTrashResult] {
        let results = candidates(urls).map { url -> BlackHoleTrashResult in
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            if let error = validationError(for: url) {
                return BlackHoleTrashResult(id: url.path, ok: false, error: error, destination: nil)
            }
            var destination: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
                return BlackHoleTrashResult(id: url.path, ok: true, error: nil,
                                            destination: destination as URL?)
            } catch {
                return BlackHoleTrashResult(id: url.path, ok: false,
                                            error: error.localizedDescription, destination: nil)
            }
        }
        OperationsLog.write("BLACKHOLE TRASH ok=\(results.filter(\.ok).count) failed=\(results.filter { !$0.ok }.count)")
        return results
    }
}
