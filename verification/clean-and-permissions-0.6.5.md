# 0.6.5 验收：清理为什么没反应、授权为什么反复要

## 一、点击清理却没有清理动作

### 现象
用户点「清理所选」后，磁盘可用空间几乎不变，日志里也没有 `CLEAN RESULT`。

### 根因（实测，不是猜测）
第一次扫描时只勾选 `recommended` 类别，而 `recommended` 是**类别级静态标记**：

| 类别 | recommended | 本机体积 |
|---|---|---|
| Chrome 缓存 | true | 1.16 GB |
| 其他应用缓存 appCaches | **false** | 2.6 GB（含 Doubao 989 MB、BundleMigration 960 MB、Codex 228 MB） |
| npm / pip / SwiftPM / uv | true | 17 MB（多数为空目录） |

本机实测：**120 个候选里只有 2 项被勾选，合计 17 MB**。17 MB 在 186 GB 的占用里看不出来，用户自然认为"没清理"。

诊断命令（用当前源码编一个只读扫描器）：

```
候选 120 项，推荐可选 2 项，合计 17 MB
  17 MB  ~/Library/Caches/pip
  0 B    ~/Library/Caches/org.swift.swiftpm
```

### 修复
1. `CacheItem.autoSelected`：`canSelect && category.safe && !category.explicitOnly`。
2. 首次扫描完成后按 `autoSelected` 勾选（保留用户后续手动改动，重新扫描沿用上次选择）。
3. 主按钮标题改为「清理 N 项 · X GB」；空选时点它自动全选可选项目。
4. 选择区按钮：「选择推荐项」→「全选可清理」。

修复后同一台机器：

```
候选 119 项 / 默认勾选 91 项 / 合计 2.74 GB
  1.16 GB   ~/Library/Caches/Google/Chrome
  989.1 MB  ~/Library/Caches/Doubao
  228.3 MB  ~/Library/Caches/Codex
```

### 真实执行一次的结果
用与 UI 相同的 `CleanupExecutor` 路径跑推荐清理：

```
候选 119 项，推荐可选 80 项，合计 1.57 GB
成功 78 项，未完成 2 项，逻辑大小 1.34 GB
  保留 [changed] ~/Library/Caches/Codex :: 扫描后目录或文件内容发生变化，请重新扫描
  保留 [changed] ~/Library/Caches/com.apple.cache_delete :: 同上
清理前 df: 5.1GiB available / 98%
清理后 df: 6.3GiB available / 97%
```

两条 `changed` 是设计内的保护：扫描快照与删除时的目录指纹不一致就放弃删除，宁可少清也不误删。

### 安装版自证
0.6.5 安装后启动到清理页，日志直接记录勾选结果：

```
[2026/10/26 19:43:16] CLEAN SCAN items=48 issues=84 selected=10 selectedBytes=229514417
```

`selected=10 / 219 MB`——扫描一结束就有勾选，主按钮不再是空动作。（数字比 91 项小，是因为上一行把大头已经清掉了。）

## 二、反复弹授权

### 根因
0.6.4 之前的包是 **ad-hoc 签名**（`codesign --sign -`）。ad-hoc 没有稳定身份，每次重新打包 cdhash 都变，macOS 的 TCC 会把每一版都当成**另一个 App**：桌面 / 文稿 / 下载三个目录的授权、以及其他应用数据的授权，每次换包都要重新问一遍。

### 修复
`Scripts/setup_signing.sh` 生成固定本地证书并入登录钥匙串，`make_app.sh` 优先使用：

```
$ codesign -d -r- /Applications/Sweep.app
designated => identifier "com.sweep.macos" and certificate root = H"fb4a6ccc03602109a61db720bb75017d1a368113"
```

designated requirement 里只有 bundle id 与证书根哈希，**与 build 产物无关**。0.6.4 与 0.6.5 两次重打包后该字符串完全一致 → 授权一次即长期有效。证书缺失时脚本自动退回 ad-hoc，不会打不出包。

同时减少无谓的授权与受限噪音：

- 移除 `~/Library/Containers/com.apple.Safari/...` 缓存路径：它属于「其他应用数据」，没有完全磁盘访问权限必然失败，只会反复触发受限提示。
- `Info.plist` 补 `NSAppleEventsUsageDescription`，说明只有提权命令会用到系统授权。
- 优化页的提权任务点击后先弹自己的说明（「接下来会弹一次系统密码窗口」），再走系统对话框，避免莫名其妙的授权中断。

## 三、限制与未验证部分

- 本机显示器取证时处于休眠/锁屏，`screencapture` 全黑，**没有取得 0.6.5 的界面截图**。UI 改动由回归测试（`cleanup UI preselects every eligible candidate after the first scan`、`explicit-only categories are never preselected`）+ 安装版日志 `selected=10` 共同证明。
- Safari 自己的 `~/Library/Caches/com.apple.Safari` 仍会报 `permissionDenied`（需要完全磁盘访问权限），只是不再因此多勾一个更敏感的容器路径。
- 76 项「读取受限」多为各应用缓存目录里被 TCC 保护的子项，属预期噪音。
- 磁盘仍是 97%：缓存加起来只有 3 GB 量级，真正的大头是 `/Applications` 33 GB、`~/Desktop` 14 GB、`~/Documents` 12 GB、`~/Doubao` 9.6 GB。这部分要用「大文件」「磁盘分析」「重复文件」去处理，清理模块不该碰用户文档。

## 四、回归

```
zsh Scripts/test.sh  →  138/138 checks passed
```
