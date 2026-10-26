# 桌面黑洞 0.6.1：缩小、可穿透、脱离上游视觉

> **0.6.2 更正**：本文件中「换成冷色刻线环」的视觉改造已被回退——用户反馈观感不佳。0.6.2 只保留尺寸 168pt、四角穿透、按窗口尺寸换算几何这三项，着色器/粒子/文字配色回到 `v0.6.0` 的暖色吸积盘。详见 `black-hole-0.6.2-revert/`。


日期：2026-10-26。基线：`v0.6.0`（`dbff6f4`）。安装路径：/Applications/Sweep.app（0.6.1）。

## 问题

1. 240×240 的面板几乎是一个不透明的黑方块，压在桌面右下角，挡住壁纸和底下的窗口，四角空白区域还会吃掉点击。
2. 画面来自上游 `charleypeng/kakabin` 的橙色吸积盘 + 星空底，视觉上就是别人的黑洞。

## 改动一：尺寸与命中区域

| 项 | 0.6.0 | 0.6.1 |
| --- | --- | --- |
| 面板边长 | 240pt | **168pt**（面积减到 49%） |
| 投递判定半径 | 112pt | **62pt** |
| 指针响应区间 | 30–210pt 线性 | **18–84pt**（`BlackHoleMetrics.strength`） |
| 角标内边距 | 24 / 88 | 22 / 84 |
| 四角空白 | 吃掉点击 | **穿透到桌面**（`panel.ignoresMouseEvents`） |

穿透实现：指针到中心的距离超过 `passThroughRadius`（62+12=74pt）时把窗口设为忽略鼠标事件，回到圈内立刻恢复；拖拽进行中强制不穿透，保证文件一定能落进来。窗口被穿透后收不到本地鼠标事件，因此加了一个 12Hz 的 `Timer` 作为兜底轮询（`installPointerMonitors`），隐藏时 invalidate。

所有几何量集中在 `BlackHoleMetrics`，前端从 `#hole` 的实际尺寸读取中心与半径，`BlackHoleWeb/src/lib/geometry.ts` 的 `WIDGET_SIZE` 与 `BlackHoleMetrics.side` 保持一致（测试断言 168）。

## 改动二：视觉重做

| 维度 | 上游 kakabin | Sweep 0.6.1 |
| --- | --- | --- |
| 配色 | 橙红吸积盘 + 暖白内圈 | 冷白内圈 → 天青 `#78AAFF` 系 → 深靛，贴合 App accent |
| 盘面质感 | 连续 fbm 气体 | 同心刻线（刻度盘语言）+ 低频不均匀 + 侧向不对称 |
| 光子环 | 单环 | 主环 + 外侧更淡副环（双层） |
| 背景 | 星空 + 星云，整块方形不透明 | **完全透明**，只在有光与视界处输出像素 |
| 尺寸行为 | 无 | 待机缩小（场缩放 1.20），靠近张开（0.88） |
| 光标凹陷 | 无 | 移除（168pt 下会把环压成中心小漩涡） |

alpha 不再由"圆形遮罩"决定，而是 `阴影视界 / 盘面覆盖率 / 亮部光晕` 三者取最大：圆外 alpha 为 0，壁纸原样透上来（见 `reference-same-area-widget-off.png` 与 `idle.png` 的对照）。掠射角处盘面减淡（`abs(v.y)` 权重），去掉之前沿盘沿的台阶状锯齿。

粒子系统的颜色与尺度同步改成冷色、并按同一场缩放系数换算屏幕坐标（`HOLE_ZOOM` 与着色器 `ZOOM_IDLE/ZOOM_ACTIVE` 由测试锁定一致）。

## 验证

- 前端：`npx vitest run`，**15/15 通过**（新增：窗口尺寸 168、着色器与 TS 缩放常量一致、着色器不含 `stars(` 且以 `vec4(col, alpha)` 输出、几何按 168 中心重算）。
- 原生：`zsh Scripts/test.sh`，**132/132 通过**（新增 9 项：面板 ≤176、投递圈小于面板、穿透半径大于投递半径且小于半边长、中心等于面板中点、指针强度在中心为 1、圈上 >0、响应半径外为 0）。
- 实机：`CGWindowListCopyWindowInfo` 确认黑洞窗口为 168×168、位于 `(1280, 630)`；`screencapture` 对照同一区域在关闭/开启黑洞时的像素，确认圆外为桌面本体。
- 交互日志（`~/Library/Logs/Sweep/operations.log`）：

```
BLACKHOLE PANEL frame=1280,158 side=168 visible=74+849
BLACKHOLE HIT_REGION passThrough=true distance=1114
BLACKHOLE HIT_REGION passThrough=false distance=0
BLACKHOLE POINTER_ENTER
BLACKHOLE HIT_REGION passThrough=true distance=97
BLACKHOLE POINTER_LEAVE
```

## 验证边界

- 截图取自本机浅色桌面；深色壁纸下的对比度没有单独做矩阵测试。
- 悬停放大的截图对比需要在光标静止时拍摄；本轮取证时鼠标正被真实操作，`idle.png` / `hover.png` 只能证明两种状态都正常渲染，放大比例以着色器常量与日志为准。
- 未重复拖入真实文件；本轮只观察已有的一次废纸篓操作记录（16:13:20）与新半径的命中日志。

## 回滚

`git checkout v0.6.0` 重新 `zsh Scripts/make_app.sh` 即可回到 240pt / 橙色版本。
