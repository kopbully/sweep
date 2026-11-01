import Foundation
import AppKit

// 功能/删除链路验收：只操作本脚本自己创建的夹具（主目录下的隐藏目录、
// ~/Library/Caches 下的唯一命名目录），日志与历史重定向到临时目录。
// 进入系统废纸篓的夹具会被找回或在结束时清掉，不触碰任何用户文件。

@main
@MainActor
struct FeatureChecks {
    static var failures = 0
    static var checks = 0
    static let token = "sweep-verify-" + UUID().uuidString.prefix(8).lowercased()
    static let fm = FileManager.default
    static let home = (NSHomeDirectory() as NSString).standardizingPath

    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        if condition() { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
    }

    static func write(_ path: String, bytes: Int, fill: UInt8 = 0x41) throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: URL(fileURLWithPath: path))
    }

    /// 本次移入废纸篓的夹具：原路径 → 废纸篓位置（~/.Trash 受隐私保护无法列目录）
    static var trashed: [String: URL] = [:]
    static func trashEntries() -> [String] {
        trashed.values.map(\.path).filter { fm.fileExists(atPath: $0) && $0.contains("sweep") }
    }

    static func main() throws {
        let logs = NSTemporaryDirectory() + token + "-logs"
        RuntimePaths.logDirectoryOverride = logs
        Remover.trashObserver = { original, destination in
            MainActor.assumeIsolated { trashed[original] = destination }
        }
        let root = home + "/." + token
        let cacheRoot = home + "/Library/Caches/" + token
        defer {
            try? fm.removeItem(atPath: root)
            try? fm.removeItem(atPath: cacheRoot)
            try? fm.removeItem(atPath: logs)
            for leftover in trashEntries() { try? fm.removeItem(atPath: leftover) }
            print(trashEntries().isEmpty ? "CLEANUP ok" : "CLEANUP left in Trash: \(trashEntries())")
        }

        // MARK: 删除闸门
        for p in ["/", "/System", "/Applications", "/Users", home, home + "/Library", home + "/Documents",
                  home + "/Desktop", home + "/.ssh"] {
            check(!PathSafety.canTrash(p) && !PathSafety.canDelete(p), "protected path is neither trashable nor deletable: \(p)")
            check(!Remover.adminRemovalAllowed(p), "admin removal refuses protected path: \(p)")
        }
        check(!Remover.adminRemovalAllowed("relative/App.app"), "admin removal refuses relative paths")
        check(!Remover.adminRemovalAllowed("/Applications/../Users"), "admin removal refuses .. segments")
        check(!Remover.adminRemovalAllowed("/Applications//Foo.app"), "admin removal refuses non-canonical paths")
        check(Remover.adminRemovalAllowed("/Applications/Foo.app"), "admin removal allows an explicit app bundle")
        let tricky = "/Applications/Bob's \"Quoted\" App.app"
        let script = Remover.adminRemovalScript(tricky)
        check(script.contains("'/Applications/Bob'\\\\''s \\\"Quoted\\\" App.app'"),
              "admin script single-quotes the path and escapes quotes for AppleScript")
        var compileError: NSDictionary?
        let compiled = NSAppleScript(source: script)?.compileAndReturnError(&compileError) ?? false
        check(compiled && compileError == nil, "admin script with quotes compiles (not executed)")
        check(!script.contains("rm -rf '/Applications/Bob's"), "old injectable quoting is gone")

        // MARK: 永久删除白名单
        let outside = root + "/keep/notes.txt"
        try write(outside, bytes: 10)
        let refused = Remover.remove([outside], mode: .permanent)
        check(refused.removed == 0 && fm.fileExists(atPath: outside), "permanent delete outside whitelist is refused")
        let cacheFile = cacheRoot + "/blob.bin"
        try write(cacheFile, bytes: 10)
        let removed = Remover.remove([cacheFile], mode: .permanent)
        check(removed.removed == 1 && !fm.fileExists(atPath: cacheFile), "permanent delete inside ~/Library/Caches works")

        // MARK: 大文件扫描 → 废纸篓 → 恢复
        let big = root + "/large/" + token + "-big.bin"
        let small = root + "/large/" + token + "-small.bin"
        try write(big, bytes: 2_200_000)
        try write(small, bytes: 10_000)
        let found = LargeFileScanner.scan(roots: [root + "/large"], minSize: 1_000_000,
                                          cancellation: CleanupCancellationToken()) { _, _, _ in }
        check(found.map(\.path) == [big], "large file scan returns only files above threshold")
        let trashResult = Remover.remove([big], mode: .trash)
        check(trashResult.removed == 1 && !fm.fileExists(atPath: big), "large file moves out of its folder")
        let inTrash = trashed[big]?.path
        check(inTrash != nil, "large file is recoverable from Trash")
        if let inTrash {
            try fm.moveItem(atPath: inTrash, toPath: big)
            check((try? Data(contentsOf: URL(fileURLWithPath: big)))?.count == 2_200_000, "restored large file is intact")
        }
        check(fm.fileExists(atPath: small), "file below threshold is untouched")

        // MARK: 重复文件
        let dup = root + "/dups"
        try write(dup + "/a.bin", bytes: 300_000, fill: 1)
        try write(dup + "/sub/b.bin", bytes: 300_000, fill: 1)
        try write(dup + "/c.bin", bytes: 300_000, fill: 2)   // 同大小不同内容
        let groups = DuplicateScanner.scan(minSize: 100_000, roots: [dup],
                                           cancellation: CleanupCancellationToken()) { _, _, _ in }
        check(groups.count == 1 && groups.first?.files.count == 2, "duplicates group identical content only")
        check(groups.first.map { Set($0.files.map(\.name)) } == ["a.bin", "b.bin"], "same-size different file is not a duplicate")

        // MARK: 卸载（夹具应用 + 残留）
        let bundleID = "com.sweepverify." + token.replacingOccurrences(of: "-", with: "")
        let appPath = root + "/Apps/VerifyFixture" + token.suffix(8) + ".app"
        try fm.createDirectory(atPath: appPath + "/Contents/MacOS", withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": "1.0",
                                    "CFBundleName": "VerifyFixture", "CFBundleExecutable": "x"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: appPath + "/Contents/Info.plist"))
        try write(appPath + "/Contents/MacOS/x", bytes: 1000)
        let leftover = home + "/Library/Caches/" + bundleID
        try write(leftover + "/cache.db", bytes: 5000)
        defer { try? fm.removeItem(atPath: leftover) }
        guard let app = UninstallEngine.inspect(path: appPath) else {
            check(false, "fixture app is recognised"); return
        }
        check(app.bundleID == bundleID, "fixture app bundle id is read")
        let leftovers = UninstallEngine.findLeftovers(app: app).map(\.path)
        check(leftovers == [leftover], "leftover search finds exactly the fixture cache")
        if leftovers != [leftover] { print("  leftovers=\(leftovers)") }
        let summary = UninstallEngine.perform([app])
        check(summary.trashed == 1 && summary.adminRemoved == 0 && summary.failed.isEmpty, "fixture app goes to Trash without admin")
        check(!fm.fileExists(atPath: appPath) && !fm.fileExists(atPath: leftover), "app and leftover leave their locations")
        check(summary.leftoverCount == 1, "leftover is counted")
        check(trashed[appPath].map { fm.fileExists(atPath: $0.path) } == true, "uninstalled app is recoverable from Trash")
        if let back = trashed[appPath] {
            try fm.moveItem(at: back, to: URL(fileURLWithPath: appPath))
            check(UninstallEngine.inspect(path: appPath)?.bundleID == bundleID, "uninstalled app restores intact (put back)")
            trashed[appPath] = nil
        }

        // MARK: 历史
        let history = OperationHistory.load()
        check(history.contains { $0.kind == .uninstall && $0.summary.contains("VerifyFixture") }, "uninstall is recorded in (redirected) history")
        check(OperationHistory.directory == logs, "history writes to the redirected log directory")

        // MARK: 优化
        check(!OptimizeCatalog.oneClickTasks.contains { $0.id == "trashEmpty" }, "one-click maintenance never empties the Trash")
        check(!OptimizeCatalog.oneClickTasks.contains { $0.needsAdmin }, "one-click maintenance never asks for admin")
        check(OptimizeCatalog.tasks.first { $0.id == "trashEmpty" }?.irreversible == true, "emptying Trash is marked irreversible")
        let logs30 = root + "/oldlogs"
        try write(logs30 + "/old.log", bytes: 10)
        try write(logs30 + "/olddir/new.log", bytes: 10)
        let old = Date().addingTimeInterval(-40 * 86400)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: logs30 + "/old.log")
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: logs30 + "/olddir")
        let picked = OptimizeCatalog.oldFiles(in: logs30, days: 30)
        check(picked == [logs30 + "/old.log"], "log pruning picks old files only, never old folders holding new logs")

        // MARK: 隐私清理目标
        let privacy = PrivacyCatalog.items().flatMap(\.paths)
        check(!privacy.isEmpty, "privacy catalog has targets")
        check(privacy.allSatisfy { !PathSafety.isProtected(($0 as NSString).standardizingPath) }, "no privacy target is a protected root")
        let outsideLibrary = privacy.filter { !$0.hasPrefix(home + "/Library/") }
        // 除 ~/Library 外只允许两份 shell 历史文件
        check(Set(outsideLibrary).isSubset(of: [home + "/.zsh_history", home + "/.bash_history"]),
              "privacy targets stay inside ~/Library (plus shell history files)")
        if !outsideLibrary.isEmpty { print("  outside=\(outsideLibrary)") }

        print("\(checks - failures)/\(checks) feature checks passed")
        if failures > 0 { exit(1) }
    }
}
