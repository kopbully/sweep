import Foundation
import CryptoKit
import Darwin

// These rules are maintained locally. No third-party rule database is embedded.
struct CleanCategory: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let paths: [String]
    let icon: String
    let safe: Bool
    let appBundleIDs: [String]
    let recommended: Bool
    let reviewReason: String?
    /// true 表示默认不勾选，必须用户自己点选（如废纸篓：删掉就真的没了）
    let explicitOnly: Bool

    init(id: String, title: String, subtitle: String, paths: [String], icon: String, safe: Bool,
         appBundleIDs: [String] = [], recommended: Bool = true, reviewReason: String? = nil,
         explicitOnly: Bool = false) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.paths = paths
        self.icon = icon
        self.safe = safe
        self.appBundleIDs = appBundleIDs
        self.recommended = recommended && safe
        self.reviewReason = reviewReason
        self.explicitOnly = explicitOnly
    }
}

struct CacheItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let category: String
    var size: Int64
    var selected: Bool = false
    let allocatedSize: Int64
    let fileCount: Int
    let canSelect: Bool
    let recommended: Bool
    /// 扫描完成后是否默认勾选：可清理、属于安全类别、且不属于必须手动确认的类别。
    let autoSelected: Bool
    let reason: String?
    let incomplete: Bool
    let hasExternalHardLinks: Bool
    let estimatedReclaimableSize: Int64
    let snapshot: CleanupSnapshot?

    init(id: String, name: String, path: String, category: String, size: Int64,
         selected: Bool = false, allocatedSize: Int64 = 0, fileCount: Int = 0,
         canSelect: Bool = true, recommended: Bool = false, autoSelected: Bool = false,
         reason: String? = nil,
         incomplete: Bool = false, hasExternalHardLinks: Bool = false,
         estimatedReclaimableSize: Int64 = 0, snapshot: CleanupSnapshot? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.category = category
        self.size = size
        self.selected = selected
        self.allocatedSize = allocatedSize
        self.fileCount = fileCount
        self.canSelect = canSelect
        self.recommended = recommended
        self.autoSelected = autoSelected && canSelect
        self.reason = reason
        self.incomplete = incomplete
        self.hasExternalHardLinks = hasExternalHardLinks
        self.estimatedReclaimableSize = estimatedReclaimableSize
        self.snapshot = snapshot
    }
}

/// A scan authorization, created only by this file. UI paths alone do not authorize removal.
struct CleanupSnapshot: Hashable, Sendable {
    fileprivate let home: String
    fileprivate let path: String
    fileprivate let categoryID: String
    fileprivate let pattern: String
    fileprivate let root: CleanupFileIdentity
    fileprivate let ancestors: [CleanupAncestor]
    fileprivate let fingerprint: String
    fileprivate let complete: Bool

    fileprivate init(home: String, path: String, categoryID: String, pattern: String,
                     root: CleanupFileIdentity, ancestors: [CleanupAncestor], fingerprint: String,
                     complete: Bool) {
        self.home = home
        self.path = path
        self.categoryID = categoryID
        self.pattern = pattern
        self.root = root
        self.ancestors = ancestors
        self.fingerprint = fingerprint
        self.complete = complete
    }
}

final class CleanupCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

enum CleanupIssueCode: String, Sendable {
    case invalidPath, permissionDenied, unreadable, symlink, crossVolume
    case cloudPlaceholder, excluded, runningApplication, changed, cancelled
}

struct CleanupIssue: Hashable, Sendable {
    let path: String
    let message: String
    let code: CleanupIssueCode
}

struct CleanupProgress: Sendable {
    var phase: String = "扫描"
    var filesScanned: Int = 0
    var currentPath: String = ""
    var targetsCompleted: Int = 0
    var targetsTotal: Int = 0
}

struct CleanupScanResult: Sendable {
    let items: [CacheItem]
    let issues: [CleanupIssue]
    let cancelled: Bool
    let progress: CleanupProgress
    let elapsed: TimeInterval
}

enum CleanupOutcomeStatus: String, Sendable {
    case removed, missing, changed, blocked, failed, cancelled
}

struct CleanupOutcome: Sendable {
    let path: String
    let status: CleanupOutcomeStatus
    let message: String
    let removedBytes: Int64
    let estimatedReclaimedBytes: Int64
}

struct CleanupReport: Sendable {
    let outcomes: [CleanupOutcome]
    let removedBytes: Int64
    let estimatedReclaimedBytes: Int64
    let cancelled: Bool
    var successfulCount: Int { outcomes.filter { $0.status == .removed }.count }
    var failedCount: Int { outcomes.filter { [.failed, .blocked, .changed].contains($0.status) }.count }
    var missingCount: Int { outcomes.filter { $0.status == .missing }.count }
}

