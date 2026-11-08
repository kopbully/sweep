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

// MARK: - 残留清理视图（独立侧栏模块）

/// 侧栏「应用 → 残留清理」：
/// 1. agent / 已卸载应用的 ~/Library 孤儿残留（来自 UninstallEngine，始终显示面板）
/// 2. 开发项目残留：构建缓存 + 疑似废弃项目（来自 DevLeftoverEngine）
struct LeftoversView: View {
    @ObservedObject var engine: UninstallEngine
    @ObservedObject var devEngine: DevLeftoverEngine
    @State private var confirmCacheClean = false
    @State private var confirmProjectDelete = false

    private func shortPath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s200) {
                PageHeader("残留清理", subtitle: "agent / 已卸载应用的尾巴，加上项目里的构建缓存与废弃项目") {
                    SweepButton(.secondary, title: "全部重扫", systemImage: "arrow.clockwise") {
                        engine.loadOrphans()
                        devEngine.scan()
                    }
                    .disabled(engine.scanningOrphans || devEngine.scanning)
                }

                orphanSection
                devSection
            }
            .padding(Space.s300)
        }
        .onAppear {
            if engine.orphanBundles.isEmpty && !engine.scanningOrphans { engine.loadOrphans() }
            if devEngine.cacheItems.isEmpty && devEngine.projects.isEmpty && !devEngine.scanning { devEngine.scan() }
        }
        .alert("清理构建缓存？", isPresented: $confirmCacheClean) {
            Button("清理所选", role: .destructive) { devEngine.removeSelectedCaches() }
            Button("取消", role: .cancel) {}
        } message: {
            let bytes = devEngine.cacheItems.filter { devEngine.selectedCaches.contains($0.id) }
                .reduce(0) { $0 + $1.size }
            Text("将把 \(devEngine.selectedCaches.count) 个构建缓存（合计 \(bytes.sizeText)）移入废纸篓。这些都是可重建的产物，重新安装 / 编译会自动再生。")
        }
        .alert("删除废弃项目？", isPresented: $confirmProjectDelete) {
            Button("删除所选", role: .destructive) { devEngine.removeSelectedProjects() }
            Button("取消", role: .cancel) {}
        } message: {
            let selected = devEngine.projects.filter { devEngine.selectedProjects.contains($0.id) }
            let bytes = selected.reduce(0) { $0 + $1.size }
            let names = selected.prefix(3).map(\.name).joined(separator: "、")
            let more = selected.count > 3 ? "等 \(selected.count) 个项目" : ""
            Text("将把 \(names)\(more)（合计 \(bytes.sizeText)）整体移入废纸篓，可恢复。删除会连同源代码一起走，请确认你不再需要这些项目。")
        }
    }

    // MARK: agent / 已卸载应用残留（始终显示，空态也说明）

    private var orphanSection: some View {
        Panel {
            VStack(alignment: .leading, spacing: Space.s100) {
                HStack(spacing: Space.s75) {
                    Image(systemName: "tray.full")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                    Text("已卸载应用残留（agent 等）")
                        .font(Typo.f(Typo.base, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Toggle("通用发现（实验）", isOn: Binding(
                        get: { engine.includeGenericOrphans },
                        set: { engine.includeGenericOrphans = $0; engine.loadOrphans() }
                    ))
                    .font(Typo.f(Typo.xs))
                    .foregroundStyle(Theme.textSecondary)
                    if engine.scanningOrphans {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("\(engine.orphanBundles.count) 个 · \(engine.orphanBundles.reduce(0) { $0 + $1.size }.sizeText)")
                            .font(Typo.f(Typo.xs))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                if engine.orphanBundles.isEmpty {
                    Text(engine.scanningOrphans
                         ? "正在扫描 ~/Library 各位置的孤儿残留…"
                         : "没有发现孤儿残留。已收录清单：OpenClaw、Hermes；打开「通用发现（实验）」可扫描更多 agent / 已卸载应用在 ~/Library 的尾巴。")
                        .font(Typo.f(Typo.xs))
                        .foregroundStyle(Theme.textMuted)
                } else {
                    Text("这些应用已不在 /Applications，但它们在 ~/Library 下的缓存、日志、偏好仍占着空间。勾选后清理，全部进废纸篓，可恢复。")
                        .font(Typo.f(Typo.xs))
                        .foregroundStyle(Theme.textMuted)
                }

                ForEach(engine.orphanBundles) { orphan in
                    VStack(alignment: .leading, spacing: Space.s50) {
                        HStack(spacing: Space.s75) {
                            Button { engine.toggleOrphan(orphan.id) } label: {
                                Image(systemName: engine.selectedOrphans.contains(orphan.id) ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 13))
                                    .foregroundStyle(engine.selectedOrphans.contains(orphan.id) ? Theme.accent : Theme.textMuted)
                            }
                            .buttonStyle(.plain)
                            Text(orphan.name)
                                .font(Typo.f(Typo.sm, .medium))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text(orphan.size.sizeText)
                                .font(Typo.mono(Typo.xs))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        ForEach(orphan.items) { item in
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
                            .padding(.vertical, 1)
                            .padding(.leading, Space.s200)
                        }
                    }
                    .padding(.vertical, Space.s50)
                }

                if !engine.selectedOrphans.isEmpty {
                    SweepButton(.danger, title: "清理所选残留", systemImage: "trash") {
                        engine.removeSelectedOrphans()
                    }
                    .padding(.top, Space.s50)
                }
            }
        }
    }

    // MARK: 开发项目残留

    private var devSection: some View {
        Panel {
            VStack(alignment: .leading, spacing: Space.s100) {
                HStack(spacing: Space.s75) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                    Text("开发项目残留")
                        .font(Typo.f(Typo.base, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if devEngine.scanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("\(devEngine.cacheItems.count) 个缓存 · \(devEngine.projects.count) 个项目")
                            .font(Typo.f(Typo.xs))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    SweepButton(.quiet, title: "重新扫描", systemImage: "arrow.clockwise") {
                        devEngine.scan()
                    }
                    .disabled(devEngine.scanning)
                }

                Text("扫描你指定的开发目录：缓存可放心清（会重新生成），整项目删除会连同源码进废纸篓，需逐条确认。")
                    .font(Typo.f(Typo.xs))
                    .foregroundStyle(Theme.textMuted)

                rootsEditor
                devCacheSection
                devAbandonedSection
            }
        }
    }

    private var rootsEditor: some View {
        VStack(alignment: .leading, spacing: Space.s75) {
            HStack(spacing: Space.s75) {
                Text("扫描目录")
                    .font(Typo.f(Typo.xs, .medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                SweepButton(.quiet, title: "添加目录", systemImage: "plus") {
                    devEngine.presentFolderPicker()
                }
            }
            if devEngine.roots.isEmpty {
                Text("还没有添加任何扫描目录。点「添加目录」选择你的项目所在位置（如 ~/Developer）。")
                    .font(Typo.f(Typo.xs))
                    .foregroundStyle(Theme.textMuted)
            } else {
                ForEach(devEngine.roots, id: \.self) { root in
                    HStack(spacing: Space.s75) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textMuted)
                        Text(shortPath(root))
                            .font(Typo.mono(Typo.xs))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: Space.s100)
                        Button {
                            devEngine.removeRoot(root)
                            devEngine.scan()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var devCacheSection: some View {
        VStack(alignment: .leading, spacing: Space.s75) {
            HStack(spacing: Space.s75) {
                Text("构建缓存（可重建，删了会重新下载 / 编译）")
                    .font(Typo.f(Typo.xs, .medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(devEngine.cacheItems.reduce(0) { $0 + $1.size }.sizeText)
                    .font(Typo.mono(Typo.xs))
                    .foregroundStyle(Theme.textSecondary)
            }

            if devEngine.cacheItems.isEmpty {
                Text(devEngine.scanning
                     ? "正在扫描构建缓存…"
                     : "没发现 node_modules / .build / dist / .venv 等构建缓存。")
                    .font(Typo.f(Typo.xs))
                    .foregroundStyle(Theme.textMuted)
            } else {
                ForEach(devEngine.cacheItems.prefix(200)) { item in
                    HStack(spacing: Space.s100) {
                        Button { devEngine.toggleCache(item.id) } label: {
                            Image(systemName: devEngine.selectedCaches.contains(item.id) ? "checkmark.square.fill" : "square")
                                .font(.system(size: 13))
                                .foregroundStyle(devEngine.selectedCaches.contains(item.id) ? Theme.accent : Theme.textMuted)
                        }
                        .buttonStyle(.plain)
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
                    .padding(.vertical, 1)
                }
                if !devEngine.selectedCaches.isEmpty {
                    SweepButton(.danger, title: "清理所选缓存", systemImage: "trash") {
                        confirmCacheClean = true
                    }
                    .padding(.top, Space.s50)
                }
            }
        }
    }

    private var devAbandonedSection: some View {
        VStack(alignment: .leading, spacing: Space.s75) {
            HStack(spacing: Space.s75) {
                Text("疑似废弃项目（按最久未修改排序）")
                    .font(Typo.f(Typo.xs, .medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Picker("", selection: $devEngine.minAgeDays) {
                    Text("30 天").tag(30)
                    Text("90 天").tag(90)
                    Text("180 天").tag(180)
                    Text("365 天").tag(365)
                }
                .frame(width: 110)
                .font(Typo.f(Typo.xs))
            }

            let list = devEngine.abandonedProjects
            if list.isEmpty {
                Text(devEngine.scanning
                     ? "正在识别项目根…"
                     : "没有超过 \(devEngine.minAgeDays) 天未修改的项目。降低阈值或换个扫描目录试试。")
                    .font(Typo.f(Typo.xs))
                    .foregroundStyle(Theme.textMuted)
            } else {
                ForEach(list) { project in
                    HStack(spacing: Space.s100) {
                        Button { devEngine.toggleProject(project.id) } label: {
                            Image(systemName: devEngine.selectedProjects.contains(project.id) ? "checkmark.square.fill" : "square")
                                .font(.system(size: 13))
                                .foregroundStyle(devEngine.selectedProjects.contains(project.id) ? Theme.accent : Theme.textMuted)
                        }
                        .buttonStyle(.plain)
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textMuted)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: Space.s50) {
                                Text(project.name)
                                    .font(Typo.f(Typo.sm, .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                if project.hasCache { Tag(text: "含缓存") }
                            }
                            Text(shortPath(project.path))
                                .font(Typo.mono(Typo.xs))
                                .foregroundStyle(Theme.textMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: Space.s100)
                        Text(project.lastModified == .distantPast ? "—" : relativeDate(project.lastModified))
                            .font(Typo.f(Typo.xs))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 84, alignment: .trailing)
                        Text(project.size.bytesText)
                            .font(Typo.mono(Typo.xs))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 72, alignment: .trailing)
                        SweepButton(.quiet, title: "显示") {
                            NSWorkspace.shared.selectFile(project.path, inFileViewerRootedAtPath: "")
                        }
                    }
                    .padding(.vertical, Space.s50)
                }
                if !devEngine.selectedProjects.isEmpty {
                    SweepButton(.danger, title: "删除所选项目", systemImage: "trash") {
                        confirmProjectDelete = true
                    }
                    .padding(.top, Space.s50)
                }
                Text("删除会连同源码与缓存整体移入废纸篓，可恢复。请只勾选你确认不再需要的项目。")
                    .font(Typo.f(Typo.xs))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.top, Space.s25)
            }
        }
    }
}
