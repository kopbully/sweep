import SwiftUI
import AppKit

// MARK: - 数据模型

struct DiskEntry: Identifiable, Hashable {
    let id: String            // = path
    let name: String
    let path: String
    /// 逻辑长度（文件内容之和），稀疏文件会把这个值抬得很高
    let size: Int64
    /// 实际占用的磁盘块，与 `du` 同口径
    let allocated: Int64
    let isDirectory: Bool

    /// 真正吃掉的空间。界面上一律以它为准。
    ///
    /// 纯稀疏文件 `allocated` 就是 0，此时不能回退到逻辑长度——那正是要修的错误。
    var footprint: Int64 { allocated }

    /// 逻辑长度比实际占用多出来的部分：稀疏文件、APFS 克隆、压缩文件
    var inflated: Int64 { max(size - allocated, 0) }

    /// 虚高到值得提示（多出 512 MB 以上，或逻辑长度至少是占用的两倍）
    var isInflated: Bool { inflated >= 536_870_912 && size >= allocated * 2 }
}

// MARK: - 引擎

final class AnalyzeEngine: ObservableObject {
    @Published var path: String = NSHomeDirectory()
    @Published var entries: [DiskEntry] = []
    @Published var scanning = false
    @Published var totalScannedSize: Int64 = 0
    /// 本层实际占用（du 口径），与 totalScannedSize 的逻辑长度并列
    @Published var footprintScannedSize: Int64 = 0
    @Published var trail: [String] = [NSHomeDirectory()]

    var breadcrumb: [String] { trail }

    func scan(_ target: String? = nil) {
        let root = target ?? path
        guard !scanning else { return }
        scanning = true
        if target != nil {
            path = root
            updateTrail(for: root)
        }
        entries = []
        totalScannedSize = 0
        footprintScannedSize = 0
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var result: [DiskEntry] = []
            var total: Int64 = 0
            guard let kids = try? fm.contentsOfDirectory(atPath: root) else {
                DispatchQueue.main.async { self.scanning = false }
                return
            }
            let fullPaths = kids
                .filter { !$0.hasPrefix(".") }
                .sorted()
                .map { "\(root.hasSuffix("/") ? String(root.dropLast()) : root)/\($0)" }
            let lock = NSLock()
            var foot: Int64 = 0
            DispatchQueue.concurrentPerform(iterations: fullPaths.count) { i in
                let p = fullPaths[i]
                var st = stat()
                guard lstat(p, &st) == 0 else { return }
                let isDir = (st.st_mode & S_IFMT) == S_IFDIR
                // 稀疏文件（Docker.raw 这类）逻辑长度可达实际占用的上千倍，
                // 两种口径都取，界面以实际占用为准。
                let m = Sizer.measure(p)
                lock.lock()
                result.append(DiskEntry(id: p,
                                        name: (p as NSString).lastPathComponent,
                                        path: p,
                                        size: m.logical,
                                        allocated: m.allocated,
                                        isDirectory: isDir))
                total += m.logical
                foot += m.allocated
                lock.unlock()
            }
            let sorted = result.sorted { $0.footprint > $1.footprint }
            DispatchQueue.main.async {
                self.entries = sorted
                self.totalScannedSize = total
                self.footprintScannedSize = foot
                self.scanning = false
            }
        }
    }

    func goUp() {
        guard !scanning, trail.count > 1 else { return }
        let parent = trail[trail.count - 2]
        trail.removeLast()
        path = parent
        scan()
    }

    func goHome() {
        guard !scanning else { return }
        trail = [NSHomeDirectory()]
        path = NSHomeDirectory()
        scan()
    }

    func go(to target: String) {
        guard !scanning, target != path else { return }
        path = target
        updateTrail(for: target)
        scan()
    }

    private func updateTrail(for target: String) {
        if let index = trail.firstIndex(of: target) {
            trail = Array(trail.prefix(through: index))
            return
        }
        if target.hasPrefix(path.hasSuffix("/") ? path : path + "/") {
            trail.append(target)
        } else {
            trail = [target]
        }
    }
}

// MARK: - 视图

