# Sweep 桌面黑洞

用户确认：把 Kakabin 的黑洞拖放效果加入 Sweep，保留现有五模块。

1. 画面：复用 Kakabin 的 Three.js / GLSL 黑洞与轨道算法，保留 MIT 署名；生成完全本地的 IIFE 资源供 WKWebView 加载。鼠标在窗口外接近也改变吸积盘与光晕；拖入成功的真实文件图标旋转、拉伸、缩小入洞。验证：前端构建、输入/结果动画逻辑测试，实际 WebKit 画面。
2. 原生：增加可开关的透明桌面 NSPanel，AppKit 文件拖放与统一逻辑点坐标；系统 trashItem 真正移动文件到可恢复废纸篓。仅接收明确拖入的本地文件，保护关键目录，按项返回成功/失败，拒绝忙碌或未加载时的投递。验证：路径策略、真实临时夹具回收及恢复、失败不会播放成功反馈。
3. 交付：侧边栏增加黑洞开关，打包资源，保留旧版，更新开发副本与 /Applications/Sweep.app。验证：既有回归、签名、真实启动、鼠标靠近、Finder 文件拖入、吸入动画与废纸篓落盘。

前端桥接约定：

- `window.sweepHole.setPointer({x,y,strength,dragging})`：x/y 为 240x240 widget 内左上原点 CSS 逻辑点，可超出窗口；strength 为 0...1。
- `window.sweepHole.prepare(items, point)`：items 为 `{id,name,icon}` 数组，icon 为原生图标 PNG data URL；point 为 `{x,y}`，显示等待处理的文件。
- `window.sweepHole.complete(results, point)`：results 为 `{id,ok,error?}` 数组，仅 ok=true 的卡片最终吸入；失败回弹并显示原因。
- `window.sweepHole.setActive(bool)`：隐藏后停止绘制与动画，显示后恢复。
- JS 通过 `window.webkit.messageHandlers.sweepHole.postMessage` 发 `{type:'ready'}`、`{type:'animation-complete',ids:[...]}`、`{type:'render-error',message:'...'}`。不开放 JS 文件操作命令。

实现约束：不改旧清理/卸载策略；此功能仅使用系统废纸篓，不含永久删除或管理员回退。测试文件明确放在本工作区 verification 中，不触碰用户原有文件。

## 0.2.1 投递修复记录

- 失败检查：用户对已安装的 0.2.0 实测“靠近有反馈，但拖入后没有回收”。原日志只有 POINTER，无 DROP；因原版没有 drag 入口日志，这一现象本身不能区分命中、URL 读取或接收条件。
- H1：WKWebView 子视图截获拖放。WebKit 的 `WebViewImpl::hitTestForDragTypes` 独立命中自身 frame，并主动注册 URL 类型；父层普通 `hitTest` 不能保证拖放归属。改为普通 root 下的独立上层 leaf 接收区，保留下层 WebKit 画面。静态主源支持该假设，调整后真实 Finder 投递与动画已完整通过。
- H2：无条件 `.move` 未与来源操作协商，而且异步回收尚未完成就返回拖放成功。采用来源允许的 `.generic`，由目标独立执行回收；拒绝仅允许 copy/link/move/delete 的来源，避免来源按 move/delete 提前自行移除数据。
- H2 运行结论：本次 Finder 的 source mask=55，原本也允许 `.move`，因此“来源缺少 move”不是此次失败的解释；保留 `.generic` 调整以明确异步回收由目标处理。
- H3：文件 URL、ready 或圆形范围拒绝。新增 DRAG_ENTER（文件数、来源 mask、是否就绪、逻辑点坐标）与 DRAG_PREPARE（是否接受）日志，不写文件路径，方便运行时区分。
- 验证：新增四个操作 mask 检查；实际废纸篓集成 54/54 通过，release 构建及签名通过。2026-10-26 02:45:51 真实 Finder 投递日志记录回收 1 项成功、0 项失败，02:45:52 动画完成；用户确认吸入，原路径消失，测试文件在废纸篓中内容完整。完整证据见 `black-hole-finder-acceptance.json`。
- 主源：[WebKit 拖放命中与类型注册](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/mac/WebViewImpl.mm#L4468)、[Apple 拖放来源协议](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/DragandDrop/Concepts/dragsource.html)。
