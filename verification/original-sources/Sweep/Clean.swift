import SwiftUI
import AppKit

// MARK: - 清理数据模型

struct CleanCategory: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let paths: [String]           // 支持 * 通配，表示列子目录
    let icon: String
    let safe: Bool
}

struct CacheItem: Identifiable, Hashable {
    let id: String                // = path
    let name: String
    let path: String
    let category: String
    var size: Int64
    var selected = true
}

enum CleanCatalog {
    static let categories: [CleanCategory] = [
        CleanCategory(
            id: "appCaches", title: "应用缓存", subtitle: "各应用的临时缓存，可再生",
            paths: ["~/Library/Caches/*"], icon: "shippingbox", safe: true),
        CleanCategory(
            id: "devXcode", title: "Xcode", subtitle: "DerivedData、设备支持与模拟器缓存",
            paths: [
                "~/Library/Developer/Xcode/DerivedData",
                "~/Library/Developer/Xcode/iOS DeviceSupport",
                "~/Library/Developer/CoreSimulator/Caches",
                "~/Library/Developer/CoreSimulator/Logs",
                "~/Library/Developer/Xcode/iOS Device Logs",
                "~/Library/Developer/Xcode/Archives",
            ], icon: "hammer", safe: true),
        CleanCategory(
            id: "devTools", title: "开发工具缓存", subtitle: "npm / pip / uv / Homebrew 等",
            paths: [
                "~/.npm/_cacache",
                "~/.cache/uv",
                "~/Library/Caches/pip",
                "~/Library/Caches/Homebrew",
                "~/.gradle/caches",
                "~/.m2/repository",
            ], icon: "terminal", safe: true),
        CleanCategory(
            id: "browsers", title: "浏览器缓存", subtitle: "浏览器关闭时才会出现",
            paths: [
                "~/Library/Caches/Google",
                "~/Library/Caches/Firefox",
                "~/Library/Caches/Microsoft Edge",
                "~/Library/Caches/com.apple.helpd",
            ], icon: "globe", safe: true),
        CleanCategory(
            id: "logs", title: "日志", subtitle: "应用日志文件，一般可以安全删除",
            paths: ["~/Library/Logs/*"], icon: "doc.plaintext", safe: true),
        CleanCategory(
            id: "trash", title: "废纸篓", subtitle: "清空后释放的空间才真正落袋",
            paths: ["~/.Trash/*"], icon: "trash", safe: true),
    ]
}

// MARK: - 扫描引擎

final class CleanEngine: ObservableObject {
    @Published var items: [CacheItem] = []
    @Published var scanning = false
    @Published var cleaning = false
    @Published var lastFreed: Int64? = nil
    @Published var lastMessage: String? = nil

    var selectedTotal: Int64 { items.filter(\.selected).reduce(0) { $0 + $1.size } }

    func scan() {
        guard !scanning else { return }
        scanning = true
        lastFreed = nil
        let cats = CleanCatalog.categories
        DispatchQueue.global(qos: .userInitiated).async {
            var result: [CacheItem] = []
            let lock = NSLock()
            for cat in cats {
                let paths: [String] = cat.paths.flatMap { p in
                    let expanded = p.expandingTilde
                    if expanded.hasSuffix("*") {
                        let dir = String(expanded.dropLast())
                        let fm = FileManager.default
                        let kids = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
                        return kids.filter { !$0.hasPrefix(".") }.sorted()
                            .map { "\(dir)/\($0)" }
                    }
                    return [expanded]
                }
                DispatchQueue.concurrentPerform(iterations: paths.count) { i in
                    let path = paths[i]
                    guard FileManager.default.fileExists(atPath: path) else { return }
                    let size = Sizer.size(path)
                    lock.lock()
                    result.append(CacheItem(
                        id: path,
                        name: (path as NSString).lastPathComponent,
                        path: path,
                        category: cat.title,
                        size: size))
                    lock.unlock()
                }
            }
            DispatchQueue.main.async {
                self.items = result
                    .filter { $0.size > 0 }
                    .sorted { $0.size > $1.size }
                self.scanning = false
                self.lastMessage = self.items.isEmpty ? "没有发现可清理的内容，很干净。" : "发现 \(result.count) 个条目，共可释放 \(self.selectedTotal.bytesText)。"
            }
        }
    }

