import SwiftUI
import AppKit

// MARK: - 数据模型

struct InstalledApp: Identifiable, Hashable {
    let id: String                  // = path
    let name: String
    let path: String
    let bundleID: String
    let version: String
    let size: Int64
    let lastModified: Date
}

struct AppObject: Identifiable {
    let id = UUID()
    let path: String
    let size: Int64
}

final class UninstallEngine: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var loading = false
    @Published var selectedPaths: Set<String> = []
    @Published var leftoversForApp: [AppObject] = []
    @Published var leftoverAppName: String? = nil
    @Published var lastMessage: String? = nil

    private var lock = NSLock()

    static let protectedNames: Set<String> = [
        "finder", "dock", "xprotect", "safari", "spotlight", "systemUIServer",
    ]

    var totalSelected: Int64 {
        apps.filter { selectedPaths.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    func load() {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let dirs = ["/Applications", NSHomeDirectory() + "/Applications"]
            var list: [InstalledApp] = []
            for dir in dirs {
                guard let kids = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                let bundles = kids.filter { $0.hasSuffix(".app") }
                DispatchQueue.concurrentPerform(iterations: bundles.count) { i in
                    let name = bundles[i]
                    let full = "\(dir)/\(name)"
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { return }
                    let size = Sizer.size(full)
                    var bundleID = ""
                    var version = ""
                    let plistPath = "\(full)/Contents/Info.plist"
                    if let data = fm.contents(atPath: plistPath),
                       let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                        bundleID = (dict["CFBundleIdentifier"] as? String) ?? ""
                        version = (dict["CFBundleShortVersionString"] as? String) ?? ""
                    }
                    let attrs = try? fm.attributesOfItem(atPath: full)
                    let modified = (attrs?[.modificationDate] as? Date) ?? Date.distantPast
                    self.lock.lock()
                    list.append(InstalledApp(id: full, name: name, path: full,
                                             bundleID: bundleID, version: version,
                                             size: size, lastModified: modified))
                    self.lock.unlock()
                }
            }
            DispatchQueue.main.async {
                self.apps = list.sorted { $0.size > $1.size }
                self.loading = false
            }
        }
    }

    /// 找指定应用的残留文件
    func loadLeftovers(for app: InstalledApp) {
        leftoverAppName = app.name
        leftoversForApp = []
        DispatchQueue.global(qos: .userInitiated).async {
            let list = Self.findLeftovers(app: app)
            DispatchQueue.main.async {
                self.leftoversForApp = list
                self.lastMessage = nil
            }
        }
    }

    static func findLeftovers(app: InstalledApp) -> [AppObject] {
        let baseName = (app.name as NSString).deletingPathExtension
        let bundleID = app.bundleID
        let dirs: [String] = [
            NSHomeDirectory() + "/Library/Application Support",
            NSHomeDirectory() + "/Library/Caches",
            NSHomeDirectory() + "/Library/Containers",
            NSHomeDirectory() + "/Library/HTTPStorages",
            NSHomeDirectory() + "/Library/Logs",
            NSHomeDirectory() + "/Library/Saved Application State",
            NSHomeDirectory() + "/Library/Preferences",
        ]
        var found: [AppObject] = []
        for dir in dirs {
            let stdDir = dir
            guard FileManager.default.fileExists(atPath: stdDir),
                  let kids = try? FileManager.default.contentsOfDirectory(atPath: stdDir) else { continue }
            for kid in kids {
                var matched = bundleID != "" && kid.contains(bundleID)
                if !matched, baseName.count >= 3 { matched = kid.lowercased().contains(baseName.lowercased()) }
                guard matched else { continue }
                let full = "\(stdDir)/\(kid)"
                found.append(AppObject(path: full, size: Sizer.sizeIfPresent(full)))
            }
        }
        return found.filter { $0.size > 0 }.sorted { $0.size > $1.size }
    }

    /// 卸载所选：应用本体→废纸篓（可恢复）；残留→废纸篓
    func uninstallSelected() {
        loading = true
        lastMessage = nil
        let targets = apps.filter { selectedPaths.contains($0.id) }
        DispatchQueue.global(qos: .userInitiated).async {
            var appFreed: Int64 = 0
            var leftoverCount = 0
            for app in targets {
                appFreed += app.size
                do {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: app.path), resultingItemURL: nil)
                    OperationsLog.write("TRASH(app) \(app.path)")
                } catch {
                    // 没有权限（多数是 /Applications 下的 root 应用）时请求管理员权限
                    try? Remover.adminRemove(app.path)
                }
                let leftovers = Self.findLeftovers(app: app)
                let res = Remover.remove(leftovers.map(\.path), mode: .trash)
                leftoverCount += res.removed
            }
            DispatchQueue.main.async {
                self.loading = false
                self.selectedPaths.removeAll()
                self.leftoversForApp = []
                self.lastMessage = "卸载完成：\(targets.count) 个应用（\(appFreed.bytesText)），清理残留 \(leftoverCount) 项。已全部移到废纸篓，可随时恢复。"
                self.load()
            }
        }
    }
}