struct AnalyzeView: View {
    @ObservedObject var engine: AnalyzeEngine
    @State private var pendingTrash: DiskEntry?
    @State private var trashError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s300) {
                PageHeader("磁盘分析", subtitle: "矩形面积就是实际占用。点文件夹往里钻，右键可在访达中显示或移入废纸篓。") {
                    SweepButton(.secondary, title: "重新统计", systemImage: "arrow.clockwise") { engine.scan() }
                        .disabled(engine.scanning)
                }

                toolbar
                if engine.scanning { scanningPanel }
                content
            }
            .padding(Space.s300)
        }
        .pageSurface()
        .onAppear { if engine.entries.isEmpty && !engine.scanning { engine.scan() } }
        .alert(item: Binding(get: { pendingTrash }, set: { pendingTrash = $0 })) { entry in
            Alert(title: Text("移入废纸篓？"),
                  message: Text("\(entry.name)（\(entry.size.bytesText)）"),
                  primaryButton: .destructive(Text("移入废纸篓")) {
                      // 只走废纸篓：旧实现在失败（包括被 PathSafety 拒绝的受保护目录）时
                      // 回退到管理员 rm -rf，等于把“可恢复”悄悄变成了永久删除并绕过保护清单。
                      let result = Remover.remove([entry.path], mode: .trash)
                      if result.removed > 0 {
                          OperationHistory.record(kind: .trash,
                                                  summary: "移入废纸篓：\(shortPath(entry.path))",
                                                  bytes: entry.size, count: 1)
                      } else {
                          trashError = "没能移入废纸篓：\(entry.name)。受保护的目录或没有权限的位置不会被删除。"
                      }
                      engine.scan()
                  },
                  secondaryButton: .cancel(Text("取消")))
        }
        .alert("未删除", isPresented: Binding(get: { trashError != nil }, set: { if !$0 { trashError = nil } })) {
            Button("好") { trashError = nil }
        } message: {
            Text(trashError ?? "")
        }
    }

    private var toolbar: some View {
        Panel {
            HStack(spacing: Space.s75) {
                SweepButton(.secondary, title: "主目录", systemImage: "house") { engine.goHome() }
                    .disabled(engine.scanning)
                SweepButton(.secondary, title: "上一级", systemImage: "chevron.up") { engine.goUp() }
                    .disabled(engine.trail.count <= 1 || engine.scanning)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.s25) {
                        ForEach(Array(engine.trail.enumerated()), id: \.offset) { index, item in
                            if index > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.textMuted)
                            }
                            Button {
                                if index < engine.trail.count - 1 { engine.go(to: item) }
                            } label: {
                                Text(displayName(item))
                                    .font(Typo.f(Typo.xs, index == engine.trail.count - 1 ? .semibold : .regular))
                                    .foregroundStyle(index == engine.trail.count - 1 ? Theme.textPrimary : Theme.textSecondary)
                                    .padding(.horizontal, Space.s50)
                                    .padding(.vertical, Space.s25)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: 420)

                Spacer()
                Tag(text: "本层占用 \(engine.footprintScannedSize.bytesText)", tone: .neutral)
            }
        }
    }

    private var scanningPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: Space.s100) {
                HStack(spacing: Space.s75) {
                    Text("正在统计每个条目的大小").font(Typo.f(Typo.sm, .medium)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(shortPath(engine.path)).font(Typo.mono(Typo.xs)).foregroundStyle(Theme.textMuted)
                        .lineLimit(1).truncationMode(.middle)
                }
                ProgressBar(value: 0.4)
                HStack(spacing: Space.s100) {
                    Skeleton(height: 10, width: 220)
                    Skeleton(height: 10, width: 90)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if engine.entries.isEmpty && !engine.scanning {
            Panel {
                EmptyState(icon: "folder",
                           title: "这层是空的",
                           message: "没有可统计的条目，返回上一级或回到主目录继续看。") {
                    SweepButton(.secondary, title: "回主目录", systemImage: "house") { engine.goHome() }
                }
            }
        } else if engine.scanning && engine.entries.isEmpty {
            Panel { HStack { Skeleton(height: 14, width: 180); Spacer() } .padding(.vertical, Space.s300) }
        } else {
            treemapPanel
        }
    }

    private var treemapPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: Space.s100) {
                GroupTitle(text: "体积占比", trailing: "最多显示 24 块 + 其他")
                TreemapView(entries: engine.entries,
                            onSelect: { open($0) },
                            onReveal: { reveal($0) },
                            onTrash: { pendingTrash = $0 })
            }
        }
    }

    private func open(_ entry: DiskEntry) {
        if entry.isDirectory {
            engine.go(to: entry.path)
        } else {
            pendingTrash = entry
        }
    }

    private func reveal(_ entry: DiskEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
    }

    private func displayName(_ path: String) -> String {
        if path == NSHomeDirectory() { return "主目录" }
        if path == "/" { return "磁盘" }
        return (path as NSString).lastPathComponent
    }
}