    func cleanSelected() {
        guard !cleaning else { return }
        // 保护运行中应用：运行中的应用的缓存删除会失败，交给删除时的报告
        cleaning = true
        let targets = items.filter(\.selected).map(\.path)
        DispatchQueue.global(qos: .userInitiated).async {
            let res = Remover.remove(targets, mode: .permanent)
            DispatchQueue.main.async {
                self.cleaning = false
                self.lastFreed = res.removed > 0 ? self.selectedTotal : 0
                self.lastMessage = res.failed == 0
                    ? "完成：删除 \(res.removed) 项，释放 \(self.lastFreed!.bytesText)。"
                    : "完成，\(res.failed) 项被跳过（运行中的应用或受保护路径）。详情见操作日志。"
                self.scan()
            }
        }
    }
}

// MARK: - 视图

struct CleanView: View {
    @StateObject private var engine = CleanEngine()
    @State private var confirmClean = false

    var grouped: [(String, [CacheItem])] {
        Dictionary(grouping: engine.items, by: \.category)
            .sorted { a, b in
                let order = CleanCatalog.categories.map(\.title)
                guard let ia = order.firstIndex(of: a.key), let ib = order.firstIndex(of: b.key) else { return a.key > b.key }
                return ia < ib
            }
            .map { ($0.key, $0.value) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                summaryCard
                if engine.scanning { progressCard("正在扫描缓存目录…") }
                if engine.cleaning { progressCard("正在删除…请稍候") }
                if let msg = engine.lastMessage { noteCard(msg) }

                ForEach(grouped, id: \.0) { cat, items in
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(cat)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                Text("\(items.count) 项 · \(items.map(\.size).reduce(0, +).bytesText)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textSecondary)
                                Spacer()
                                Button(categoryToggleLabel(items)) {
                                    let allSelected = items.allSatisfy { $0.selected }
                                    toggleCategory(cat, to: !allSelected)
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg))
                            }
                            ForEach(items) { item in
                                itemRow(item)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Theme.bg)
        .onAppear { if engine.items.isEmpty && !engine.scanning { engine.scan() } }
        .alert("确认清理？", isPresented: $confirmClean) {
            Button("永久删除所选") { engine.cleanSelected() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将永久删除 \(engine.selectedTotal.bytesText) 的文件。缓存可再生，但请确认没有勾选不想删的内容。")
        }
    }

    private var header: some View {
        SectionTitle(title: "清理", subtitle: "先看清每个条目，再决定删什么——默认勾选的都是可再生内容")
    }

    private var summaryCard: some View {
        Card {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("可释放空间")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    Text(engine.selectedTotal.bytesText)
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.accent)
                    if let freed = engine.lastFreed, freed > 0 {
                        Text("上次已释放 \(freed.bytesText)")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
                Button {
                    if engine.scanning || engine.cleaning { return }
                    engine.scan()
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .tint(Theme.textSecondary)
                Button {
                    confirmClean = true
                } label: {
                    Label("清理所选", systemImage: "wind.snow")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .foregroundStyle(.black)
                .disabled(engine.selectedTotal == 0 || engine.cleaning || engine.scanning)
            }
        }
    }

    private func progressCard(_ text: String) -> some View {
        Card {
            HStack {
                ProgressView().controlSize(.small)
                Text(text).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func noteCard(_ msg: String) -> some View {
        Card {
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
                Text(msg).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func itemRow(_ item: CacheItem) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: binding(for: item))
                .labelsHidden()
                .controlSize(.mini)
            Image(systemName: "folder.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(shortPath(item.path))
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("打开") { reveal(item.path) }
                .buttonStyle(.link)
                .font(.system(size: 10))
            Text(item.size.bytesText)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 74, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private func binding(for item: CacheItem) -> Binding<Bool> {
        Binding(
            get: { engine.items.first(where: { $0.id == item.id })?.selected ?? item.selected },
            set: { newValue in
                if let i = engine.items.firstIndex(where: { $0.id == item.id }) {
                    engine.items[i].selected = newValue
                }
            })
    }

    private func toggleCategory(_ category: String, to: Bool) {
        for i in engine.items.indices where engine.items[i].category == category {
            engine.items[i].selected = to
        }
    }

    private func categoryToggleLabel(_ items: [CacheItem]) -> String {
        items.allSatisfy { $0.selected } ? "全不选" : "全选"
    }

    private func shortPath(_ p: String) -> String {
        return p.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

extension Array where Element == CacheItem {
    func first(id: String) -> CacheItem? { first { $0.id == id } }
}
