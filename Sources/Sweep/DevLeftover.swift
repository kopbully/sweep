import SwiftUI
import AppKit
import Foundation

// MARK: - 数据模型

/// 一个被识别为「项目根」的目录（含源码）。删除时整体移入废纸篓。
struct ProjectFolder: Identifiable, Hashable {
    let id: String          // = path
    let name: String
    let path: String
    let size: Int64
    let lastModified: Date
    var hasCache: Bool      // 该项目下是否检测到了可清理的构建缓存
}

// MARK: - 引擎

/// 开发项目残留：扫描用户指定的项目根目录，找出两类可清理对象：
/// 1. 构建缓存（node_modules / .build / dist / .venv …）——可重建，删了重新安装/编译会再生。
/// 2. 疑似废弃的项目目录——按最久未修改排序，逐条确认后才整体移入废纸篓（可恢复）。
///
/// 所有删除都走 `Remover.remove(mode: .trash)`，即系统废纸篓，可恢复；
/// 且 `Remover` 会拦截受保护目录（~/Desktop、~/Documents、~/Library 等），不会越界。
final class DevLeftoverEngine: ObservableObject {

    // MARK: 可识别的构建缓存目录名（高置信度、可重建，才会被纳入缓存清理）
    static let cacheDirNames: Set<String> = [
        "node_modules", ".build", "dist", ".next", ".nuxt", "out",
        ".turbo", ".venv", "venv", "__pycache__", ".gradle", "Pods",
        ".pytest_cache", ".mypy_cache", "target", ".dart_tool",
        ".svelte-kit", ".output", ".astro", "coverage", ".parcel-cache",
        ".rush", ".terraform",
    ]

    // 标记「这是一个项目根」的文件（字面匹配）
    private static let literalMarkers: Set<String> = [
        "package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml",
        "Cargo.toml", "pyproject.toml", "requirements.txt", "setup.py",
        "go.mod", "go.sum", "Gemfile", "Gemfile.lock", "pom.xml",
        "build.gradle", "build.gradle.kts", "composer.json", "deno.json",
        "bun.lockb", "rust-toolchain.toml", "mix.exs", "pubspec.yaml",
        "CMakeLists.txt", "Makefile", "BUILD", "WORKSPACE", "justfile",
    ]

    // MARK: 状态

    @Published var roots: [String] {
        didSet { UserDefaults.standard.set(roots, forKey: "sweep.devRoots") }
    }
    @Published var cacheItems: [AppObject] = []
    @Published var selectedCaches: Set<String> = []
    @Published var projects: [ProjectFolder] = []
    @Published var selectedProjects: Set<String> = []
    @Published var scanning = false
    /// 仅展示「超过 N 天未修改」的项目，作为「废弃」的启发式阈值
    @Published var minAgeDays: Int = 90
    @Published var lastMessage: String? = nil
    @Published var lastMessageIsWarning = false

    init() {
        if let saved = UserDefaults.standard.array(forKey: "sweep.devRoots") as? [String],
           !saved.isEmpty {
            roots = saved
        } else {
            roots = Self.defaultRoots()
        }
    }

    /// 常见开发目录，仅保留本机真实存在的作为默认扫描根
    static func defaultRoots() -> [String] {
        let candidates = [
            "~/Developer", "~/Projects", "~/code", "~/dev", "~/src",
            "~/repos", "~/git", "~/Documents/GitHub", "~/Documents/Developer",
            "~/Documents/projects",
        ]
        let fm = FileManager.default
        return candidates.compactMap { candidate in
            let expanded = (candidate as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: expanded, isDirectory: &isDir) && isDir.boolValue
                ? candidate : nil
        }
    }

    // MARK: 选择

    func toggleCache(_ id: String) {
        if selectedCaches.contains(id) { selectedCaches.remove(id) }
        else { selectedCaches.insert(id) }
    }

    func toggleProject(_ id: String) {
        if selectedProjects.contains(id) { selectedProjects.remove(id) }
        else { selectedProjects.insert(id) }
    }

    func addRoot(_ path: String) {
        let std = (path as NSString).standardizingPath
        if !roots.contains(std) { roots.append(std) }
    }

    func removeRoot(_ path: String) {
        roots.removeAll { ($0 as NSString).standardizingPath == (path as NSString).standardizingPath }
    }

