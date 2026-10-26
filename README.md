# Sweep — 安静的 macOS 空间管家

参考 [Nivo](https://app.nivoclean.com)（Mole CLI 的商业壳）的产品思路，用 **Swift + SwiftUI** 做的一个本地原生桌面应用。五个模块对应 Nivo 的五颗行星：

| 模块 | 功能 |
|------|------|
| **清理 Clean** | 扫描浏览器与应用缓存、Xcode DerivedData/模拟器缓存、npm/pip/uv/Homebrew/Gradle 缓存。默认不勾选；少量明确缓存可加入推荐选择，其他应用缓存逐项复核后才可清理。 |
| **卸载 Uninstall** | 读取 /Applications（含家目录），展示应用体积/版本/最后修改时间；卸载时本体进废纸篓（可恢复），并按 Bundle ID + 名称搜索 `~/Library` 下 7 类残留一并清理 |
| **优化 Optimize** | 6 个维护任务：DNS 刷新、Quick Look 缩略图清理、旧日志修剪、清空废纸篓、下载目录安装包清理、系统日志修剪。免密任务可一键顺序执行；管理员任务通过系统授权框 |
| **分析 Analyze** | 任意目录逐层钻取的空间排行：条目按大小排序，带占比条，可"进入 / 移入废纸篓 / 在 Finder 中显示" |
| **监控 Status** | 一秒采样：CPU、内存、磁盘、上下行流量、电池/电源、负载、开机时长，每项带 60 秒 sparkline；健康分（0-100）；进程列表（ps 轮询）支持排序与置顶钉选 |

## 构建与运行

```bash
# 开发调试（swift run launch GUI application）
swift build && .build/debug/Sweep

# 打包成独立的 .app 双击运行
zsh Scripts/make_app.sh          # 默认 release
open Sweep.app
```

要求：macOS 13+，Apple Command Line Tools（无需完整 Xcode）。

## 0.4.0 启动项 · 规则扩容 · 删除闸门修复

- 新增 **启动项** 模块：扫描 `~/Library/LaunchAgents`、`/Library/LaunchAgents`、`/Library/LaunchDaemons`，解析 Label / 程序路径 / RunAtLoad，并用 `launchctl list` 标出运行状态。用户级代理可停用与恢复（`launchctl bootout` + 把 plist 移入 `~/Library/Application Support/Sweep/disabled-launch-agents`，不删除文件）；系统代理与守护进程只读展示，提示需管理员权限。
- **清理规则从 13 类扩到 25 类**：新增 Cargo、Go 构建缓存、CocoaPods、SwiftPM、JetBrains、VS Code 缓存、Yarn、pnpm 缓存与全局存储（复核项）、Playwright/Cypress/Selenium、electron-builder、Xcode 辅助缓存。所有新增路径都先过 `PathSafety` 白名单，`~/Library/Application Support/Code` 只放行 4 个缓存子目录，设置与工作区仍在保护区。
- **修复删除闸门**：`PathSafety.protected` 里的根目录 `/` 参与了前缀匹配，导致**每一条绝对路径都被判为受保护**，`Remover` 全线拒绝。日志里累计 618 条 `SKIP(protected)`，也就是说 0.3.x 的「优化」一键任务、分析页「移入废纸篓」、卸载残留清理实际上从未成功执行。现在根目录只做精确匹配，白名单照旧生效。
- 规则覆盖面的参考来自 [MangoDisk](https://github.com/harry0703/MangoDisk)（GPL-3.0）：只借鉴了路径清单与「可重建」结论，未复制其代码或 TOML 规则文件，Sweep 仍是 MIT。

## 0.3.1 单实例与重复悬浮窗

桌面只应出现一个黑洞悬浮窗。0.3.1 在启动早期用 `flock` 抢占 `~/Library/Application Support/Sweep/instance.lock`：第二个 Sweep 进程会唤起已有窗口后立刻退出，不再各自创建一个黑洞面板。锁由内核持有，进程崩溃会自动释放，可用 `SWEEP_ALLOW_MULTI_INSTANCE=1` 临时绕过（仅用于调试）。

同一症状的另一个来源是旧的原型 App（`/Applications/DiskPilot.app`，Python 悬浮小组件）也在画黑洞。该应用与它的 `com.diskpilot.widget` 开机自启项已移除，应用本体在废纸篓、备份在 `~/ZCodeProject/disk-monitor/_removed-20261026/`。

## 0.3.0 磁盘清理

- 扫描范围限于明确的用户缓存目录；不扫描废纸篓、Xcode Archives、个人文件或应用数据目录。
- 所有候选初始未选；浏览器、开发工具和包管理器的明确缓存可加入“选择推荐项”，其他 `~/Library/Caches` 直接子目录只供逐项复核。
- 运行中的应用缓存、Sweep 自身缓存、同步状态、模型、项目依赖、符号链接、云占位、跨卷内容和扫描不完整的条目不会进入可清理选择。
- 显示逻辑大小、磁盘占用和硬链接回收估算；扫描有取消、当前路径和受限详情。执行前重查候选身份与内容，结果逐项汇总；清理页的缓存清理为永久删除，不经过废纸篓。

## 0.2.0 桌面黑洞

侧边栏点击「桌面黑洞」显示悬浮黑洞；再次点击或右键可隐藏。鼠标从窗口外靠近时，吸积盘与光晕响应；左键拖动可调整位置。

从 Finder 拖入本地文件或文件夹后，由 AppKit 接收文件 URL，Swift 使用系统 `trashItem` 移到可恢复的废纸篓。成功后，真实文件图标旋转、拉伸、缩小吸入；失败项回弹并显示原因。此入口不使用永久删除或管理员回退，关键目录及凭据位置受到保护。

画面基于 [Kakabin](https://github.com/charleypeng/kakabin) 的 MIT 授权 GLSL / Three.js 代码，许可证随应用资源一起打包；画面和文件操作均在本机完成。

已生成的本地资源随源码提供。修改画面时，在 `BlackHoleWeb/` 运行 `npm ci && npm run build`，再打包 Swift app。隐藏黑洞后停止画面刷新。

0.2.1 将原生文件接收区放到画面上层，避免 WebKit 自己的拖放接收路径截获文件；使用由接收方处理的拖放操作，回收由 Sweep 根据系统废纸篓结果完成。

`SWEEP_TEST_REAL_TRASH=1 zsh Scripts/test.sh` 仅回收本工作区自动生成的夹具，并将其从废纸篓恢复；普通测试跳过真实废纸篓操作。

## 0.1.1 性能与数据修正

- 系统指标在后台采样，每秒合并发布；离开监控页后取消任务，重新进入先建立差分基线。
- CPU 使用相邻采样的内核计数；进程内存直接读取 RSS，采用二进制内存单位。
- 网络读取真实 `if_data`，按 Wi-Fi / 以太网物理接口分别差分，处理回绕和接口重连；不重复累计 VPN 隧道。
- 进程表独立刷新、按需渲染，保留排序与按 PID 置顶；读取错误直接显示。
- 仪表按采样结果更新，去除每秒重复启动的补间动画；CPU、内存、磁盘颜色统一按 80% / 90% 使用率分级。
- 普通文件和嵌套应用包纳入大小统计，硬链接在同一棵目录树内按设备号与 inode 去重。
- 三个状态扫描页面复用已有结果，刷新按钮可手动重新统计。

使用 `zsh Scripts/test.sh` 运行独立回归检查，无需安装 XCTest 或完整 Xcode。
文件体积是逻辑大小估算；APFS 克隆、稀疏文件以及跨条目共享的硬链接会影响实际释放空间。
实测记录与已发现的原有删除分支问题见 `verification/investigation.md`。

## 安全设计（故意保守）

- **先展示后删除**：清理/卸载均要求逐项确认，删除前有确认弹窗。清理页使用独立的缓存范围验证与执行前重检。
- **卸载走废纸篓**：应用本体和残留都移入 Trash，错误点击可恢复；缓存类为真正释放字节才永久删除。
- **路径保护清单**：其他模块继续使用 `Common.swift` 的 `PathSafety`；清理页使用独立缓存白名单，仅允许列出的用户缓存根及其受检子路径。
- **无遥测**：所有扫描本地完成，唯一"网络请求"是每个操作写本地日志（`~/Library/Logs/Sweep/operations.log`）。
- **软链不跟随**：大小统计用 `URLDirectoryEnumerator` + `lstat`，硬链接在树内去重避免 uv/pnpm 目录双倍计数。

## 版本管理

版本用 git commit + tag 记录，不再复制整份目录当快照（历史上 `verification/` 下的整份源码快照已清理，只在废纸篓留档）。

```bash
git tag -a v0.3.1 -m "单实例守卫，去掉重复悬浮窗"   # 一个版本一个 tag
zsh Scripts/make_app.sh && ditto Sweep.app /Applications/Sweep.app
```

`.build/`、`node_modules/`、`*.app/` 和测试夹具不进版本库；回滚用 tag 重新构建，而不是保留安装包副本。

## 想扩展的点

- Treemap 可视化（目前 Analyze 是排行条）
- `sudo` 相关更强的免打扰体验（Touch ID 集成）
- 清理白名单（`~/.config/sweep/whitelist`）
- `sparkline` 量程自适应

模块结构：

```
Sources/Sweep/
├── SweepApp.swift   # 侧边栏 + 5 模块路由
├── Theme.swift      # 暗色设计系统（卡片/仪表环/sparkline）
├── Common.swift     # 格式化、路径保护、删除策略、大小统计、操作日志
├── Status.swift     # mach/IOKit/getifaddrs 采样 + 仪表盘视图
├── Clean.swift      # 缓存目录分类 + 扫描/确认/删除引擎
├── Uninstall.swift  # 应用清单 + 残留追踪
├── Optimize.swift   # 维护任务目录 + 一键执行链
└── Analyze.swift    # 目录钻取排行
```

MIT License。
