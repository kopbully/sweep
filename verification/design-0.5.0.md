# 0.5.0 界面重构与六个新模块

时间：2026-10-26
构建：`zsh Scripts/make_app.sh` → `/Applications/Sweep.app` 0.5.0（ad-hoc 签名校验通过）
回归：`zsh Scripts/test.sh` → **123/123 通过**（`design-0.5.0-tests.txt`）

## 一、设计规范来源与落地

规范来自 [elayadesign/ai-design-skills](https://github.com/elayadesign/ai-design-skills)（MIT）中的 `landing-page-design` 视觉系统，落在 `Sources/Sweep/DesignSystem.swift`。

| 规则 | 落地方式 |
|---|---|
| 暗色底板只用 5 档 | `bg #000000` / `surface #181818` / `surfaceRaised #1F1F1F` / `surfaceHover #272727` / `border #313131` |
| 背景禁止渐变 | 所有面板、卡片、工具栏一律平涂，渐变只出现在标题文字（`Theme.titleGradient` 白 → `#9B9B9B`） |
| 字号阶梯 | `Typo` 12 / 14 / 16 / 18 / 20 / 24 / 30，仅允许这七档 |
| 间距令牌 | `Space` 2 / 4 / 8 / 12 / 16 / 24 / 32 / 40 / 48 |
| 圆角与嵌套公式 | `Radius.nested(outer:gap:)` 实现 `inner = outer − gap`，≤2 时归零 |
| 动效曲线 | `Motion.base` = `timingCurve(0.22, 1, 0.36, 1, 0.5s)`，只动 opacity / scale |
| 状态齐全 | `SweepButton` 有 hover / pressed(0.98) / disabled；`Skeleton` 骨架屏；`EmptyState` 带下一步动作 |
| 减少动态效果 | hover 与骨架动画都读 `accessibilityReduceMotion` |

刻意偏离：图标用 SF Symbols，未引入 Phosphor/Solar（原生应用不引 Web 图标字体）；滚动显隐用 SwiftUI 原生动画，未搬 `IntersectionObserver`。

## 二、新模块与验证方式

| 模块 | 实现要点 | 验证 |
|---|---|---|
| 大文件 | `LargeFileScanner` 只走普通文件，跳过 `.app`/`.photoslibrary` 等包内部，每 2000 个文件回传部分结果 | 实机扫描主目录；流式列表与骨架屏有截图（03） |
| 重复文件 | 大小分桶 → 首尾 64 KB SHA256 → 全文件 SHA256；默认保留最早修改的一份 | 回归端到端：1.2 MB 夹具两同内容 + 一份同尺寸不同内容，只归一组、保留较早者 |
| 矩形树图 | `TreemapLayout.squarify`，最多 24 块 + 其他 | 回归校验面积和 = 画布、比例误差 < 5%、越界检查（05） |
| 旭日图 | 按钻取路径成环，悬停中心显示名称/体积/占比，右侧图例同色阶 | 实机截图（06）；单环时的引导文案 |
| 内存 | `host_statistics64` + `vm.swapusage` + `kern.memorystatus_vm_pressure_level`，`ps` 取进程 | 回归校验总量 > 0、已用 ≤ 总量、压力等级在 1...4（07） |
| 隐私清理 | 按条目声明路径永久删除，`Remover(extraAllow:)` 只放行本条目路径 | 回归：清单内可删、清单外仍被拒；实机仅扫描测量（08） |
| 操作历史 | `history.jsonl` 为权威来源，旧日志仅保留早于首条结构化记录的部分 | 回归解析时间戳/类型；实机 647 条记录按天分组（09） |

## 三、界面截图

`design-0.5.0-screens/` 下 10 张，均为按窗口 ID 截图（避免遮挡）：

01 监控（默认页）、02 清理、03 大文件（扫描中）、04 重复文件（未开始态）、05 矩形树图、06 旭日图、07 内存、08 隐私清理、09 操作历史、10 启动项。

## 四、诚实说明：没有在真实数据上执行的动作

- **内存整理**：需要用户输入管理员密码，自动化验证未触发。代码路径为 `osascript -e 'do shell script "/usr/sbin/purge" with administrator privileges'`，失败会原样显示错误。是否真能回收取决于当前空闲缓存，文案已说明「不会让正在运行的程序变快」。
- **隐私清理**：没有对真实浏览器 Cookie/历史执行删除，避免把你这台机器的登录态清掉。只验证了扫描测量、白名单机制与测试夹具上的删除。
- **重复文件**：没有在主目录跑整盘校验（读全量内容耗时），改用 1.2 MB 夹具做端到端验证。
- **大文件**：默认 500 MB 门槛下扫描主目录 30 万+ 文件仍未结束（缓存与聊天附件很多），过程中有部分结果与取消按钮。门槛调低会更快出结果。

## 五、已知遗留

- 清理页仍有个别 11 px 的元信息（紧凑表格需要），未强制拉到 12 px 阶梯。
- 启动项列表的「显示」按钮在不同行有 1–2 px 的横向抖动，来自按钮宽度的自然差异，未做等宽处理。
- 磁盘分析一进页面就要对每个子目录做递归统计，主目录首次约 20 秒；切到树图/旭日图需等统计完成。
