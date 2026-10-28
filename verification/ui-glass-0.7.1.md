# 0.7.1 验收：磨砂玻璃与环境光

目标：把“一叠白纸”换成有层次的玻璃界面，但不牺牲文字对比度、不动任何业务逻辑。

## 一、改了什么

| 层 | 文件 | 改动 |
|---|---|---|
| 底 | `Visuals.swift`（新） | `AmbientBackdrop`：三团蓝/青/紫雾，14–22s 缓动漂移；`SheenOverlay` 周期高光；`PulseHalo` 呼吸光晕；`ToolbarRule` 游走高光；`SelectionPill` 渐变胶囊；`TickerText` 数字过渡 |
| 面 | `DesignSystem.swift` | `Panel` → `ultraThinMaterial` + 0.55 自适应实色 + 渐变描边，新增 `lift` 悬停抬升；`ProgressBar` 渐变 + 半高发光；`Skeleton` 扫光；`MetricTile` 带色晕与描边；`EmptyState` 加光晕；`SweepButton` 主按钮悬停发光 |
| 图 | `Theme.swift` | `Sparkline` 渐变面积 + 模糊外发光 + 末点光点；`GaugeRing` 角向渐变 + 发光 + 数值过渡 |
| 壳 | `SweepApp.swift` | 内容区套 `AmbientBackdrop`；模块切换 fade+上移 10pt（`Motion.base`）；侧栏选中态换 `SelectionPill`；Logo 加高光；工具栏底边换 `ToolbarRule` |
| 页 | `Clean/Optimize/Status/Uninstall` | 撤掉各自的 `.background(Theme.bg)`，底色统一交给外壳；清理页徽标与大数字改成渐变；卸载页统计行改成“环形占比 + 定宽指标块” |

## 二、踩到的问题

1. **统计行被挤成两行**。卸载页把原来的三块文字指标换成“环形 + 指标块”后，`HStack` 里的元素没有定宽，标签被压到 26pt 宽而折行、数值被裁掉。改成 `metric(title:value:)` 与 `selectionGauge` 都 `.fixedSize()`，并把两栏指标并到一组，行高恢复正常。
2. **进度条发光糊住文字**。`ProgressBar` 的 shadow 半径取 `height * 0.9`，5pt 的条会溢出 4.5pt，正好压在下方“已用 88% · 共 245.11 GB”上。改成 `max(1.5, height * 0.5)`、透明度 0.28，只留一层薄边。
3. **磨砂面板一开始太透**。只上 `ultraThinMaterial` 时深色下文字发灰，补一层 `Theme.surface.opacity(0.55)`（自适应白/深灰）后才能同时兼顾通透与对比度。

## 三、检查项

- `Scripts/test.sh`：149/149 通过（视觉改动不触碰任何引擎逻辑）。
- 三个页面的实际渲染：`ui-glass-clean.png`、`ui-glass-status.png`、`ui-glass-uninstall.png`（窗口原尺寸截取，宽 1400）。
- 动效全部包在 `accessibilityReduceMotion` 里；关掉“减弱动态”后环境光、光晕、骨架扫光、工具栏高光均静止。
- 未改动的部分：所有删除/卸载路径、`PathSafety` 白名单、历史记录格式。
