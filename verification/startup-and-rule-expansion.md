# 0.4.0 验证记录（启动项 · 规则扩容 · 删除闸门）

## 1. 删除闸门 bug（本次最重要的发现）

**现象**：`PathSafety.protected` 第一项是 `/`。`isProtected` 的前缀分支只要求 `b.hasSuffix("/")`，而 `/` 本身就以 `/` 结尾，因此任意绝对路径都被判为受保护：

```
for banned in protected {
    let b = (banned as NSString).standardizingPath
    if p == b { return true }
    if p.hasPrefix(b) && b.hasSuffix("/") { return true }   // b == "/" 时命中一切
}
```

**影响面**：`Remover.remove` 是优化页 4 个维护任务、分析页「移入废纸篓」、卸载页残留清理的唯一删除闸门；全被拒绝且只写一行日志。证据：

```
$ grep -c "SKIP(protected)" ~/Library/Logs/Sweep/operations.log
618
$ grep "SKIP(protected)" ... | tail -1
[2026/10/25 17:01:40] SKIP(protected) /Users/focus/Library/Caches/io.github.clash-verge-rev.clash-verge-rev
```

**修复**：根目录只参与精确匹配，不再进入前缀分支。修复前后的判定矩阵（探针程序实测）：

| 路径 | 修复前 del / trash | 修复后 del / trash |
| --- | --- | --- |
| `~/Library/Caches/pip` | n / n | **Y / Y** |
| `~/Library/Application Support/Code/Cache` | n / n | **Y / Y** |
| `~/Library/pnpm/store` | n / n | **Y / Y** |
| `~/Documents/secret.txt` | n / n | n / **Y**（可恢复） |
| `/`、`/System` | n / n | n / n（仍受保护） |
| `~/Desktop/x.txt` | n / n | n / **Y**（可恢复） |

永久删除仍然严格限定在白名单前缀内，没有放宽到用户资料目录。

## 2. 启动项模块

- 扫描来源：`~/Library/LaunchAgents`、`/Library/LaunchAgents`、`/Library/LaunchDaemons`；软链 plist 不纳入管理；`launchctl list` 解析运行状态（跳过表头行）。
- 界面实测：共 **47 项自启，其中 28 项已启用**；用户代理排在前面并带「停用」按钮，系统守护标「系统守护 / 需管理员」。（截图 `startup-module.png`）
- 端到端自测（临时 plist `com.sweep.selftest`，测完删除）：

```
fixture created: true
discovered scope=userAgent manageable=true enabled=false
disable -> moved to store: true
enable -> restored to LaunchAgents: true
SELFTEST PASS
```

- 停用只移动文件到 `~/Library/Application Support/Sweep/disabled-launch-agents/`，不删除；启用会移回 `~/Library/LaunchAgents` 并 `launchctl bootstrap`。

## 3. 清理规则扩容

13 → **25** 类。新增路径均核对过「可重建」事实（各包管理器官方缓存目录），并逐条通过白名单断言：

```swift
check(CleanCatalog.scanTargets().allSatisfy {
    PathSafety.canDelete($0.path) || !fm.fileExists(atPath: $0.path)
}, "every scannable cleanup target is covered by the safety whitelist")
```

放宽白名单的范围只有两处，且都很窄：`~/Library/Application Support/Code` 下的 4 个缓存子目录、`~/Library/pnpm/store`（`recommended: false`，需逐项确认）。回归测试专门断言 `~/Library/Application Support/Code/User/settings.json` **不可删除**。

## 4. 测试

`zsh Scripts/test.sh` → **91/91 通过**（0.3.1 为 73 项，新增 18 项：单实例锁 4 + 启动项解析 6 + 白名单自检 5 + 删除闸门 6，其中部分为同一用例的多种断言）。

## 5. 许可证边界

MangoDisk 为 **GPL-3.0**，Sweep 为 MIT，二者不兼容。本次只参考了它的规则**路径清单**与「安全/可重建」结论（这些属于公开事实，且各工具官方文档也有记载），没有复制任何 Rust/TOML 代码或规则文件进来。Sweep 的规则结构、扫描引擎、快照校验全部是自有实现。
