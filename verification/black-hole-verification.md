# Sweep 0.2.1 桌面黑洞验收

更新日期：2026-10-26。

版本备份根目录：`/Users/focus/Documents/ChatGPT/逆向/Sweep/verification`。

## 交付

- `/Applications/Sweep.app` 与 `/Users/focus/Sweep/Sweep.app` 已更新至 0.2.1，源码同步到 `/Users/focus/Sweep`。
- 两处旧版应用及被覆盖源码保留于 `black-hole-installed-backup/`；更新前完整开发检查点保留于 `before-black-hole/`。
- 0.2.0 安装记录见 `black-hole-installed.json`；0.2.1 安装记录见 `black-hole-0.2.1-installed.json`，前版另保留于 `black-hole-0.2.0/`。三份新应用的可执行文件 SHA-256 一致，签名验证通过。

## 行为

- Sweep 侧栏“桌面黑洞”开关打开透明浮窗；鼠标从窗口外接近也会增强黑洞反馈。左键拖动浮窗，右键隐藏；关闭主窗口后浮窗继续运行。
- Finder 拖入本地文件后，由原生 AppKit 读取文件 URL，调用系统 `trashItem` 移到可恢复的废纸篓。
- 动画等待真实文件操作结果；成功文件的图标旋转、拉伸、缩小入洞，失败项目回弹并显示原因。大量文件以六个可见位置排队播放。
- 隐藏时停止绘制；画面进程异常后可通过隐藏、重新打开恢复。这个功能没有永久删除或管理员删除回退。
- 黑洞 GLSL 与轨道效果参考 [Kakabin](https://github.com/charleypeng/kakabin)，本地包含 Kakabin 与 Three.js 的 MIT 许可证。

## 已通过的验证

- Swift 原生回归：46 项，含此前监控、大小统计检查、拖入路径策略及四项来源操作协商检查。
- 实际系统废纸篓集成：54/54（包含上面的 46 项），覆盖自建文件、文件夹、符号链接、保护路径失败、目标保留及从废纸篓恢复内容。见 `black-hole-real-trash-0.2.1-tests.txt`。
- 动画逻辑：12/12，含真实结果前等待、混合成败、大于六项排队及暂停时钟；前端构建通过。见 `black-hole-web-tests.txt`。
- Swift release 构建及 ad-hoc 签名通过。见 `black-hole-release-0.2.1-build.txt`。
- WKWebView 原生黑洞画面已实际显示；开关、右键菜单和主窗口关闭后运行已在桌面工具中验证。已安装应用确实从 `/Applications/Sweep.app/Contents/MacOS/Sweep` 运行。
- 用户已对 0.2.0 确认真实鼠标靠近有反馈，但文件投递未回收。0.2.1 调整为上层独立原生接收区，避免依赖父视图的鼠标命中来接管 WebKit 拖放。投递修复证据与假设见 `black-hole-plan.md`。
- 0.2.1 已通过真实 Finder 投递：用户确认“文件被吸入，原位置文件消失”；2026-10-26 02:45:50–02:45:52 日志依次记录 DRAG_ENTER、DRAG_PREPARE accepted=true、DROP count=1、TRASH ok=1 failed=0、ABSORB_COMPLETE count=1。来源 mask=55，支持 `.generic`。
- 自建测试文件已从原位置消失；直接读取 `~/.Trash/Sweep 黑洞吸入测试.txt` 成功，80 字节内容与测试夹具完全一致，文件保留在废纸篓，可恢复。证据见 `black-hole-finder-acceptance.json`。
- 本地浏览器预览验证了靠近及结果动画。浏览器预览是模拟桥接输入，不等同于 Finder 文件回收。

## 验证边界

- 桌面自动化的 drag 输入没有完成投递；完整桌面验收由用户真实鼠标操作、原生事件日志和废纸篓文件内容共同确认。没有把浏览器模拟动画记作真实文件回收。
- 0.2.0 只读采样显示：主窗口关闭、浮窗显示时，Sweep 主进程在约 15 秒内增加 0.80 秒 CPU 时间，约占一个核心的 5.3%。这是前版短时本机读数，不包含 WebKit/GPU 进程；不用于宣称 0.2.1 整体性能改进。原始读数见 `black-hole-native-cpu.json`。
- 多显示器及混合缩放屏幕没有在实机验证。旧的清理、卸载和优化操作路径保持原状，本次验收仅使用自建文件。
