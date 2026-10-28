# Sweep — 安静的 macOS 空间管家

参考 [Nivo](https://app.nivoclean.com)（Mole CLI 的商业壳）的产品思路，用 **Swift + SwiftUI** 做的一个本地原生桌面应用。十一个模块分四组：

| 模块 | 功能 |
|------|------|
| **清理 Clean** | 扫描浏览器与应用缓存、Xcode DerivedData/模拟器缓存、npm/pip/uv/Homebrew/Gradle 等 25 类可重建缓存。扫描完成后默认勾选全部可清理项，主按钮直接显示项数与体积；被占用、只读或需手动确认的项目默认不勾。 |
| **大文件 Large files** | 按 100 MB / 500 MB / 1 GB / 5 GB 门槛找出单个文件，边扫边出结果，可批量移入废纸篓。隐藏目录与缓存树不在范围内。 |
| **重复文件 Duplicates** | 大小分桶 → 首尾 64 KB 摘要 → 全文件 SHA256 三段校验，只有逐字节一致才归组；默认保留修改时间最早的一份。 |
| **磁盘分析 Analyze** | 列表 / 矩形树图 / 旭日图三种视图看空间去向，逐层钻取，右键可移入废纸篓。 |
| **监控 Status** | 一秒采样：CPU、内存、磁盘、上下行流量、电池/电源、负载、开机时长，每项带 60 秒 sparkline；健康分与进程列表。 |
| **优化 Optimize** | 6 个维护任务：DNS 刷新、Quick Look 缩略图清理、旧日志修剪、清空废纸篓、下载目录安装包清理、系统日志修剪。 |
| **启动项 Startup** | 扫描三个 LaunchAgents/LaunchDaemons 目录，用户级可停用与恢复，系统级只读。 |
| **内存 Memory** | 应用/联动/压缩/交换内存构成、压力等级、进程占用排行；「整理可回收内存」调用系统 purge（需管理员密码）。 |
| **卸载 Uninstall** | 列出 `/Applications` 与 `~/Applications`（含 Utilities 一层子目录）的应用与体积，按 Bundle ID／应用名找出散落在 `~/Library` 的残留，本体与残留一起进废纸篓；目录不可写的装机应用会请求一次管理员授权，界面上提前说明这一步不可恢复。Sweep 自己不会出现在清单里。 |
| **隐私清理 Privacy** | 浏览器缓存、历史、Cookie，以及最近使用、崩溃报告、Shell 历史、剪贴板；按「安全 / 丢记录 / 会退出登录」分级。 |
| **操作历史 History** | 每次删除与系统改动写入结构化 `history.jsonl`，界面同时解析旧版日志，按天分组、按类型筛选、可导出 CSV。 |

## 构建与运行

```bash
# 开发调试（swift run launch GUI application）
swift build && .build/debug/Sweep

# 打包成独立的 .app 双击运行
zsh Scripts/make_app.sh          # 默认 release
open Sweep.app
```

要求：macOS 13+，Apple Command Line Tools（无需完整 Xcode）。

## 0.7.1 界面：磨砂玻璃 + 环境光

- **面板换成玻璃**：`Panel` 从实色白改成 `ultraThinMaterial` + 0.55 透明度的自适应底色，底下的环境光能透上来，文字对比度靠自己那层实色兜住。描边是左上偏蓝、右下回灰的渐变，比一圈死灰线更像“有光打过来”。统计和主操作卡片加 `lift: true`，悬停时抬 1.5pt、阴影加深。
- **环境光**：`AmbientBackdrop` 在内容区底下铺三团蓝/青/紫雾，14–22 秒挪一次位置（浅色 0.16–0.30，深色 0.26–0.40）。为了让它看得见，各页自带的 `.background(Theme.bg)` 全部撤掉，底色统一由外壳提供。
- **侧栏选中态**：换成渐变胶囊 + 内描边 + 顶部高光 + 蓝色投影；未选中行悬停时图标转成强调色。
- **图表**：`Sparkline` 加渐变面积、一层模糊描边的外发光和末点光点；`GaugeRing` 改成角向渐变 + 发光 + 数值过渡；`ProgressBar` 渐变填充 + 半高发光（原先 0.9 倍高度的发光会把下方说明文字糊掉）。
- **细节**：主视觉徽标换成渐变方块 + 白色图标 + 周期性高光扫过；清理页的大数字改成蓝色渐变；`MetricTile` / `MetricSummary` 走 `TickerText`（macOS 14+ 有数字滚动过渡）；骨架屏从呼吸改成扫光；空状态图标背后加两圈缓慢扩散的呼吸光晕；工具栏底边换成一束慢慢游走的高光。
- 全部动效都遵守 `accessibilityReduceMotion`，关掉“减弱动态”就静止。
- 回归 149/149。界面截图见 `verification/ui-glass-clean.png`、`ui-glass-status.png`、`ui-glass-uninstall.png`。

## 0.7.0 应用图标 · 卸载模块

- **自带图标**：`IconArt.swift` 是唯一的几何来源——824×824 内容区、0.2255 圆角（对齐 macOS 图标模板）、一条自左下笔尖收细到右上圆头的“清扫弧”。`Scripts/make_icon.swift` 用它渲染 10 档尺寸交给 `iconutil` 出 `AppIcon.icns`，侧边栏的 `SweepLogo` 用同一份路径在 SwiftUI Canvas 里画，改一处两边一起变。`make_app.sh` 负责把 icns 塞进 bundle 并写 `CFBundleIconFile`。
- **底板踩过的坑**：先用超椭圆（n=5）做底板，NSWorkspace 解析出来的图标会被系统套上一层灰色“应用底板”，蓝底缩到 54%；换成系统模板的圆角比例后恢复正常。锥形笔画最初用“整条子路径 + nonzero 填充”，圆头与笔画绕向相反，重叠处被挖空——现在按子路径分别填充。
- **卸载模块接进界面**：`Uninstall.swift` 早就写好了，但只在 `ShellView` 里 `@StateObject` 了一个没人用的 `UninstallEngine`，所以侧栏看不到入口。现在 `Module.uninstall` 挂在新建的「应用」组下，渲染 `UninstallView`。
- **残留匹配收紧**：旧版用 `kid.contains(baseName)` 判匹配，`Code` 会命中 `Code Cache` 这类无辜目录。现在 Bundle ID 走精确或 `.`/`-` 分段，应用名只接受完全同名或以 `.`、空格、`-`、`_` 续写；0 字节的空目录/空 plist 也计入残留（留着比清掉更碍事）。
- **结果说清楚**：能进废纸篓的写“可恢复”，走管理员删除的单独说明“已永久删除”，失败项点名；每次卸载写一条 `kind=uninstall` 的历史记录。
- **验证**：`Scripts/test.sh` 149 项通过（新增 6 项匹配规则断言）；用一个假应用 `~/Applications/SweepTestApp.app` 与 5 份残留跑通端到端，诱饵目录 `SweepTestAppShadow` 未被误删。见 `verification/uninstall-0.7.0.md`。

## 0.6.6 家目录之外的大块占用（磁盘占满的真凶）

- 清理页新增卡片「家目录之外的大块占用」：系统升级残留、系统更新缓存、移动端更新残留、更新器临时副本、诊断日志、交换镜像。**只报告体积**，不越出清理器的家目录安全边界。
- `adminStaging` 类（如 `macOS Install Data` 13.16 GB）提供「移除 · 需授权」，点一次弹一次系统授权；`userTempClone` 直接删 `X/*.code_sign_clone`；`infoOnly` 只显示「系统自管」。
- 排查结论：`df` 在本机不可信（写入/删除 800 MB 数值不变），要看 `diskutil apfs list` 的 `Capacity Not Allocated`；`du` 对 APFS 克隆会按逻辑大小重复计数——21 GB 的 Chrome `code_sign_clone` 删掉后一个字节都没释放。
- 但更新器泄漏是真的：GoogleUpdater 每 ~6 分钟复制一份 App 重新签名，2 分钟涨 1.4 GB × 2。停用三个 launch agent 后连续 7 分钟保持 0 B。恢复命令见 `verification/disk-full-0.6.6.md`。
- 详见 `verification/disk-full-0.6.6.md`。

## 0.6.5 清理真的会清、授权只要给一次

- **默认勾选全部可清理项**：以前只勾 `recommended`（pip / SwiftPM 这类保守项），120 个候选里只勾中 2 项 17 MB，点清理几乎看不出变化。现在新增 `CacheItem.autoSelected`：可清理 + 类别安全 + 非 `explicitOnly` 就默认勾上，主按钮直接写「清理 N 项 · X GB」，空选时点主按钮会自动全选。
- **`explicitOnly` 类别**：默认永不勾选（留给废纸篓这类删掉就找不回的目标）。
- **稳定的代码签名**：`Scripts/setup_signing.sh` 生成固定的本地证书 "Sweep Local Signing"，`make_app.sh` 优先用它签名。designated requirement 变成 `identifier "com.sweep.macos" and certificate root = H"…"`，跨重打包不变，**系统授权（桌面/文稿/下载、其他应用数据）只需给一次**；此前用 ad-hoc 签名，每次重新打包 cdhash 都变，等于每次都换了个 App，授权反复失效。缺证书时仍退回 ad-hoc。
- 移除 Safari 容器内缓存路径（需要「完全磁盘访问权限」才能读，只会反复报读取受限）；`Info.plist` 补 `NSAppleEventsUsageDescription`。
- 优化页里需要提权的任务，点击后先说明「接下来会弹一次系统密码窗口」，不再让人莫名撞上授权框。
- 详见 `verification/clean-and-permissions-0.6.5.md`。

## 0.6.1 / 0.6.2 桌面黑洞：尺寸与交互

- 面板 240 → **168pt**，投递半径 112 → 62pt。指针在圈外（>74pt）时窗口 `ignoresMouseEvents`，四角空白直接穿透到桌面，不再抢点击；拖拽进行中强制恢复可接收，保证文件一定落得进来。
- 几何量集中在 `BlackHoleMetrics`，前端 `WIDGET_SIZE` 取真实窗口尺寸换算中心、半径与图标偏移，改大小不用动两处。
- **视觉沿用上游 `charleypeng/kakabin` 的暖色吸积盘**（0.6.1 曾试过冷色刻线环，观感不佳，0.6.2 整体退回）：橙色盘面 + 光子环 + 淡星点，圆形软边外透明。
- 界面文字/图标按 168pt 收紧（34px 图标、9–10px 标签），配色仍用暖调以贴合盘面。
- 详见 `verification/black-hole-widget-0.6.1.md`（含 0.6.2 回退记录）。

## 0.6.0 macOS 玻璃界面

参考 [macos27-claude](https://github.com/a2d2-dev/macos27-claude) 的 `glass.css`、窗口与 Finder 组件，将界面层次适配为原生 SwiftUI：

- 系统磨砂侧栏与工具栏、蓝色选中态、浅色阅读面、细描边和轻阴影；十个模块沿用现有分组与功能。
- 浅色/深色随系统外观切换；减少透明度时使用实色侧栏，减少动态效果时关闭按钮和导航动效。
- 清理页突出所选大小、当前选择和缓存分组，路径、受限原因与永久删除确认仍完整显示。
- 监控页统一指标卡片高度，放大实时数值与趋势图，磁盘可用量和占用进度同时展示。
- 按钮使用原生 `ButtonStyle` 的按下状态，支持鼠标与键盘；移除原来的附加拖动手势。
- 黑洞绘制资源、文件投递、回收流程与单实例守卫保持既有实现。

界面通过 AppKit 材质与 SwiftUI 控件实现。参考项目的 MIT 许可证随应用资源打包，说明见 `Sources/Sweep/Resources/ThirdParty/`。

## 0.5.0 界面重构 · 六个新模块

### 视觉系统

界面按 [ai-design-skills](https://github.com/elayadesign/ai-design-skills)（MIT）的 `landing-page-design` 视觉系统重做，落在 `DesignSystem.swift`：

- **底板只取五档**：`#000000` 窗口、`#181818` 面板、`#1F1F1F` 次级面、`#272727` 悬停、`#313131` 描边。背景一律平涂，不做渐变。
- **渐变只用于标题文字**：白 → `#9B9B9B`，侧边栏品牌名与每个页头标题都用它。
- **字号阶梯** 12 / 14 / 16 / 18 / 20 / 24 / 30；**间距令牌** 2 / 4 / 8 / 12 / 16 / 24 / 32；**圆角** 6 / 8 / 12 / 16，嵌套时按 `inner = outer − gap` 收窄。
- **动效**统一 `cubic-bezier(0.22, 1, 0.36, 1)`，只作用于透明度与缩放，并尊重「减弱动态效果」。
- **状态齐全**：每个交互都有悬停、按下 `scale(0.98)`、禁用、加载骨架与空状态；空状态是带下一步动作的完整版面，不是空白面板。
- 刻意偏离的两处：图标用 SF Symbols 而不是 Phosphor/Solar（原生应用不引 Web 图标库）；滚动显隐改用 SwiftUI 原生动画，不搬 `IntersectionObserver` 那一套。

### 新增能力

- **大文件**：`LargeFileScanner` 只走普通文件，跳过 `.app`/`.photoslibrary` 等包内部，每 2000 个文件回传一次部分结果，扫描过程就能看到列表；取消立即生效。
- **重复文件**：默认不自动扫描（整文件校验开销大），需手动开始。`DuplicateGroup.keeper` 取最早修改的一份，`wasted` 按「份数 − 1」计。
- **矩形树图**：`TreemapLayout.squarify` 实现 squarified treemap，最多画 24 块 + 其余合并；面积严格正比于体积，测试校验了填充率与比例。
- **旭日图**：按钻取路径逐层成环，悬停时中心显示该分段名称、体积与占比，右侧图例与扇区共用同一套明度阶梯。
- **内存**：`host_statistics64` 读应用/联动/压缩内存，`sysctlbyname(vm.swapusage)` 读交换，`kern.memorystatus_vm_pressure_level` 读压力；进程排行来自 `ps`，退出走 `NSRunningApplication.terminate()`。
- **隐私清理**：`Remover.remove(..., extraAllow:)` 只放行条目自己声明的路径，全局白名单不放宽；测试覆盖了「清单内可删 / 清单外仍被拒」。
- **操作历史**：`history.jsonl` 是权威来源，旧 `operations.log` 只保留早于第一条结构化记录的部分，避免同一操作被计两次；测试产生的记录写到临时目录，不污染用户历史。

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
