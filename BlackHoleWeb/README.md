# Sweep 本地黑洞资源

`npm test` 运行几何、逐文件结果、轨道与显隐时钟回归。`npm run build` 将经典 IIFE 脚本、HTML、CSS 和许可证生成到 `../Sources/Sweep/Resources/BlackHole/`。已锁定依赖版本；资源没有远程字体、纹理、模块或网络请求。首次复建可执行 `npm ci`。

原始黑洞 GLSL、粒子 GLSL 与轨道积分来自 [charleypeng/kakabin](https://github.com/charleypeng/kakabin)，保留 MIT 许可（`public/LICENSE-kakabin.txt`）。Three.js 使用 MIT 许可（`public/LICENSE-three.txt`）。Sweep 在此基础上增加外部指针靠近响应、原生图标与结果桥接；原始光线步进、透镜盘面、光子环、粒子引力轨道保持原算法。

在 240×240 透明 WKWebView 中以本地 `file://…/index.html` 加载。`window.sweepHole` 在页面初始化时公开，渲染成功后向 `window.webkit.messageHandlers.sweepHole` 发送 `{type:"ready"}`。

```ts
window.sweepHole.setPointer({ x: 270, y: 120, strength: 0.6, dragging: true });
window.sweepHole.prepare([{ id: "unique-native-id", name: "报告.pdf", icon: "data:image/png;base64,…" }], { x: 174, y: 94 });
// AppKit 系统废纸篓操作返回后，每项分别确认；prepare 本身不会播放成功。
window.sweepHole.complete([{ id: "unique-native-id", ok: true }], { x: 174, y: 94 });
// 或 { id: "unique-native-id", ok: false, error: "系统返回的具体原因" }
window.sweepHole.setActive(false);
```

坐标是 widget 左上原点的 CSS 逻辑点（可在窗口外）；`strength` 是 0…1。请给每次文件投放使用唯一 ID，先 `prepare` 再 `complete`。原生 PNG data URL 以外的图标 URL 会被忽略；文件名和错误只经 `textContent` 显示。最多同时展示 6 个文件图标；后续项目排队，每项轮到时才开始完整吸入或回弹动画。原生回收结果到达后立即计数，动画队列不延迟实际文件操作。失败回弹完成后按需释放展示位，原始错误列表继续保留。

只有 `ok:true` 项目进入约 1 秒的螺旋拉伸缩小，随后触发原始轨道碎粒。失败项目回弹并保留原始错误。成功吸入结束发送 `{type:"animation-complete",ids:[…]}`，其中仅包含 `ok:true` 项目的 ID；失败项目保留图标及错误，回弹不发送成功完成通知。异常发送 `{type:"render-error",message:"…"}`。宿主收到完成消息时只用于动画生命周期，不应再次执行文件操作。

空闲 20fps，靠近 30fps，吸入/粒子 45fps；`setActive(false)` 或网页隐藏都会取消 RAF，恢复时暂停的动画接续。普通浏览器本地预览会明确显示“未连接文件操作”；网页没有删除、清空废纸篓或任何文件读写能力。
