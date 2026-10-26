# 0.6.6 磁盘占满的根因与「家目录之外的大块占用」

## 现象

- 磁盘可用空间长期 2.2–2.6 GB，容量 99%
- 用户在 Sweep 里点清理，报告清掉 1.34 GB，但几小时内又满
- 反复出现系统授权弹窗

## 排查过程与结论

### 1. `df` 在本环境不可信，必须用 APFS 容器元数据

`df` 在写入/删除 800 MB 后数值不变（前后都读 2281172KB）。真实剩余空间以
`diskutil apfs list` 的 `Capacity Not Allocated` 为准。

### 2. 21 GB 的 `com.google.Chrome.code_sign_clone` 是假大头

`TMPDIR/../X` 下有 15 个 `code_sign_clone.*`，每个 `du` 报 1.4 GB，合计 21 GB。
删除后容器可用空间**一个字节没变**——它们是 `clonefile()` 产物，与
`/Applications/Google Chrome.app` 共享磁盘块，`du` 按逻辑大小重复计数。

教训：报告「可释放空间」时不能直接用 `du` 求和，APFS 克隆与硬链接都会虚高。

### 3. 但它是真实泄漏：每 ~6 分钟长 1.4 GB × 2

删除后 2 分钟就重新长到 2.8 GB。`~/Library/Application Support/Google/GoogleUpdater/updater.log`
显示更新器 `--wake` 周期运行，`Failed to lookup version for {44fc7fe2-…}` 之后反复走
`code_sign_clone` 的签名/替换流程。

处置（已验证）：

```sh
U=$(id -u)
for j in com.google.GoogleUpdater.wake com.google.keystone.agent com.google.keystone.xpcservice; do
  launchctl bootout "gui/$U/$j" 2>/dev/null
  launchctl disable "gui/$U/$j"
done
defaults write com.google.Keystone.Agent checkInterval -int 0
```

对照结果：停用前 2 分钟涨到 2.8 GB；停用后连续 7 分钟 0 B。

恢复自动更新（需要时）：

```sh
U=$(id -u)
for j in com.google.GoogleUpdater.wake com.google.keystone.agent com.google.keystone.xpcservice; do
  launchctl enable "gui/$U/$j"
done
defaults delete com.google.Keystone.Agent checkInterval
```

### 4. 真正能腾出空间的位置

| 位置 | 逻辑大小 | 性质 |
|---|---|---|
| `/System/Volumes/Data/macOS Install Data` | 13.16 GB | 2021-04-10 的 macOS 11 安装包残留，需管理员 |
| `/private/var/db/diagnostics` | 3.08 GB | 系统诊断日志，系统自管 |
| `/private/var/vm` | 2.15 GB | 交换与睡眠镜像，系统按压力伸缩 |
| `/Library/Updates` | 105 KB | 已安装更新的残留包 |
| `~/Library/Application Support/Doubao` | 5.2 GB | 第三方应用数据，非缓存部分不建议代删 |
| `~/Desktop/O*O` | 8.7 GB | 用户项目（node_modules / 构建产物） |
| `~/Documents/ChatGPT/逆向` | 9.2 GB | 用户项目 |

## 0.6.6 的改动

新增 `Sources/Sweep/SystemLeftovers.swift`：家目录之外的已知占用只**报告体积**，
不进入清理器的安全边界。清理页新增卡片「家目录之外的大块占用」：

- `adminStaging`：系统升级残留 → 「移除 · 需授权」，通过 `NSAppleScript`
  `do shell script … with administrator privileges` 弹一次系统授权
- `userTempClone`：更新器临时副本 → 直接删 `X/*.code_sign_clone`
- `infoOnly`：诊断日志、交换镜像 → 只显示「系统自管」，工具不碰

体积为 0 的项不显示，避免空行噪音。

## 验证

- 原生回归 **143/143**（新增 5 项：残留清单的权限标注、诊断日志不可删、
  更新器探测路径落到 `<TMPDIR 上一级>/X`、可移除项仅限两类、路径保持绝对）
- 实机截图 `verification/disk-full-0.6.6/sweep-clean-page.png`：
  系统升级残留 **13.16 GB**，按钮为「移除 · 需授权」
- 泄漏对照：停用更新器前 2 分钟 2.8 GB → 停用后 7 分钟 0 B

## 未做 / 边界

- 13.16 GB 的实际删除需要用户在弹窗里输入密码，本会话的沙箱上下文无法弹出授权框，
  按钮已就位但未替用户执行。
- 未清理 `~/Desktop`、`~/Documents`、`~/Doubao`：属于用户数据，需逐项确认。
- 未动 `Preboot`（10.9 GB）与 `VM`（14 GB）：系统卷，动它们风险高于收益。