enum CleanCatalog {
    static let categories: [CleanCategory] = [
        CleanCategory(id: "chrome", title: "Chrome 缓存", subtitle: "关闭 Chrome 后可重新生成",
                      paths: ["~/Library/Caches/Google/Chrome"], icon: "globe", safe: true,
                      appBundleIDs: ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary"]),
        CleanCategory(id: "firefox", title: "Firefox 缓存", subtitle: "仅 cache2，不包含浏览器资料",
                      paths: ["~/Library/Caches/Firefox/Profiles/*/cache2"], icon: "globe", safe: true,
                      appBundleIDs: ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"]),
        CleanCategory(id: "edge", title: "Edge 缓存", subtitle: "关闭 Edge 后可重新生成",
                      paths: ["~/Library/Caches/Microsoft Edge"], icon: "globe", safe: true,
                      appBundleIDs: ["com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary"]),
        CleanCategory(id: "safari", title: "Safari 缓存", subtitle: "仅明确缓存，保留网页资料与登录状态",
                      paths: ["~/Library/Caches/com.apple.Safari"],
                      icon: "globe", safe: true, appBundleIDs: ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]),
        CleanCategory(id: "appCaches", title: "其他应用缓存", subtitle: "逐项检查；不默认推荐清理",
                      paths: ["~/Library/Caches/*"], icon: "shippingbox", safe: true, recommended: false,
                      reviewReason: "应用缓存由各应用自行管理，可能含离线或同步状态；请逐项确认"),
        CleanCategory(id: "slack", title: "Slack 缓存", subtitle: "关闭 Slack 后可重新生成",
                      paths: ["~/Library/Caches/com.tinyspeck.slackmacgap"], icon: "shippingbox", safe: true,
                      appBundleIDs: ["com.tinyspeck.slackmacgap"]),
        CleanCategory(id: "devXcode", title: "Xcode 构建缓存", subtitle: "DerivedData，不包含 Archives 与设备支持资料",
                      paths: ["~/Library/Developer/Xcode/DerivedData"], icon: "hammer", safe: true,
                      appBundleIDs: ["com.apple.dt.Xcode"]),
        CleanCategory(id: "simulator", title: "Simulator 缓存", subtitle: "仅 CoreSimulator/Caches，保留模拟器设备",
                      paths: ["~/Library/Developer/CoreSimulator/Caches"], icon: "hammer", safe: true,
                      appBundleIDs: ["com.apple.iphonesimulator", "com.apple.dt.Xcode"]),
        CleanCategory(id: "npm", title: "npm 缓存", subtitle: "仅内容缓存，不扫描项目依赖",
                      paths: ["~/.npm/_cacache"], icon: "terminal", safe: true),
        CleanCategory(id: "uv", title: "uv 缓存", subtitle: "下载与构建缓存，可重新生成",
                      paths: ["~/.cache/uv"], icon: "terminal", safe: true),
        CleanCategory(id: "pip", title: "pip 缓存", subtitle: "下载与 wheel 缓存，可重新生成",
                      paths: ["~/Library/Caches/pip", "~/.cache/pip"], icon: "terminal", safe: true),
        CleanCategory(id: "homebrew", title: "Homebrew 缓存", subtitle: "下载缓存，保留已安装软件",
                      paths: ["~/Library/Caches/Homebrew"], icon: "terminal", safe: true),
        CleanCategory(id: "gradle", title: "Gradle 缓存", subtitle: "可重新下载与构建的缓存",
                      paths: ["~/.gradle/caches"], icon: "terminal", safe: true),
        CleanCategory(id: "cargo", title: "Cargo 缓存", subtitle: "crates 下载缓存与 git 索引，不影响已编译产物",
                      paths: ["~/.cargo/registry/cache", "~/.cargo/git/db"], icon: "terminal", safe: true),
        CleanCategory(id: "go", title: "Go 构建缓存", subtitle: "go-build 编译缓存，下次编译自动重建",
                      paths: ["~/Library/Caches/go-build"], icon: "terminal", safe: true),
        CleanCategory(id: "cocoapods", title: "CocoaPods 缓存", subtitle: "下载的 pod 压缩包，可重新拉取",
                      paths: ["~/Library/Caches/CocoaPods"], icon: "hammer", safe: true),
        CleanCategory(id: "swiftpm", title: "SwiftPM 缓存", subtitle: "依赖下载缓存，保留项目内 Package.resolved",
                      paths: ["~/Library/Caches/org.swift.swiftpm"], icon: "hammer", safe: true),
        CleanCategory(id: "jetbrains", title: "JetBrains 缓存", subtitle: "IDE 索引与编译缓存，首次打开项目会重建",
                      paths: ["~/Library/Caches/JetBrains"], icon: "hammer", safe: true,
                      appBundleIDs: ["com.jetbrains.intellij", "com.jetbrains.pycharm", "com.jetbrains.WebStorm", "com.jetbrains.AppCode"]),
        CleanCategory(id: "vscode", title: "VS Code 缓存", subtitle: "仅缓存目录，保留设置、插件与工作区",
                      paths: ["~/Library/Application Support/Code/Cache", "~/Library/Application Support/Code/CachedData",
                              "~/Library/Application Support/Code/GPUCache", "~/Library/Application Support/Code/Code Cache"],
                      icon: "hammer", safe: true, appBundleIDs: ["com.microsoft.VSCode"]),
        CleanCategory(id: "yarn", title: "Yarn 缓存", subtitle: "包下载缓存，不扫描项目依赖",
                      paths: ["~/Library/Caches/Yarn"], icon: "terminal", safe: true),
        CleanCategory(id: "pnpmCache", title: "pnpm 缓存", subtitle: "元数据与下载缓存，可重新获取",
                      paths: ["~/Library/Caches/pnpm"], icon: "terminal", safe: true),
        CleanCategory(id: "pnpmStore", title: "pnpm 全局存储", subtitle: "内容寻址仓库，清理后项目首次安装会重新链接",
                      paths: ["~/Library/pnpm/store"], icon: "terminal", safe: true, recommended: false,
                      reviewReason: "已有项目依赖通过硬链接指向该仓库；清理不会破坏现有 node_modules，但下次安装需要重新下载"),
        CleanCategory(id: "browserAutomation", title: "浏览器自动化缓存", subtitle: "Playwright / Cypress / Selenium 下载的浏览器",
                      paths: ["~/Library/Caches/ms-playwright", "~/Library/Caches/Cypress", "~/.cache/selenium"],
                      icon: "globe", safe: true),
        CleanCategory(id: "electronBuilder", title: "electron-builder 缓存", subtitle: "打包用 Electron 运行时，可重新下载",
                      paths: ["~/Library/Caches/electron-builder"], icon: "shippingbox", safe: true),
        CleanCategory(id: "xcodeAux", title: "Xcode 辅助缓存", subtitle: "文档索引与设备日志，不含 Archives 与设备支持",
                      paths: ["~/Library/Developer/Xcode/DocumentationCache", "~/Library/Developer/Xcode/DocumentationIndex",
                              "~/Library/Developer/Xcode/iOS Device Logs", "~/Library/Developer/Xcode/watchOS Device Logs"],
                      icon: "hammer", safe: true, appBundleIDs: ["com.apple.dt.Xcode"]),
    ]

    static func scanTargets(categories: [CleanCategory] = categories) -> [(path: String, category: String)] {
        resolve(categories: categories, home: NSHomeDirectory(), enforceSafety: false, cancellation: nil).targets.map { ($0.path, $0.category.title) }
    }

    fileprivate struct Target {
        let path: String
        let pattern: String
        let category: CleanCategory
    }

    /// Both production scanning and the compatibility helper use this expansion and overlap policy.
    fileprivate static func resolve(categories: [CleanCategory], home: String,
                                    enforceSafety: Bool,
                                    cancellation: CleanupCancellationToken?) -> (targets: [Target], issues: [CleanupIssue]) {
        let ordered = categories.filter { $0.id != "appCaches" } + categories.filter { $0.id == "appCaches" }
        var seen = Set<String>()
        var targets: [Target] = []
        var issues: [CleanupIssue] = []
        for category in ordered {
            for rawPattern in category.paths {
                if cancellation?.isCancelled == true { break }
                let pattern = CleanupPathRules.expand(rawPattern, home: home)
                guard !pattern.contains("\0"), pattern.hasPrefix("/"),
                      pattern.split(separator: "/").allSatisfy({ !$0.contains("*") || $0 == "*" }) else {
                    issues.append(CleanupIssue(path: pattern, message: "规则路径格式不受支持", code: .invalidPath))
                    continue
                }
                var partial = ["/"]
                for component in pattern.split(separator: "/").map(String.init) {
                    if component != "*" {
                        partial = partial.map { URL(fileURLWithPath: $0).appendingPathComponent(component).path }
                        continue
                    }
                    var expanded: [String] = []
                    for directory in partial {
                        if cancellation?.isCancelled == true { break }
                        if enforceSafety, let issue = CleanupPathRules.validationIssue(directory, home: home, listing: true) {
                            issues.append(issue)
                            continue
                        }
                        do {
                            let names: [String]
                            if enforceSafety {
                                let descriptor = try CleanupFileSystem.openAbsoluteDirectory(directory)
                                defer { close(descriptor) }
                                names = try CleanupFileSystem.names(in: descriptor, cancellation: cancellation)
                            } else {
                                // The compatibility helper also accepts temporary fixture paths
                                // such as /var/folders, whose prefix is a platform symlink.
                                names = try FileManager.default.contentsOfDirectory(atPath: directory)
                            }
                            expanded.append(contentsOf: names.map { URL(fileURLWithPath: directory).appendingPathComponent($0).path })
                        } catch let error as CleanupFileError {
                            if error.number != ENOENT { issues.append(error.issue(path: directory)) }
                        } catch {
                            issues.append(CleanupIssue(path: directory, message: error.localizedDescription, code: .unreadable))
                        }
                    }
                    partial = expanded
                }
                for candidate in partial {
                    let path = (candidate as NSString).standardizingPath
                    if enforceSafety {
                        do {
                            _ = try CleanupFileSystem.context(path: path, home: home)
                        } catch let error as CleanupFileError where error.number == ENOENT {
                            continue
                        } catch CleanupInspectionError.issue {
                            if seen.insert(path).inserted { targets.append(Target(path: path, pattern: pattern, category: category)) }
                            continue
                        } catch let error as CleanupFileError where error.number != ENOENT {
                            if seen.insert(path).inserted { targets.append(Target(path: path, pattern: pattern, category: category)) }
                            continue
                        } catch {
                            issues.append(CleanupIssue(path: path, message: error.localizedDescription, code: .unreadable))
                            continue
                        }
                    }
                    if seen.insert(path).inserted { targets.append(Target(path: path, pattern: pattern, category: category)) }
                }
            }
        }
        // Keeping the narrower target avoids a selected parent deleting an unselected child.
        let nonoverlapping = targets.filter { outer in
            !targets.contains { inner in inner.path != outer.path && inner.path.hasPrefix(outer.path + "/") }
        }
        return (nonoverlapping, issues)
    }

    fileprivate static func category(for snapshot: CleanupSnapshot, categories: [CleanCategory], home: String) -> CleanCategory? {
        categories.first { category in
            category.id == snapshot.categoryID && category.paths.contains { raw in
                let pattern = CleanupPathRules.expand(raw, home: home)
                guard pattern == snapshot.pattern else { return false }
                let a = pattern.split(separator: "/")
                let b = snapshot.path.split(separator: "/")
                return a.count == b.count && zip(a, b).allSatisfy { $0 == "*" || $0 == $1 }
            }
        }
    }
}

fileprivate enum CleanupPathRules {
    static func canonicalHome(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).standardizingPath, isDirectory: true).resolvingSymlinksInPath().path
    }

    static func expand(_ pattern: String, home: String) -> String {
        let expanded: String
        if pattern == "~" { expanded = home }
        else if pattern.hasPrefix("~/") { expanded = home + String(pattern.dropFirst()) }
        else { expanded = pattern }
        return (expanded as NSString).standardizingPath
    }

    static func validationIssue(_ path: String, home: String, listing: Bool = false) -> CleanupIssue? {
        guard home != "/", path.hasPrefix(home + "/"), !path.contains("\0") else {
            return CleanupIssue(path: path, message: "路径超出本地用户缓存范围", code: .invalidPath)
        }
        let relative = String(path.dropFirst(home.count + 1))
        let roots = ["Library/Caches", "Library/Developer/Xcode/DerivedData",
                     "Library/Developer/CoreSimulator/Caches", ".npm/_cacache", ".cache/uv", ".cache/pip",
                     ".gradle/caches", "Library/Containers/com.apple.Safari/Data/Library/Caches/com.apple.Safari"]
        guard roots.contains(where: { root in
            relative.hasPrefix(root + "/") || (relative == root && (listing || root != "Library/Caches"))
        }) else {
            return CleanupIssue(path: path, message: "路径未通过明确缓存边界校验", code: .invalidPath)
        }
        let components = relative.split(separator: "/").map { $0.lowercased() }
        let protectedNames = Set(["com.sweep.macos", "com.apple.bird", "com.apple.cloudd", "com.apple.clouddocs",
                                  "com.apple.nsurlsessiond",
                                  "node_modules", ".venv", "venv", "huggingface", "torch", "ollama", "lmstudio", "models"])
        if components.contains(where: { component in
            protectedNames.contains(component) || component.contains("cloudkit") || component.contains("fileprovider") ||
            component.contains("icloud") || component.contains("syncstate") || component.contains("sync-state") ||
            component.contains("onedrive") || component.contains("dropbox")
        }) {
            return CleanupIssue(path: path, message: "已排除应用自身、同步状态、模型或项目依赖目录", code: .excluded)
        }
        return nil
    }

    static func runningIssue(path: String, category: CleanCategory, bundleIDs: Set<String>,
                             processNames: Set<String>? = []) -> CleanupIssue? {
        let directoryName = (path as NSString).lastPathComponent
        let active = category.appBundleIDs.filter { bundleIDs.contains($0) }
        let matchingDirectory = bundleIDs.first { $0.caseInsensitiveCompare(directoryName) == .orderedSame }
        let activeIDs = active + (matchingDirectory.map { [ $0 ] } ?? [])
        if !activeIDs.isEmpty {
            return CleanupIssue(path: path, message: "关联应用正在运行，请退出后重新扫描：" + Array(Set(activeIDs)).sorted().joined(separator: ", "), code: .runningApplication)
        }
        guard let guarded = CleanupProcessActivity.guardedNames(for: category.id) else { return nil }
        guard let processNames else {
            return CleanupIssue(path: path, message: "无法确认构建或模拟器进程状态，此项已保留", code: .runningApplication)
        }
        let activeProcesses = processNames.intersection(guarded).sorted()
        guard !activeProcesses.isEmpty else { return nil }
        return CleanupIssue(path: path, message: "关联进程正在运行，请等待结束后重新扫描：" + activeProcesses.joined(separator: ", "), code: .runningApplication)
    }
}