    /// 弹出系统选文件夹面板，添加扫描根
    func presentFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择要纳入扫描的开发目录"
        if panel.runModal() == .OK, let url = panel.url {
            addRoot(url.path)
        }
    }

    // MARK: 扫描（只读，不删除任何东西）

    /// 仅展示超过阈值未修改的项目（按最久未修改在前）
    var abandonedProjects: [ProjectFolder] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -minAgeDays, to: Date()) ?? .distantPast
        return projects.filter { $0.lastModified < cutoff }
            .sorted { $0.lastModified < $1.lastModified }
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        let rootsToScan = roots.map { ($0 as NSString).expandingTildeInPath }
        DispatchQueue.global(qos: .userInitiated).async {
            let (caches, foundProjects) = Self.collect(roots: rootsToScan)
            let cacheParents = Set(caches.map { ($0.path as NSString).deletingLastPathComponent })
            var projects = foundProjects
            for i in projects.indices { projects[i].hasCache = cacheParents.contains(projects[i].path) }
            DispatchQueue.main.async {
                self.cacheItems = caches
                self.projects = projects
                self.scanning = false
            }
        }
    }

    /// 同步遍历：返回找到的构建缓存与项目根。供 scan() 与 CLI 探针共用。
    static func collect(roots: [String]) -> (caches: [AppObject], projects: [ProjectFolder]) {
        var caches: [AppObject] = []
        var projects: [ProjectFolder] = []
        let fm = FileManager.default
        let maxLevel = 4           // 项目根最多向下 4 层
        let hardCeiling = 6        // 防止异常深目录 runaway

        for root in roots {
            guard fm.fileExists(atPath: root),
                  let enumerator = fm.enumerator(at: URL(fileURLWithPath: root),
                       includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                       options: [.skipsPackageDescendants]) else { continue }
            while let url = enumerator.nextObject() as? URL {
                let level = enumerator.level
                if level > hardCeiling { enumerator.skipDescendants(); continue }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let name = url.lastPathComponent

                // 跳过版本库内部目录，避免无意义的海量遍历
                if name == ".git" || name == ".svn" || name == ".hg" {
                    enumerator.skipDescendants(); continue
                }

                // 构建缓存：记录后不再向下遍历（其体积已计入）
                if cacheDirNames.contains(name) {
                    let size = Sizer.footprint(url.path)
                    if size > 0 { caches.append(AppObject(path: url.path, size: size)) }
                    enumerator.skipDescendants()
                    continue
                }

                // 项目根：检查该目录是否包含项目标记文件
                if level <= maxLevel {
                    guard let kids = try? fm.contentsOfDirectory(atPath: url.path) else { continue }
                    if isProjectRoot(url, kids: kids) {
                        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                            .contentModificationDate ?? .distantPast
                        projects.append(ProjectFolder(id: url.path, name: name, path: url.path,
                                                      size: Sizer.footprint(url.path),
                                                      lastModified: mod, hasCache: false))
                    }
                }
            }
        }
        caches.sort { $0.size > $1.size }
        projects.sort { $0.lastModified < $1.lastModified }
        return (caches, projects)
    }

    private static func isProjectRoot(_ url: URL, kids: [String]) -> Bool {
        let set = Set(kids)
        if !set.isDisjoint(with: literalMarkers) { return true }
        for k in kids where k.hasSuffix(".xcodeproj") || k.hasSuffix(".sln") || k.hasSuffix(".xcworkspace") {
            return true
        }
        return false
    }

    // MARK: 删除（全部走废纸篓，可恢复）

    /// 清理选中的构建缓存（可重建，安全）
    func removeSelectedCaches() {
        var paths: [String] = []
        for id in selectedCaches {
            if let c = cacheItems.first(where: { $0.id == id }) { paths.append(c.path) }
        }
        guard !paths.isEmpty else { return }
        let bytes = cacheItems.filter { selectedCaches.contains($0.id) }.reduce(0) { $0 + $1.size }
        let res = Remover.remove(paths, mode: .trash)
        OperationHistory.record(kind: .uninstall,
                                summary: "清理开发项目构建缓存 \(res.removed) 项",
                                bytes: bytes, count: res.removed)
        selectedCaches.removeAll()
        scan()
    }

    /// 删除选中的整个项目目录（高危，调用方已逐条确认）。整体移入废纸篓，可恢复。
    func removeSelectedProjects() {
        var paths: [String] = []
        for id in selectedProjects {
            if let p = projects.first(where: { $0.id == id }) { paths.append(p.path) }
        }
        guard !paths.isEmpty else { return }
        let bytes = projects.filter { selectedProjects.contains($0.id) }.reduce(0) { $0 + $1.size }
        let res = Remover.remove(paths, mode: .trash)
        OperationHistory.record(kind: .uninstall,
                                summary: "删除废弃开发项目 \(res.removed) 个",
                                bytes: bytes, count: res.removed)
        selectedProjects.removeAll()
        scan()
    }

    // MARK: 只读诊断（CLI）

    /// SWEEP_DEV_PROBE=1：打印构建缓存与项目根的命中，不做任何删除。
    static func runProbe() {
        let expanded = DevLeftoverEngine().roots.map { ($0 as NSString).expandingTildeInPath }
        let (caches, projects) = Self.collect(roots: expanded)
        let cacheBytes = caches.reduce(0) { $0 + $1.size }
        print("DEV_PROBE roots=\(expanded.count) caches=\(caches.count) cacheBytes=\(cacheBytes) projects=\(projects.count)")
        for c in caches.prefix(12) { print("  CACHE \(c.size)\t\(c.path)") }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        for p in projects.prefix(12) {
            print("  PROJ \(p.size)\t\(formatter.string(from: p.lastModified))\t\(p.path)")
        }
    }
}
