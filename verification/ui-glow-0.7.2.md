# 0.7.2 图表发光 · 分段滑动 · 行入场

构建：`zsh Scripts/make_app.sh` → `ditto Sweep.app /Applications/Sweep.app`，签名 `Sweep Local Signing`。
回归：`zsh Scripts/test.sh` → 149/149。

## 改了什么

| 位置 | 改动 | 文件 |
| --- | --- | --- |
| 矩形树图 | 色相环配色（青→蓝→紫）、块面高光、悬停放大 1.04 + 同色发光 + 其余块退到 0.5、换层错开淡入 | `Treemap.swift` |
| 旭日图 | 悬停瓣外扩 0.022 + 发光、其余瓣退到 0.45、中心数值 `TickerText` | `Treemap.swift` |
| 分段控件 | `matchedGeometryEffect` 滑动胶囊 + 渐变填充 + 内描边 | `DesignSystem.swift` |
| 列表行 | `StaggerIn` 错开淡入 + 上移 6pt（≤24 行 × 18ms，只播一次） | `Visuals.swift` |
| 主按钮 | `PulseGlow` 忙碌呼吸 1.25s | `Visuals.swift` |
| 磁盘分析列表 | 手写 Capsule 占比条 → `ProgressBar` | `Analyze.swift` |

`SegmentedBar` 的滑动胶囊依赖 `matchedGeometryEffect`：`if active { ... .matchedGeometryEffect(id: "segmented-pill", in: pill) }`，
配合 `withAnimation(reduceMotion ? nil : Motion.quick)`。切换时 SwiftUI 会在两个几何体之间插值，视觉上就是胶囊滑过去。

## 验证方式

没有辅助功能权限（System Events 报 -10004），点不了界面，所以悬停态无法真机验证，只能验证静态渲染：

1. `screencapture -l <windowID>` 直接抓窗口（窗口被 macOS 恢复到别的桌面时，全屏截图抓不到；
   用 CGWindowList 拿到 1240×800 那个 windowID 再抓）。
2. 逐页核对渲染结果，见 `verification/ui-*-0.7.2.png`。

## 踩坑

- **cfprefsd 缓存**：`defaults write com.sweep.macos analyzeLens` 之后 `defaults read` 已经返回新值，
  但 App 启动读到的仍是旧值（表现为「旭日图」键已写入、界面还停在矩形树图）。
  要在写入后 `killall cfprefsd` 并 sleep 2 才会被新进程读到。
  排查时曾怀疑是 `AppStorage` 反序列化问题，用临时改默认值 + `defaults delete` 排除。
- **窗口在别的桌面**：全屏 `screencapture -x` 抓不到主窗口；`CGWindowListCopyWindowInfo` 加
  `.optionOnScreenOnly` 也列不出来。删掉 `~/Library/Saved Application State/com.sweep.macos.savedState`
  并按 windowID 抓图才稳定。
- 家目录统计慢：磁盘分析页从启动到出图要 ~35s，截图脚本等 40s。
