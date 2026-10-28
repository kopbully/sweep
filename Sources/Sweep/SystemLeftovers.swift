import Foundation

/// 家目录之外的已知空间占用：清理器本身的安全边界只在 home 内，
/// 这些位置单独报告体积，是否移除由用户逐项决定。
struct SystemLeftover: Identifiable, Equatable {
    enum Kind: Equatable {
        /// 系统升级残留（需要管理员授权才能删）
        case adminStaging
        /// 更新器留下的临时签名副本（属主是当前用户，可直接删）
        case userTempClone
        /// 仅展示，不建议由工具删除（系统自管）
        case infoOnly
    }

    let id: String
    let title: String
    let detail: String
    let path: String
    var size: Int64
    let kind: Kind

    var isRemovable: Bool { kind != .infoOnly }
    var needsAdmin: Bool { kind == .adminStaging }
}

enum SystemLeftovers {
    /// 已知位置清单（不含体积，便于测试断言）
    static func locations(tempDirectory: String = NSTemporaryDirectory()) -> [SystemLeftover] {
        var items: [SystemLeftover] = [
            SystemLeftover(id: "macOSInstallData",
                           title: "系统升级残留",
                           detail: "旧版 macOS 安装包，与当前系统无关，可安全移除",
                           path: "/System/Volumes/Data/macOS Install Data",
                           size: 0, kind: .adminStaging),
            SystemLeftover(id: "libraryUpdates",
                           title: "系统更新缓存",
                           detail: "已安装更新的安装包残留",
                           path: "/Library/Updates",
                           size: 0, kind: .adminStaging),
            SystemLeftover(id: "mobileSoftwareUpdate",
                           title: "移动端系统更新残留",
                           detail: "iOS/iPadOS 更新包残留",
                           path: "/System/Volumes/Data/MobileSoftwareUpdate",
                           size: 0, kind: .adminStaging),
            SystemLeftover(id: "updaterClones",
                           title: "更新器临时副本",
                           detail: "浏览器更新器反复复制自身的残留，可安全清理",
                           path: updaterCloneRoot(tempDirectory: tempDirectory),
                           size: 0, kind: .userTempClone),
            SystemLeftover(id: "diagnostics",
                           title: "系统诊断日志",
                           detail: "系统自管的诊断数据，需要在「存储」里由系统回收",
                           path: "/private/var/db/diagnostics",
                           size: 0, kind: .infoOnly),
            SystemLeftover(id: "swap",
                           title: "交换与睡眠镜像",
                           detail: "内存交换文件，由系统按内存压力自动伸缩",
                           path: "/private/var/vm",
                           size: 0, kind: .infoOnly),
        ]
        if items.isEmpty { items = [] }
        return items
    }

    /// 更新器把 app 复制到这里再签名：`<TMPDIR 的上一级>/X/*.code_sign_clone`
    static func updaterCloneRoot(tempDirectory: String) -> String {
        let parent = (tempDirectory.hasSuffix("/") ? String(tempDirectory.dropLast()) : tempDirectory) as NSString
        return parent.deletingLastPathComponent + "/X"
    }

    /// 扫描体积；不存在或不可读的项会被过滤掉
    static func scan(tempDirectory: String = NSTemporaryDirectory()) -> [SystemLeftover] {
        locations(tempDirectory: tempDirectory).compactMap { item in
            var measured = item
            let size = Sizer.footprint(item.path)
            guard size > 0 else { return nil }
            measured.size = size
            return measured
        }
    }

    /// 移除一项。adminStaging 走一次系统授权对话框。
    static func remove(_ item: SystemLeftover) throws {
        guard item.isRemovable else { throw RemovalError.notRemovable }
        switch item.kind {
        case .userTempClone:
            let fm = FileManager.default
            guard let children = try? fm.contentsOfDirectory(atPath: item.path) else { return }
            for name in children where name.hasSuffix(".code_sign_clone") {
                try? fm.removeItem(atPath: item.path + "/" + name)
            }
        case .adminStaging:
            try removeWithAdministrator(item.path)
        case .infoOnly:
            throw RemovalError.notRemovable
        }
    }

    enum RemovalError: LocalizedError {
        case notRemovable
        case authorizationFailed(String)

        var errorDescription: String? {
            switch self {
            case .notRemovable: return "该项不由工具删除。"
            case .authorizationFailed(let message): return message
            }
        }
    }

    static func removeWithAdministrator(_ path: String) throws {
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let source = "do shell script \"rm -rf \(quoted)\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else {
            throw RemovalError.authorizationFailed("无法创建授权脚本")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "授权或删除失败"
            throw RemovalError.authorizationFailed(message)
        }
        OperationsLog.write("ADMIN-REMOVE \(path)")
    }
}
