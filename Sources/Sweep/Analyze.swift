import SwiftUI
import AppKit

// MARK: - 数据模型 / 扫描引擎

struct DiskEntry: Identifiable, Hashable {
    let id: String            // = path
    let name: String
    let path: String
    let size: Int64
    let isDirectory: Bool
}

final class AnalyzeEngine: ObservableObject {
    @Published var path: String = NSHomeDirectory()
    @Published var entries: [DiskEntry] = []
    @Published var scanning = false
    @Published var totalScannedSize: Int64 = 0
    @Published var breadcrumb: [String] = []

    func scan(_ target: String? = nil) {
        let root = target ?? path
        guard !scanning else { return }
        scanning = true
        if target != nil {
            path = root
            breadcrumb.append(root)
        }
        entries = []
        totalScannedSize = 0
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var result: [DiskEntry] = []
            var total: Int64 = 0
            guard let kids = try? fm.contentsOfDirectory(atPath: root) else {
                DispatchQueue.main.async {
                    self.scanning = false
                }
                return
            }
            let fullPaths = kids
                .filter { !$0.hasPrefix(".") }
                .sorted()
                .map { "\(root.hasSuffix("/") ? String(root.dropLast()) : root)/\($0)" }
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: fullPaths.count) { i in
                let p = fullPaths[i]
                var st = stat()
                guard lstat(p, &st) == 0 else { return }
                let isDir = (st.st_mode & S_IFMT) == S_IFDIR
                let size: Int64
                if isDir {
                    size = Sizer.size(p)
                } else {
                    size = Int64(st.st_size)
                }
                lock.lock()
                result.append(DiskEntry(id: p,
                                        name: (p as NSString).lastPathComponent,
                                        path: p,
                                        size: size,
                                        isDirectory: isDir))
                total += size
                lock.unlock()
            }
            DispatchQueue.main.async {
                self.entries = result.sorted { $0.size > $1.size }
                self.totalScannedSize = total
                self.scanning = false
            }
        }
    }

    func goUp() {
        guard !scanning else { return }
        let parent = (path as NSString).deletingLastPathComponent
        if parent == path || parent.isEmpty { return }
        path = parent
        if !breadcrumb.isEmpty { breadcrumb.removeLast() }
        scan()
    }

    func goHome() {
        go(to: NSHomeDirectory())
    }

    func go(to target: String) {
        if scanning || target == path { return }
        breadcrumb = [target]
        path = target
        scan()
    }
}

// MARK: - 视图

struct AnalyzeView: View {
    @ObservedObject var engine: AnalyzeEngine
    @State private var confirmTrash: DiskEntry? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(title: "分析", subtitle: "点进任意目录看大小排行，右键式操作：移入废纸篓或去 Finder 找它")
                toolbarCard
                if engine.scanning {
                    Card {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("正在统计 \(shortPath(engine.path)) 下每个条目的大小…")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                entriesCard
                hintCard
            }
            .padding(20)
        }
        .background(Theme.bg)
        .onAppear {
            if engine.entries.isEmpty && !engine.scanning { engine.scan() }
        }
        .alert(item: Binding(
            get: { confirmTrash },
            set: { confirmTrash = $0 })) { entry in
            Alert(
                title: Text("移入废纸篓？"),
                message: Text("\(entry.name)（\(entry.size.bytesText)）"),
                primaryButton: .destructive(Text("移入废纸篓")) {
                    let res = Remover.remove([entry.path], mode: .trash)
                    if res.failed > 0 {
                        // 权限不足时请求管理员
                        try? Remover.adminRemove(entry.path)
                    }
                    engine.scan()
                },
                secondaryButton: .cancel(Text("取消")))
        }
    }

    private var toolbarCard: some View {
        Card {
            HStack(spacing: 10) {
                Button {
                    engine.goHome()
                } label: {
                    Image(systemName: "house")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .tint(Theme.textSecondary)
                .disabled(engine.scanning)

                Button {
                    engine.goUp()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .tint(Theme.textSecondary)
                .disabled(isAtRoot || engine.scanning)

                Text(shortPath(engine.path))
                    .font(.system(size: 12).monospaced())
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Text("本层合计 \(engine.totalScannedSize.bytesText)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg))

                Button {
                    engine.scan()
                } label: {
                    Label("重新统计", systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .disabled(engine.scanning)
            }
        }
    }

    private var entriesCard: some View {
        Card {
            VStack(spacing: 0) {
                HStack {
                    Text("条目")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text("占比 · 大小 · 操作")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.bottom, 6)
                if !engine.scanning && engine.entries.isEmpty {
                    Text("这层是空的")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.vertical, 30)
                        .frame(maxWidth: .infinity)
                }
                ForEach(engine.entries) { entry in
                    entryRow(entry)
                }
            }
        }
    }

    private var hintCard: some View {
        Card {
            HStack {
                Image(systemName: "lightbulb")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accentWarn)
                Text("建议定期看看 ~/Library/Application Support 和 ~/Downloads，这两个地方常常堆着早就不用的东西。受保护的系统路径不会被允许放入废纸篓。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var isAtRoot: Bool {
        engine.path == NSHomeDirectory() || engine.path == "/" || engine.path == "/Users"
    }

    private func entryRow(_ entry: DiskEntry) -> some View {
        let topSize = max(engine.entries.first?.size ?? 1, 1)
        let ratio = Double(entry.size) / Double(topSize)
        return HStack(spacing: 10) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .font(.system(size: 10))
                .foregroundStyle(entry.isDirectory ? Theme.accent.opacity(0.8) : Theme.textSecondary)
            Text(entry.name)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer()
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.bg)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.accent.opacity(0.75))
                        .frame(width: max(geo.size.width * CGFloat(ratio), 3))
                }
            }
            .frame(maxWidth: 150, maxHeight: 6)
            .padding(.vertical, 12)

            Text(entry.size.bytesText)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 78, alignment: .trailing)

            if entry.isDirectory {
                Button("进入") { engine.scan(entry.path) }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
            }
            Button("移到废纸篓") { confirmTrash = entry }
                .buttonStyle(.link)
                .font(.system(size: 10))
                .foregroundStyle(Theme.accentDanger)
            Button("Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
            }
            .buttonStyle(.link)
            .font(.system(size: 10))
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func shortPath(_ p: String) -> String {
        p.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