enum CleanupProcessActivity {
    static func guardedNames(for categoryID: String) -> Set<String>? {
        switch categoryID {
        case "devXcode": return ["xcodebuild", "xcbuild", "xcbbuildservice", "xcbbuildserviceagent", "xctest"]
        case "simulator": return ["simctl"]
        default: return nil
        }
    }

    static func currentNames() -> Set<String>? {
        guard let processes = try? ProcList.fetch() else { return nil }
        return Set(processes.map { $0.name.lowercased() })
    }
}

fileprivate struct CleanupFileIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let kind: UInt32

    init(_ value: stat) {
        device = UInt64(bitPattern: Int64(value.st_dev))
        inode = UInt64(value.st_ino)
        kind = UInt32(value.st_mode & S_IFMT)
    }
}

fileprivate struct CleanupMetadataSnapshot: Sendable {
    let identity: CleanupFileIdentity
    let mode: UInt32
    let size: Int64
    let blocks: Int64
    let linkCount: UInt64
    let flags: UInt32
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(_ value: stat) {
        identity = CleanupFileIdentity(value)
        mode = UInt32(value.st_mode)
        size = Int64(value.st_size)
        blocks = Int64(value.st_blocks)
        linkCount = UInt64(value.st_nlink)
        flags = UInt32(value.st_flags)
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }

    func matches(_ value: stat, removedLinks: Int = 0) -> Bool {
        identity == CleanupFileIdentity(value) && mode == UInt32(value.st_mode) &&
        size == Int64(value.st_size) && blocks == Int64(value.st_blocks) &&
        UInt64(value.st_nlink) == linkCount - UInt64(max(0, removedLinks)) && flags == UInt32(value.st_flags) &&
        modifiedSeconds == Int64(value.st_mtimespec.tv_sec) &&
        modifiedNanoseconds == Int64(value.st_mtimespec.tv_nsec) &&
        (removedLinks > 0 || (changedSeconds == Int64(value.st_ctimespec.tv_sec) &&
                             changedNanoseconds == Int64(value.st_ctimespec.tv_nsec)))
    }
}

