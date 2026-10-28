import Foundation

enum Module: String, Hashable, CaseIterable, Identifiable {
    case clean, largeFiles, duplicates, analyze
    case status, optimize, startup, memory
    case uninstall, privacy, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clean: return "清理"
        case .largeFiles: return "大文件"
        case .duplicates: return "重复文件"
        case .analyze: return "磁盘分析"
        case .status: return "监控"
        case .optimize: return "优化"
        case .startup: return "启动项"
        case .memory: return "内存"
        case .uninstall: return "卸载"
        case .privacy: return "隐私清理"
        case .history: return "操作历史"
        }
    }

    var glyph: String {
        switch self {
        case .clean: return "wind"
        case .largeFiles: return "doc.zipper"
        case .duplicates: return "doc.on.doc"
        case .analyze: return "chart.pie"
        case .status: return "waveform.path.ecg"
        case .optimize: return "bolt.horizontal"
        case .startup: return "power"
        case .memory: return "memorychip"
        case .uninstall: return "xmark.bin"
        case .privacy: return "hand.raised"
        case .history: return "clock.arrow.circlepath"
        }
    }

    var hint: String {
        switch self {
        case .clean: return "扫描可再生缓存、日志与废纸篓"
        case .largeFiles: return "揪出占地方的大文件"
        case .duplicates: return "同一份内容只留一份"
        case .analyze: return "看看磁盘空间都去哪了"
        case .status: return "CPU · 内存 · 磁盘 · 网络 · 电源"
        case .optimize: return "一键运行安全的维护任务"
        case .startup: return "管理登录与开机自动运行的后台程序"
        case .memory: return "看清谁在吃内存，回收可释放部分"
        case .uninstall: return "把应用连同它的残留一起清干净"
        case .privacy: return "清掉浏览器与系统留下的痕迹"
        case .history: return "每一次删除都有据可查"
        }
    }
}

struct ModuleGroup: Identifiable {
    let id: String
    let title: String
    let modules: [Module]

    static let all: [ModuleGroup] = [
        ModuleGroup(id: "space", title: "空间", modules: [.clean, .largeFiles, .duplicates, .analyze]),
        ModuleGroup(id: "system", title: "系统", modules: [.status, .optimize, .startup, .memory]),
        ModuleGroup(id: "apps", title: "应用", modules: [.uninstall]),
        ModuleGroup(id: "record", title: "记录", modules: [.privacy, .history]),
    ]
}
