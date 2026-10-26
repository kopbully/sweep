import Foundation

/// 单实例锁：两个 Sweep 进程会各自创建一个桌面黑洞面板，在桌面上表现为
/// 两个黑洞悬浮窗叠在一起。锁由内核持有，进程退出（含崩溃）时自动释放，
/// 因此不会残留死锁文件。
final class SingleInstanceLock {
    let path: String
    private var descriptor: Int32 = -1

    init(path: String = NSHomeDirectory() + "/Library/Application Support/Sweep/instance.lock") {
        self.path = path
    }

    var isHeld: Bool { descriptor >= 0 }

    /// 抢占锁；返回 false 表示已有另一个实例持有。
    /// 锁文件不可写时按"允许启动"处理，避免因为磁盘或权限问题打不开应用。
    @discardableResult
    func acquire() -> Bool {
        if descriptor >= 0 { return true }
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        descriptor = fd
        _ = ftruncate(fd, 0)
        let record = "\(getpid())\n"
        _ = record.withCString { write(fd, $0, strlen($0)) }
        return true
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
