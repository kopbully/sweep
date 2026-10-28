# 0.7.0 验收：应用图标 · 卸载模块

## 一、卸载模块为什么看不见

### 现象
侧栏只有「空间 / 系统 / 记录」三组的十个入口，界面上找不到卸载。

### 根因
`Sources/Sweep/Uninstall.swift` 里的 `UninstallEngine` 与 `UninstallView` 是完整的，但 `Module` 枚举里没有 `uninstall`
这个 case，`ModuleGroup.all` 也没收它；`ShellView` 里 `@StateObject private var uninstallEngine = UninstallEngine()`
创建之后从来没有被任何视图读过。等于写好了但没接线。

### 修复
| 位置 | 改动 |
|---|---|
| `Module.swift` | 新增 `case uninstall`（标题「卸载」、图标 `xmark.bin`），并新建分组「应用」 |
| `SweepApp.swift` | `detail` 里补 `case .uninstall: UninstallView(engine: uninstallEngine)` |
| `History.swift` | `OperationKind` 新增 `uninstall`，卸载动作进「操作历史」 |

`Scripts/test.sh` 里原有的断言「every module appears in exactly one sidebar group」会自动覆盖新入口的分组唯一性。

## 二、残留匹配：旧规则会误伤

旧实现 `kid.contains(baseName)` 是**子串匹配**：应用名 `Code` 会命中 `~/Library/Caches/Code Cache`，
应用名 `Sweep` 会命中 `~/Library/Logs/sweep_report.log`，而这些东西在卸载时会被直接扔进废纸篓。

现在 `UninstallEngine.matches` 的规则：

| 维度 | 判定 |
|---|---|
| Bundle ID | 完全相等，或以 `com.foo.bar.` / `com.foo.bar-` 续写（覆盖 `com.foo.bar.plist`、`com.foo.bar.savedState`） |
| 应用名 | 完全相等，或以 `.`、空格、`-`、`_` 续写；长度不足 3 个字符不参与匹配 |
| 0 字节项 | 计入残留（空目录与空 plist 留着更碍事），UI 显示 `—` |

新增 6 条断言：

```
PASS uninstall matches the exact bundle id
PASS uninstall matches files named after the bundle id
PASS uninstall matches app-name folders that continue after a separator
PASS uninstall refuses a folder that merely shares the name prefix
PASS uninstall refuses a bundle id that merely shares a prefix
PASS uninstall ignores names shorter than three characters
```

## 三、端到端验证（没有辅助功能权限，走受控诊断口）

本机 `System Events` 报 `-10004 权限违例`，点不了界面按钮，所以给 App 加了一个**只读 / 受控**的诊断开关，
和既有的 `SWEEP_START_MODULE`、`SWEEP_ALLOW_MULTI_INSTANCE` 同类：

```
SWEEP_UNINSTALL_PROBE=<app 路径>              # 只打印匹配到的残留，不删除
SWEEP_UNINSTALL_PROBE_APPLY=1                 # 额外真的卸载，且仅限 ~/Applications 下的应用
```

造一个假应用 `~/Applications/SweepTestApp.app`（bundle `com.sweep.testapp`）与 5 份残留，外加一份诱饵
`~/Library/Caches/SweepTestAppShadow`：

```
PROBE app=SweepTestApp bundle=com.sweep.testapp version=1.0 size=166847 needsAuth=false
PROBE leftovers=5 bytes=5242880
PROBE   3145728  ~/Library/Caches/com.sweep.testapp
PROBE   2097152  ~/Library/Application Support/SweepTestApp
PROBE   0        ~/Library/HTTPStorages/com.sweep.testapp
PROBE   0        ~/Library/Saved Application State/com.sweep.testapp.savedState
PROBE   0        ~/Library/Preferences/com.sweep.testapp.plist
PROBE applied trashed=1 admin=0 failed=0 leftovers=5 bytes=5409727
PROBE message=1 个应用已进废纸篓，可恢复；带走残留 5 项 · 5.2 MB。
```

核对结果：应用本体与 5 份残留都不在原位，诱饵 `SweepTestAppShadow` 保留；`operations.log` 里有 6 条
`TRASH` 记录；`history.jsonl` 追加了 `{"kind":"uninstall","count":1,...}`。

## 四、图标

几何集中在 `Sources/Sweep/IconArt.swift`：`Scripts/make_icon.swift` 渲染 10 档尺寸 → `iconutil` 出
`AppIcon.icns`；`SweepLogo`（SwiftUI Canvas）用同一份 `CGPath` 画侧栏标识。

踩过的两个坑：

1. **超椭圆底板被系统套灰板**。底板最初用超椭圆（`|x/a|^5+|y/b|^5=1`），`NSWorkspace.icon(forFile:)`
   解析出来的结果是「灰色应用底板 + 缩到 54% 的蓝底」；换成系统模板的圆角比例（半径 = 边长 × 0.2255，
   824 → 185）后恢复正常。判断依据：同样 824 内容区的系统图标（Notes）没有灰板。
2. **nonzero 填充把圆头挖空**。锥形笔画与圆头写成一条 path 后，两者绕向相反，重叠区域 winding 归零，
   渲染出来是一个带缺口和空洞的环。现在 `IconArt.mark` 返回子路径数组，逐段填充，并在透明度层里合成。

锥形笔画本身用「中心线采样 + 逐点法线偏移」构造，偏移量按曲率半径的 72% 截断，否则内侧会在弯头处翻折
（第一版就是一条自我交叉的细线，`.build/ribbon_debug.swift` 的描边图留了证据）。

## 五、回归

```
149/149 checks passed
```

版本号 0.6.6 → 0.7.0（`Scripts/make_app.sh`），`/Applications/Sweep.app` 已替换为新构建；
旧构建备份在 `/tmp/Sweep-prev-*.app`。