fileprivate struct CleanupManifestEntry: Sendable {
    let relativePath: String
    let metadata: CleanupMetadataSnapshot
}

fileprivate struct CleanupAncestor: Hashable, Sendable {
    let path: String
    let identity: CleanupFileIdentity
}

fileprivate struct CleanupFileError: Error {
    let number: Int32
    let detail: String
    init(_ detail: String, number: Int32 = errno) {
        self.number = number
        self.detail = detail
    }
    func issue(path: String) -> CleanupIssue {
        CleanupIssue(path: path, message: detail + "：" + String(cString: strerror(number)),
                     code: number == EACCES || number == EPERM ? .permissionDenied : .unreadable)
    }
}

fileprivate enum CleanupInspectionError: Error {
    case issue(CleanupIssue)
}

fileprivate final class CleanupContext {
    let parentDescriptor: Int32
    let name: String
    let root: stat
    let ancestors: [CleanupAncestor]
    let device: dev_t
    init(parentDescriptor: Int32, name: String, root: stat, ancestors: [CleanupAncestor], device: dev_t) {
        self.parentDescriptor = parentDescriptor
        self.name = name
        self.root = root
        self.ancestors = ancestors
        self.device = device
    }
    deinit { close(parentDescriptor) }
}

fileprivate enum CleanupFileSystem {
    static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    static func openAbsoluteDirectory(_ path: String) throws -> Int32 {
        var descriptor = open("/", directoryFlags)
        guard descriptor >= 0 else { throw CleanupFileError("读取根目录失败") }
        do {
            for component in path.split(separator: "/") {
                let next = openat(descriptor, String(component), directoryFlags)
                guard next >= 0 else { throw CleanupFileError("读取目录失败") }
                close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    static func names(in descriptor: Int32, cancellation: CleanupCancellationToken? = nil) throws -> [String] {
        let copy = dup(descriptor)
        guard copy >= 0 else { throw CleanupFileError("读取目录句柄失败") }
        guard let directory = fdopendir(copy) else {
            let failure = CleanupFileError("读取目录失败")
            close(copy)
            throw failure
        }
        defer { closedir(directory) }
        var names: [String] = []
        errno = 0
        while cancellation?.isCancelled != true, let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { names.append(name) }
            errno = 0
        }
        if errno != 0 { throw CleanupFileError("列出目录失败") }
        return cancellation?.isCancelled == true ? names : names.sorted()
    }

    static func context(path: String, home: String) throws -> CleanupContext {
        if let issue = CleanupPathRules.validationIssue(path, home: home) { throw CleanupInspectionError.issue(issue) }
        var descriptor = try openAbsoluteDirectory(home)
        do {
            var homeStat = stat()
            guard fstat(descriptor, &homeStat) == 0 else { throw CleanupFileError("读取用户目录身份失败") }
            let components = String(path.dropFirst(home.count + 1)).split(separator: "/").map(String.init)
            var ancestors = [CleanupAncestor(path: home, identity: CleanupFileIdentity(homeStat))]
            var parentPath = home
            for component in components.dropLast() {
                parentPath = URL(fileURLWithPath: parentPath).appendingPathComponent(component).path
                var value = stat()
                guard fstatat(descriptor, component, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw CleanupFileError("读取父目录失败") }
                if value.st_mode & S_IFMT == S_IFLNK {
                    throw CleanupInspectionError.issue(CleanupIssue(path: parentPath, message: "父目录是符号链接，已跳过", code: .symlink))
                }
                guard value.st_dev == homeStat.st_dev else {
                    throw CleanupInspectionError.issue(CleanupIssue(path: parentPath, message: "父目录跨越文件系统卷，已跳过", code: .crossVolume))
                }
                let next = openat(descriptor, component, directoryFlags)
                guard next >= 0 else { throw CleanupFileError("打开父目录失败") }
                var opened = stat()
                if fstat(next, &opened) != 0 || CleanupFileIdentity(opened) != CleanupFileIdentity(value) {
                    close(next)
                    throw CleanupInspectionError.issue(CleanupIssue(path: parentPath, message: "父目录在检查期间发生变化", code: .changed))
                }
                close(descriptor)
                descriptor = next
                ancestors.append(CleanupAncestor(path: parentPath, identity: CleanupFileIdentity(value)))
            }
            guard let name = components.last else { throw CleanupFileError("候选路径为空", number: EINVAL) }
            var root = stat()
            guard fstatat(descriptor, name, &root, AT_SYMLINK_NOFOLLOW) == 0 else { throw CleanupFileError("读取候选身份失败") }
            return CleanupContext(parentDescriptor: descriptor, name: name, root: root, ancestors: ancestors, device: homeStat.st_dev)
        } catch {
            close(descriptor)
            throw error
        }
    }

    static func cloudPlaceholder(_ value: stat, name: String) -> Bool {
        // SF_DATALESS identifies an APFS/File Provider placeholder without reading file data.
        (value.st_flags & UInt32(SF_DATALESS)) != 0 || (name.hasPrefix(".") && name.hasSuffix(".icloud"))
    }

    static func sameMetadata(_ a: stat, _ b: stat) -> Bool {
        CleanupFileIdentity(a) == CleanupFileIdentity(b) && a.st_mode == b.st_mode && a.st_size == b.st_size &&
        a.st_blocks == b.st_blocks && a.st_nlink == b.st_nlink && a.st_flags == b.st_flags &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }

    /// Descriptor-relative removal keeps parent aliases and nested links outside the deletion walk.
    static func remove(parent: Int32, name: String, device: dev_t, home: String, rootPath: String,
                       relativePath: String, expectedParent: CleanupFileIdentity,
                       manifest: [CleanupManifestEntry], manifestIndex: inout Int,
                       removedHardLinks: inout [CleanupFileIdentity: Int],
                       activityIssue: (() -> CleanupIssue?)? = nil,
                       afterDirectoryOpen: ((String) -> Void)? = nil) throws {
        let fullPath = relativePath.isEmpty ? rootPath : rootPath + "/" + relativePath
        if let issue = activityIssue?() { throw CleanupInspectionError.issue(issue) }
        if let issue = CleanupPathRules.validationIssue(fullPath, home: home) {
            throw CleanupInspectionError.issue(issue)
        }
        guard manifestIndex < manifest.count,
              manifest[manifestIndex].relativePath == relativePath else {
            throw CleanupInspectionError.issue(CleanupIssue(path: fullPath, message: "发现扫描后新增或变更的条目，此项保留", code: .changed))
        }
        let expected = manifest[manifestIndex].metadata
        manifestIndex += 1
        let removedLinks = removedHardLinks[expected.identity, default: 0]

        let parentPath = (fullPath as NSString).deletingLastPathComponent
        guard try directoryDescriptor(parent, isAt: parentPath, expected: expectedParent) else {
            throw CleanupInspectionError.issue(CleanupIssue(path: parentPath, message: "父目录已移动或替换，此项保留", code: .changed))
        }
        var value = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw CleanupFileError("删除前读取身份失败") }
        guard expected.matches(value, removedLinks: removedLinks) else {
            throw CleanupInspectionError.issue(CleanupIssue(path: fullPath, message: "删除前条目元数据已变化，此项保留", code: .changed))
        }
        guard value.st_dev == device, value.st_mode & S_IFMT != S_IFLNK,
              !cloudPlaceholder(value, name: name) else {
            throw CleanupInspectionError.issue(CleanupIssue(path: fullPath, message: "删除期间出现链接、跨卷对象或云占位文件", code: .changed))
        }
        let kind = value.st_mode & S_IFMT
        if kind == S_IFDIR {
            let descriptor = openat(parent, name, directoryFlags)
            guard descriptor >= 0 else { throw CleanupFileError("打开待删除目录失败") }
            defer { close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, expected.matches(opened, removedLinks: removedLinks) else {
                throw CleanupInspectionError.issue(CleanupIssue(path: fullPath, message: "待删除目录身份发生变化", code: .changed))
            }
            afterDirectoryOpen?(fullPath)
            for child in try names(in: descriptor) {
                let childRelative = relativePath.isEmpty ? child : relativePath + "/" + child
                try remove(parent: descriptor, name: child, device: device, home: home, rootPath: rootPath,
                           relativePath: childRelative, expectedParent: expected.identity,
                           manifest: manifest, manifestIndex: &manifestIndex,
                           removedHardLinks: &removedHardLinks, activityIssue: activityIssue,
                           afterDirectoryOpen: afterDirectoryOpen)
            }
            if let issue = activityIssue?() { throw CleanupInspectionError.issue(issue) }
            var final = stat()
            guard fstatat(parent, name, &final, AT_SYMLINK_NOFOLLOW) == 0,
                  CleanupFileIdentity(final) == CleanupFileIdentity(value) else {
                throw CleanupInspectionError.issue(CleanupIssue(path: fullPath, message: "删除目录前身份发生变化", code: .changed))
            }
            guard try directoryDescriptor(parent, isAt: parentPath, expected: expectedParent) else {
                throw CleanupInspectionError.issue(CleanupIssue(path: parentPath, message: "父目录已移动或替换，此项保留", code: .changed))
            }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw CleanupFileError("移除目录失败") }
        } else if kind == S_IFREG {
            if let issue = activityIssue?() { throw CleanupInspectionError.issue(issue) }
            var final = stat()
            guard fstatat(parent, name, &final, AT_SYMLINK_NOFOLLOW) == 0,
                  expected.matches(final, removedLinks: removedLinks),
                  try directoryDescriptor(parent, isAt: parentPath, expected: expectedParent) else {
                throw CleanupInspectionError.issue(CleanupIssue(path: fullPath, message: "文件或父目录在删除前发生变化，此项保留", code: .changed))
            }
            guard unlinkat(parent, name, 0) == 0 else { throw CleanupFileError("移除文件失败") }
            if expected.linkCount > 1 { removedHardLinks[expected.identity] = removedLinks + 1 }
        } else {
            throw CleanupInspectionError.issue(CleanupIssue(path: fullPath, message: "仅清理普通缓存文件与目录", code: .excluded))
        }
    }

    private static func directoryDescriptor(_ descriptor: Int32, isAt path: String,
                                            expected: CleanupFileIdentity) throws -> Bool {
        let named: Int32
        do {
            named = try openAbsoluteDirectory(path)
        } catch let error as CleanupFileError where error.number == ENOENT {
            throw CleanupInspectionError.issue(CleanupIssue(path: path, message: "父目录已移出候选路径，此项保留", code: .changed))
        }
        defer { close(named) }
        var held = stat()
        var current = stat()
        guard fstat(descriptor, &held) == 0, fstat(named, &current) == 0 else {
            throw CleanupFileError("重验父目录身份失败")
        }
        return CleanupFileIdentity(held) == expected && CleanupFileIdentity(current) == expected
    }
}

fileprivate final class CleanupProgressReporter {
    var value: CleanupProgress
    private let callback: ((CleanupProgress) -> Void)?
    private var lastEmission = -Double.infinity

    init(phase: String, total: Int = 0, callback: ((CleanupProgress) -> Void)?) {
        value = CleanupProgress(phase: phase, targetsTotal: total)
        self.callback = callback
    }

    func emit(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        if force || now - lastEmission >= 0.1 {
            lastEmission = now
            callback?(value)
        }
    }
}

fileprivate struct CleanupHardLink {
    var occurrences: Int
    let links: Int
    let logical: Int64
    let allocated: Int64
}

fileprivate struct CleanupMeasurement {
    let fingerprint: String
    let root: stat
    let logical: Int64
    let allocated: Int64
    let fileCount: Int
    let reclaimable: Int64
    let hardLinks: [CleanupFileIdentity: CleanupHardLink]
    let manifest: [CleanupManifestEntry]
    let issues: [CleanupIssue]
    let cancelled: Bool
    var complete: Bool { issues.isEmpty && !cancelled }
    var hasExternalHardLinks: Bool { hardLinks.values.contains { $0.occurrences < $0.links } }

    func deduplicated(excluding seen: inout Set<CleanupFileIdentity>) -> (logical: Int64, allocated: Int64, files: Int, reclaimable: Int64) {
        var bytes = logical
        var blocks = allocated
        var files = fileCount
        var possible = reclaimable
        for (identity, link) in hardLinks {
            if !seen.insert(identity).inserted {
                bytes -= link.logical
                blocks -= link.allocated
                files -= 1
                if link.occurrences >= link.links { possible -= link.allocated }
            }
        }
        return (max(0, bytes), max(0, blocks), max(0, files), max(0, possible))
    }
}

/// The walk is serial and bounded by tree depth. It never reads file contents or follows links.
fileprivate final class CleanupWalker {
    let path: String
    let home: String
    let context: CleanupContext
    let cancellation: CleanupCancellationToken
    let reporter: CleanupProgressReporter
    private var hash = SHA256()
    private var logical: Int64 = 0
    private var allocated: Int64 = 0
    private var fileCount = 0
    private var reclaimable: Int64 = 0
    private var hardLinks: [CleanupFileIdentity: CleanupHardLink] = [:]
    private let captureManifest: Bool
    private var manifest: [CleanupManifestEntry] = []
    private var manifestLimitReached = false
    private var issues: [CleanupIssue] = []
    private static let maximumManifestEntries = 250_000

    init(path: String, home: String, context: CleanupContext,
         cancellation: CleanupCancellationToken, reporter: CleanupProgressReporter,
         captureManifest: Bool = false) {
        self.path = path
        self.home = home
        self.context = context
        self.cancellation = cancellation
        self.reporter = reporter
        self.captureManifest = captureManifest
    }

    func measure() -> CleanupMeasurement {
        walk(parent: context.parentDescriptor, name: context.name, relative: "", initial: context.root)
        if !cancellation.isCancelled {
            var current = stat()
            if fstatat(context.parentDescriptor, context.name, &current, AT_SYMLINK_NOFOLLOW) != 0 ||
                !CleanupFileSystem.sameMetadata(current, context.root) {
                issues.append(CleanupIssue(path: path, message: "候选在扫描期间发生变化，请重新扫描", code: .changed))
            }
        }
        for link in hardLinks.values {
            logical += link.logical
            allocated += link.allocated
            fileCount += 1
            if link.occurrences >= link.links { reclaimable += link.allocated }
        }
        return CleanupMeasurement(fingerprint: hash.finalize().map { String(format: "%02x", $0) }.joined(),
                                  root: context.root, logical: logical, allocated: allocated, fileCount: fileCount,
                                  reclaimable: reclaimable, hardLinks: hardLinks, manifest: manifest, issues: issues,
                                  cancelled: cancellation.isCancelled)
    }

    private func record(_ value: stat, relative: String) {
        hash.update(data: Data(relative.utf8))
        hash.update(data: Data([0]))
        let numbers: [UInt64] = [
            UInt64(bitPattern: Int64(value.st_dev)), UInt64(value.st_ino), UInt64(value.st_mode),
            UInt64(bitPattern: Int64(value.st_size)), UInt64(bitPattern: Int64(value.st_blocks)), UInt64(value.st_nlink),
            UInt64(bitPattern: Int64(value.st_mtimespec.tv_sec)), UInt64(bitPattern: Int64(value.st_mtimespec.tv_nsec)),
            UInt64(bitPattern: Int64(value.st_ctimespec.tv_sec)), UInt64(bitPattern: Int64(value.st_ctimespec.tv_nsec)),
            UInt64(value.st_flags),
        ]
        for number in numbers {
            var fixed = number.littleEndian
            withUnsafeBytes(of: &fixed) { hash.update(data: Data($0)) }
        }
    }

    private func walk(parent: Int32, name: String, relative: String, initial value: stat) {
        guard !cancellation.isCancelled, !manifestLimitReached else { return }
        let fullPath = relative.isEmpty ? path : path + "/" + relative
        reporter.value.currentPath = fullPath
        reporter.emit()
        record(value, relative: relative)
        if captureManifest {
            guard manifest.count < Self.maximumManifestEntries else {
                manifestLimitReached = true
                issues.append(CleanupIssue(path: path, message: "条目数超过 250,000 上限，无法建立逐项复核清单；此项保留", code: .unreadable))
                return
            }
            manifest.append(CleanupManifestEntry(relativePath: relative, metadata: CleanupMetadataSnapshot(value)))
        }
        guard value.st_dev == context.device else {
            issues.append(CleanupIssue(path: fullPath, message: "跨越文件系统卷，已跳过；所属目录保留", code: .crossVolume))
            return
        }
        let kind = value.st_mode & S_IFMT
        if kind == S_IFLNK {
            issues.append(CleanupIssue(path: fullPath, message: "符号链接已跳过；所属目录保留", code: .symlink))
            return
        }
        if CleanupFileSystem.cloudPlaceholder(value, name: name) {
            issues.append(CleanupIssue(path: fullPath, message: "云占位文件已跳过；所属目录保留", code: .cloudPlaceholder))
            return
        }
        if let issue = CleanupPathRules.validationIssue(fullPath, home: home) {
            issues.append(issue)
            return
        }
        if kind == S_IFREG {
            reporter.value.filesScanned += 1
            let bytes = max(0, Int64(value.st_size))
            let blocks = max(0, Int64(value.st_blocks)) * 512
            if value.st_nlink > 1 {
                let identity = CleanupFileIdentity(value)
                if var prior = hardLinks[identity] {
                    prior.occurrences += 1
                    hardLinks[identity] = prior
                } else {
                    hardLinks[identity] = CleanupHardLink(occurrences: 1, links: Int(value.st_nlink), logical: bytes, allocated: blocks)
                }
            } else {
                logical += bytes
                allocated += blocks
                fileCount += 1
                reclaimable += blocks
            }
            reporter.emit()
            return
        }
        guard kind == S_IFDIR else {
            issues.append(CleanupIssue(path: fullPath, message: "特殊文件已跳过；所属目录保留", code: .excluded))
            return
        }
        let descriptor = openat(parent, name, CleanupFileSystem.directoryFlags)
        guard descriptor >= 0 else {
            issues.append(CleanupFileError("打开缓存目录失败").issue(path: fullPath))
            return
        }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, CleanupFileSystem.sameMetadata(value, opened) else {
            issues.append(CleanupIssue(path: fullPath, message: "目录在打开期间发生变化", code: .changed))
            return
        }
        do {
            let names = try CleanupFileSystem.names(in: descriptor, cancellation: cancellation)
            for child in names {
                guard !cancellation.isCancelled else { return }
                var childStat = stat()
                let childRelative = relative.isEmpty ? child : relative + "/" + child
                guard fstatat(descriptor, child, &childStat, AT_SYMLINK_NOFOLLOW) == 0 else {
                    issues.append(CleanupFileError("读取缓存条目失败").issue(path: path + "/" + childRelative))
                    continue
                }
                walk(parent: descriptor, name: child, relative: childRelative, initial: childStat)
            }
        } catch let error as CleanupFileError {
            issues.append(error.issue(path: fullPath))
        } catch {
            issues.append(CleanupIssue(path: fullPath, message: error.localizedDescription, code: .unreadable))
        }
        var final = stat()
        if !cancellation.isCancelled && (fstat(descriptor, &final) != 0 || !CleanupFileSystem.sameMetadata(value, final)) {
            issues.append(CleanupIssue(path: fullPath, message: "目录内容在扫描期间发生变化", code: .changed))
        }
    }
}

enum CleanupScanner {
    static func scan(categories: [CleanCategory] = CleanCatalog.categories, home: String = NSHomeDirectory(),
                     runningBundleIDs: Set<String> = [],
                     processNames: Set<String>? = nil,
                     cancellation: CleanupCancellationToken = CleanupCancellationToken(),
                     progress: ((CleanupProgress) -> Void)? = nil) -> CleanupScanResult {
        let started = ProcessInfo.processInfo.systemUptime
        let trustedHome = CleanupPathRules.canonicalHome(home)
        let reporter = CleanupProgressReporter(phase: "扫描", callback: progress)
        reporter.emit(force: true)
        var items: [CacheItem] = []
        var issues: [CleanupIssue] = []
        let needsProcessList = categories.contains { CleanupProcessActivity.guardedNames(for: $0.id) != nil }
        let currentProcessNames: Set<String>?
        if let processNames { currentProcessNames = processNames }
        else if needsProcessList { currentProcessNames = CleanupProcessActivity.currentNames() }
        else { currentProcessNames = [] }
        if !cancellation.isCancelled {
            let resolved = CleanCatalog.resolve(categories: categories, home: trustedHome, enforceSafety: true,
                                                cancellation: cancellation)
            issues = resolved.issues
            reporter.value.targetsTotal = resolved.targets.count
            for target in resolved.targets {
                if cancellation.isCancelled { break }
                reporter.value.currentPath = target.path
                defer {
                    reporter.value.targetsCompleted += 1
                    reporter.emit()
                }
                do {
                    let context = try CleanupFileSystem.context(path: target.path, home: trustedHome)
                    let measurement = CleanupWalker(path: target.path, home: trustedHome, context: context,
                                                    cancellation: cancellation, reporter: reporter).measure()
                    let active = CleanupPathRules.runningIssue(path: target.path, category: target.category,
                                                               bundleIDs: runningBundleIDs, processNames: currentProcessNames)
                    issues.append(contentsOf: measurement.issues)
                    if let active { issues.append(active) }
                    var withinCandidate = Set<CleanupFileIdentity>()
                    let sizes = measurement.deduplicated(excluding: &withinCandidate)
                    let selectable = measurement.complete && active == nil
                    var reasons = measurement.issues.first.map { [$0.message] } ?? []
                    if let active { reasons.append(active.message) }
                    if let review = target.category.reviewReason { reasons.append(review) }
                    if measurement.hasExternalHardLinks { reasons.append("含目录外硬链接，磁盘回收空间仅作保守估算") }
                    let snapshot = CleanupSnapshot(home: trustedHome, path: target.path, categoryID: target.category.id,
                                                   pattern: target.pattern, root: CleanupFileIdentity(measurement.root),
                                                   ancestors: context.ancestors, fingerprint: measurement.fingerprint,
                                                   complete: measurement.complete)
                    items.append(CacheItem(id: target.path, name: (target.path as NSString).lastPathComponent,
                                           path: target.path, category: target.category.title, size: sizes.logical,
                                           allocatedSize: sizes.allocated, fileCount: sizes.files, canSelect: selectable,
                                           recommended: selectable && target.category.recommended,
                                           autoSelected: selectable && target.category.safe && !target.category.explicitOnly,
                                           reason: reasons.isEmpty ? nil : reasons.joined(separator: "；"),
                                           incomplete: !measurement.complete, hasExternalHardLinks: measurement.hasExternalHardLinks,
                                           estimatedReclaimableSize: sizes.reclaimable, snapshot: snapshot))
                } catch let error as CleanupFileError {
                    if error.number == ENOENT { continue }
                    let issue = error.issue(path: target.path)
                    issues.append(issue)
                    items.append(blockedItem(target, issue: issue))
                } catch CleanupInspectionError.issue(let issue) {
                    issues.append(issue)
                    items.append(blockedItem(target, issue: issue))
                } catch {
                    let issue = CleanupIssue(path: target.path, message: error.localizedDescription, code: .unreadable)
                    issues.append(issue)
                    items.append(blockedItem(target, issue: issue))
                }
            }
        }
        if cancellation.isCancelled {
            issues.append(CleanupIssue(path: reporter.value.currentPath, message: "扫描已取消，现有结果不完整", code: .cancelled))
        }
        reporter.emit(force: true)
        return CleanupScanResult(items: items.sorted { $0.size == $1.size ? $0.path < $1.path : $0.size > $1.size },
                                 issues: issues, cancelled: cancellation.isCancelled, progress: reporter.value,
                                 elapsed: ProcessInfo.processInfo.systemUptime - started)
    }

    private static func blockedItem(_ target: CleanCatalog.Target, issue: CleanupIssue) -> CacheItem {
        CacheItem(id: target.path, name: (target.path as NSString).lastPathComponent, path: target.path,
                  category: target.category.title, size: 0, canSelect: false, reason: issue.message, incomplete: true)
    }
}

enum CleanupExecutor {
    /// The caller confirms permanent deletion first. Only scanner-issued, unchanged snapshots qualify.
    /// removeItem is a narrow test seam; normal operation uses descriptor-relative unlinkat.
    static func clean(items: [CacheItem], categories: [CleanCategory] = CleanCatalog.categories,
                      home: String = NSHomeDirectory(), runningBundleIDs: Set<String> = [],
                      runningBundleIDsProvider: (@Sendable () -> Set<String>)? = nil,
                      processNames: Set<String>? = nil,
                      runningProcessNamesProvider: (@Sendable () -> Set<String>?)? = nil,
                      cancellation: CleanupCancellationToken = CleanupCancellationToken(),
                      removeItem: ((String) throws -> Void)? = nil,
                      beforeRemoval: (() -> Void)? = nil,
                      afterDirectoryOpen: ((String) -> Void)? = nil,
                      progress: ((CleanupProgress) -> Void)? = nil) -> CleanupReport {
        let trustedHome = CleanupPathRules.canonicalHome(home)
        let reporter = CleanupProgressReporter(phase: "预检", total: items.count, callback: progress)
        reporter.emit(force: true)
        var outcomes: [CleanupOutcome] = []
        var totalBytes: Int64 = 0
        var totalReclaimed: Int64 = 0
        var seenPaths = Set<String>()
        func currentProcessNames(for category: CleanCategory) -> Set<String>? {
            guard CleanupProcessActivity.guardedNames(for: category.id) != nil else { return [] }
            if let runningProcessNamesProvider { return runningProcessNamesProvider() }
            return processNames ?? CleanupProcessActivity.currentNames()
        }
        func currentBundleIDs() -> Set<String> { runningBundleIDsProvider?() ?? runningBundleIDs }
        for item in items {
            reporter.value.currentPath = item.path
            reporter.value.phase = "预检"
            defer {
                reporter.value.targetsCompleted += 1
                reporter.emit()
            }
            func outcome(_ status: CleanupOutcomeStatus, _ message: String,
                         bytes: Int64 = 0, reclaimed: Int64 = 0) -> CleanupOutcome {
                CleanupOutcome(path: item.path, status: status, message: message,
                               removedBytes: bytes, estimatedReclaimedBytes: reclaimed)
            }
            if cancellation.isCancelled {
                outcomes.append(outcome(.cancelled, "操作已取消，此项保留"))
                continue
            }
            guard seenPaths.insert(item.path).inserted else {
                outcomes.append(outcome(.blocked, "重复候选已跳过"))
                continue
            }
            guard item.selected, item.canSelect, let snapshot = item.snapshot, snapshot.complete,
                  snapshot.home == trustedHome, snapshot.path == item.path,
                  let category = CleanCatalog.category(for: snapshot, categories: categories, home: trustedHome) else {
                outcomes.append(outcome(.blocked, "此项缺少有效选择或扫描授权，请重新扫描"))
                continue
            }
            if let issue = CleanupPathRules.validationIssue(item.path, home: trustedHome) {
                outcomes.append(outcome(.blocked, issue.message))
                continue
            }
            if let issue = CleanupPathRules.runningIssue(path: item.path, category: category,
                                                        bundleIDs: currentBundleIDs(),
                                                        processNames: currentProcessNames(for: category)) {
                outcomes.append(outcome(.blocked, issue.message))
                continue
            }
            do {
                let context = try CleanupFileSystem.context(path: item.path, home: trustedHome)
                guard CleanupFileIdentity(context.root) == snapshot.root, context.ancestors == snapshot.ancestors else {
                    outcomes.append(outcome(.changed, "候选或父目录身份已变化，此项保留"))
                    continue
                }
                let measurement = CleanupWalker(path: item.path, home: trustedHome, context: context,
                                                    cancellation: cancellation, reporter: reporter,
                                                    captureManifest: true).measure()
                if cancellation.isCancelled {
                    outcomes.append(outcome(.cancelled, "预检已取消，此项保留"))
                    continue
                }
                guard measurement.complete else {
                    let status: CleanupOutcomeStatus = measurement.issues.contains { $0.code == .changed } ? .changed : .blocked
                    outcomes.append(outcome(status, measurement.issues.first?.message ?? "预检不完整，此项保留"))
                    continue
                }
                guard measurement.fingerprint == snapshot.fingerprint else {
                    outcomes.append(outcome(.changed, "扫描后目录或文件内容发生变化，请重新扫描"))
                    continue
                }
                // Reopen the named chain after the walk, rather than relying on an old parent descriptor.
                let current = try CleanupFileSystem.context(path: item.path, home: trustedHome)
                guard current.ancestors == snapshot.ancestors,
                      CleanupFileSystem.sameMetadata(current.root, measurement.root) else {
                    outcomes.append(outcome(.changed, "删除前路径身份已变化，此项保留"))
                    continue
                }
                if let issue = CleanupPathRules.runningIssue(path: item.path, category: category,
                                                            bundleIDs: currentBundleIDs(),
                                                            processNames: currentProcessNames(for: category)) {
                    outcomes.append(outcome(.blocked, issue.message))
                    continue
                }
                if cancellation.isCancelled {
                    outcomes.append(outcome(.cancelled, "删除前已取消，此项保留"))
                    continue
                }
                reporter.value.phase = "删除"
                reporter.emit()
                do {
                    if let removeItem { try removeItem(item.path) }
                    else {
                        guard let expectedParent = current.ancestors.last?.identity else {
                            outcomes.append(outcome(.blocked, "缺少父目录身份验证，此项保留"))
                            continue
                        }
                        beforeRemoval?()
                        let activityIssue = {
                            CleanupPathRules.runningIssue(path: item.path, category: category,
                                                         bundleIDs: currentBundleIDs(),
                                                         processNames: currentProcessNames(for: category))
                        }
                        var manifestIndex = 0
                        var removedHardLinks = [CleanupFileIdentity: Int]()
                        try CleanupFileSystem.remove(parent: current.parentDescriptor, name: current.name,
                                                     device: current.device, home: trustedHome, rootPath: item.path,
                                                     relativePath: "", expectedParent: expectedParent,
                                                     manifest: measurement.manifest, manifestIndex: &manifestIndex,
                                                     removedHardLinks: &removedHardLinks, activityIssue: activityIssue,
                                                     afterDirectoryOpen: afterDirectoryOpen)
                        guard manifestIndex == measurement.manifest.count else {
                            outcomes.append(outcome(.changed, "删除期间发现候选内容发生变化，未计入完成字节"))
                            continue
                        }
                    }
                    var remaining = stat()
                    let result = fstatat(current.parentDescriptor, current.name, &remaining, AT_SYMLINK_NOFOLLOW)
                    guard result != 0 && errno == ENOENT else {
                        outcomes.append(outcome(.failed, "删除操作后仍存在原路径，未计入完成字节"))
                        continue
                    }
                    var withinCandidate = Set<CleanupFileIdentity>()
                    let sizes = measurement.deduplicated(excluding: &withinCandidate)
                    totalBytes += sizes.logical
                    totalReclaimed += sizes.reclaimable
                    outcomes.append(outcome(.removed, "已永久清理；磁盘回收量为估算", bytes: sizes.logical, reclaimed: sizes.reclaimable))
                } catch CleanupInspectionError.issue(let issue) {
                    let status: CleanupOutcomeStatus
                    switch issue.code {
                    case .changed, .excluded, .symlink, .crossVolume, .cloudPlaceholder: status = .changed
                    case .invalidPath, .runningApplication: status = .blocked
                    default: status = .failed
                    }
                    outcomes.append(outcome(status, issue.message + "；可能只清理了部分内容，未计入完成字节"))
                } catch {
                    outcomes.append(outcome(.failed, "删除失败：" + error.localizedDescription + "；未计入完成字节"))
                }
            } catch let error as CleanupFileError {
                if error.number == ENOENT { outcomes.append(outcome(.missing, "候选已消失，未计入完成字节")) }
                else { outcomes.append(outcome(.blocked, error.issue(path: item.path).message)) }
            } catch CleanupInspectionError.issue(let issue) {
                outcomes.append(outcome(issue.code == .changed ? .changed : .blocked, issue.message))
            } catch {
                outcomes.append(outcome(.failed, error.localizedDescription))
            }
        }
        reporter.emit(force: true)
        return CleanupReport(outcomes: outcomes, removedBytes: totalBytes, estimatedReclaimedBytes: totalReclaimed,
                             cancelled: cancellation.isCancelled)
    }
}
