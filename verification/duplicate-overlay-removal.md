# 重复悬浮窗清除与单实例守卫（0.3.1）

## 现象

桌面上同时出现两个黑洞悬浮窗：较大的深色圆盘（Sweep）与较小的浅色方块（旧原型小组件，带「9.7 GB 可用 / 健康度 · 空间危急 / 请核实重要信息」）。

## 取证

`CGWindowListCopyWindowInfo` 枚举屏幕上的窗口（`kCGWindowListOptionOnScreenOnly`），两个悬浮层窗口分属不同进程：

| Owner | 尺寸 | 位置 | 层级 | PID | 结论 |
|-------|------|------|------|-----|------|
| Sweep | 240×240 | (1222, 641) | 3（浮动） | 32444 | Sweep 桌面黑洞面板，保留 |
| Python | 140×140 | (974, 727) | 3（浮动） | 16879 | `floating.py` 悬浮小组件，重复项 |

Python 进程的命令行是 `.../Python floating.py`，其宿主是 `/Applications/DiskPilot.app`（`CFBundleIdentifier = com.diskpilot.widget`，`LSUIElement = true`）。该 App 的 `Contents/MacOS/DiskPilot` 是一个 shell 启动器：

```
exec /Library/Frameworks/Python.framework/Versions/3.11/bin/python3 "/Users/focus/ZCodeProject/disk-monitor/floating.py"
```

开机自启来自 `~/Library/LaunchAgents/com.diskpilot.widget.plist`，并在 BTM 中登记为 legacy agent（`8.com.diskpilot.widget`），所以每次登录都会和 Sweep 一起画出第二个黑洞。

## 处理

1. 备份到 `~/ZCodeProject/disk-monitor/_removed-20261026/`：`DiskPilot.app.bak`、`com.diskpilot.widget.plist.bak`、`widget.json.bak`。
2. `launchctl bootout gui/$UID/com.diskpilot.widget` 卸载自启任务，删除 `~/Library/LaunchAgents/com.diskpilot.widget.plist`。
3. `kill 16879` 结束悬浮小组件进程（bootout 不会杀掉 `exec` 后的 Python 进程）。
4. `mv /Applications/DiskPilot.app ~/.Trash/DiskPilot.app`（Finder 自动化被系统权限拒绝，改用直接移入废纸篓，可从废纸篓还原）。Python 源码目录 `~/ZCodeProject/disk-monitor` 未改动。
5. Sweep 侧加固：新增 `Sources/Sweep/Instance.swift`，启动早期用 `flock` 抢占 `~/Library/Application Support/Sweep/instance.lock`；抢不到锁的第二个进程会把已有实例拉到前台并 `exit(0)`，不再创建第二个面板。`applicationWillTerminate` 只由持锁进程执行，避免副实例退出时把「桌面黑洞已启用」偏好写回 false。

## 验证

- 回归测试：**73/73 通过**（新增 4 项单实例锁检查：首个实例取得锁、第二个实例被拒、持锁状态唯一、释放后可复用）。见 `duplicate-overlay-tests.txt`。
- 构建：`Scripts/make_app.sh` 产出 0.3.1，`codesign -v --strict` 通过；`/Applications/Sweep.app` 已更新，0.3.0 回滚点保存在 `verification/before-instance-guard-0.3.0/Sweep.app`。
- 重复启动：`open -n /Applications/Sweep.app` 后进程列表仍只有 PID 68893，日志出现 `INSTANCE SECONDARY_LAUNCH pid=68968`，窗口清单里没有第二个 240×240 面板。
- 桌面状态：见 `duplicate-overlay-state.json`，只剩 `Sweep 240x240 / layer 3` 与主窗口；`floating.py` 进程为空；BTM 中已无 DiskPilot 登录项。
- 截图核对：桌面右下角只有一个黑洞，浅色小组件与「9.7 GB 可用」文案消失。

## 遗留

- `~/Sweep` 是 0.2.1 时期的旧副本（缺 `Cleanup.swift`），不是当前开发目录；后续改动需在 `~/Documents/ChatGPT/逆向/Sweep` 进行，建议归档旧副本以免再次混淆。
- 黑洞面板位置每次启动按 `visibleFrame` 重新计算（右上偏移 264/88），不记忆用户拖动后的位置；如需记忆可另开一项改动。
