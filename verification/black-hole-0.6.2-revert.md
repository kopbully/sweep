# 桌面黑洞 0.6.2：视觉回退

日期：2026-10-26。基线：`v0.6.1`（`c94eb99`）。安装路径：/Applications/Sweep.app（0.6.2）。

## 起因

0.6.1 为了让黑洞"不像别人的项目"，把着色器改成冷白→天青→深靛的刻线环、去掉星空、圆外全透明。实机观感被判定为"太丑"——冷色环偏灰、盘面缺少层次、星点消失后整体变空。要求退回上一个效果。

## 处置

保留交互层（尺寸 168pt、四角穿透、按真实窗口换算几何），只回退视觉层：

| 文件 | 处置 |
|---|---|
| `BlackHoleWeb/src/shaders/blackhole.ts` | `git checkout v0.6.0 --` 整份还原（暖色吸积盘、光子环、淡星点、圆形软边） |
| `BlackHoleWeb/src/renderer.ts` | 去掉 `HOLE_ZOOM` 相关缩放，粒子配色回到暖色 `dim / (0.35+0.6t) / (0.15+0.75t²)`；尺寸仍取 `WIDGET_SIZE` |
| `BlackHoleWeb/src/lib/geometry.ts` | 删除 `HOLE_ZOOM` 常量，`WIDGET_SIZE` 保持 168 |
| `BlackHoleWeb/public/black-hole.css` | 保留 168pt 下的紧凑尺寸（34px 图标、72px 名称、9–10px 字号），配色改回暖调 `#ffe4bf / #17131c / #ffd6a024` |
| `BlackHoleWeb/test/widget.test.ts` | 删除 zoom 一致性、`stars(` 缺席两条断言（着色器已回退），保留 168 尺寸与螺旋落点断言 |

原生侧 `Sources/Sweep/BlackHole.swift` 未改：仍然是 168pt 面板、62pt 投递半径、>74pt 穿透、12Hz 兜底轮询。

## 验收

- 前端 vitest **13/13**：`WIDGET_SIZE = 168`、`toNDC(84,84)=(0,0)`、螺旋终点 (84,84)、`pendingPosition` 让首个文件落在真实投放点。
- 原生回归 **132/132**（`zsh Scripts/test.sh`）：含投递圈小于面板、穿透半径不越界、中心与强度曲线。
- 实机窗口 `layer=3 name=Sweep 桌面黑洞 bounds=168×168 @ (1280,630)`；安装版 `CFBundleShortVersionString = 0.6.2`。
- 截图：`black-hole-0.6.2-revert/idle.png`、`hover.png`、`desktop-context.png` —— 暖橙吸积盘 + 光子环 + 星点，圆外透明（context 图里能看到底下的窗口与文稿文字透出）。

## 遗留

- 视觉与上游 `charleypeng/kakabin` 一致，0.6.1 的"差异化"目标未达成。若要再区分，应做小改动（盘面倾角、亮度曲线、环厚度）而不是换整套配色。
- 0.6.1 的冷色资源已随版本回退丢弃，需要时可 `git show v0.6.1:BlackHoleWeb/src/shaders/blackhole.ts` 取回。