// MARK: - 视图

struct UninstallView: View {
    @StateObject private var engine = UninstallEngine()
    @State private var searching = ""
    @State private var confirmUninstall = false

    var filtered: [InstalledApp] {
        let q = searching.lowercased()
        return engine.apps.filter {
            q.isEmpty || $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(title: "卸载", subtitle: "应用本体移入废纸篓，再带上一份它的残留清单")

                summaryCard

                if let msg = engine.lastMessage {
                    Card {
                        HStack {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.accent)
                            Text(msg).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }

                if engine.loading {
                    Card {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("正在读取应用与大小，第一次会花点时间…")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }

                Card {
                    VStack(spacing: 0) {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                            TextField("按名称或 Bundle ID 搜索…", text: $searching)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg))
                        .padding(.bottom, 8)

                        appList
                    }
                }

                if let name = engine.leftoverAppName {
                    leftoverCard(appName: name)
                }
            }
            .padding(20)
        }
        .background(Theme.bg)
        .onAppear { engine.load() }
        .alert("确认卸载？", isPresented: $confirmUninstall) {
            Button("卸载所选", role: .destructive) { engine.uninstallSelected() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已选 \(engine.selectedPaths.count) 个应用，共 \(engine.totalSelected.bytesText)。应用本体与发现的残留会移到废纸篓。")
        }
    }

    private var summaryCard: some View {
        Card {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("将卸载")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    Text("\(engine.selectedPaths.count) 个应用")
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text("共 \(engine.totalSelected.bytesText)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent)
                }
                Spacer()
                Button {
                    engine.load()
                } label: {
                    Label("刷新应用", systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .tint(Theme.textSecondary)
                Button {
                    confirmUninstall = true
                } label: {
                    Label("卸载所选", systemImage: "arrow.uturn.down")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accentWarn)
                .foregroundStyle(.black)
                .disabled(engine.selectedPaths.isEmpty || engine.loading)
            }
        }
    }

    private var appList: some View {
        VStack(spacing: 0) {
            ForEach(filtered) { app in
                appRow(app)
            }
            if !engine.loading && filtered.isEmpty {
                Text("没有匹配的应用")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, 30)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func appRow(_ app: InstalledApp) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { engine.selectedPaths.contains(app.id) },
                    set: { on in
                        if on { engine.selectedPaths.insert(app.id) } else { engine.selectedPaths.remove(app.id) }
                    }))
                .labelsHidden()
                .controlSize(.mini)

                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable()
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(app.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if !app.version.isEmpty {
                            Text(app.version)
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.bg))
                        }
                    }
                    Text(app.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textSecondary.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()

                Text(app.lastModified == Date.distantPast ? "—" : relativeDate(app.lastModified))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)

                Text(app.size.bytesText)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 74, alignment: .trailing)

                Button { engine.loadLeftovers(for: app) } label: {
                    Text("看残留")
                        .font(.system(size: 10))
                }
                .buttonStyle(.link)
                .foregroundStyle(Theme.accent)
            }
            .padding(.vertical, 5)
            Divider().overlay(Theme.cardBorder)
        }
        .contentShape(Rectangle())
    }

    private func leftoverCard(appName: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "trash.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    Text("\(appName) 的残留")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                }
                if engine.leftoversForApp.isEmpty {
                    Text("没有发现可清理的残留文件（应用可能是绿色安装，或已被清理过）")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
                ForEach(engine.leftoversForApp) { item in
                    HStack(spacing: 10) {
                        Image(systemName: "doc")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textSecondary)
                        Text(item.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.system(size: 10).monospaced())
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(item.size.bytesText)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 66, alignment: .trailing)
                    }
                }
            }
        }
    }
}

// MARK: - 无用扩展清理
