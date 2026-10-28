# 0.7.3 稀疏文件体积虚报（数据正确性）

## 现象

「磁盘分析」把 `~/Library` 报成 **262.94 GB**，树图里一个块几乎占满画布。
同一台机器 `df` 显示整盘 228 GiB、已用 172 GiB，`du -sh ~/Library` 只有 18 GB——
一个子目录不可能比整块盘还大。

## 定位

遍历 `~/Library` 收集每个文件的 `st_size`（逻辑）与 `st_blocks × 512`（实际），按差额排序：

```
逻辑合计: 245.79 GB
差 228.04 GB  逻辑 228.27 GB  实际 0.23 GB
  /Users/focus/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw
```

Docker Desktop 的虚拟磁盘是稀疏文件：向文件系统"声明"了 228 GB，实际只写了 0.23 GB 的块。
原 `Sizer.size()` 只累加 `st_size`，等于把声明长度当成占用。

`~/Library` 两种口径对账，确认 `st_blocks` 口径与 `du` 一致：

| 口径 | 值 |
| --- | --- |
| 逻辑（`st_size` 之和） | 245.82 GB |
| 实际（`st_blocks × 512`） | 17.96 GB |
| `du -sh` | 18 G |

## 修复

- `Common.swift`：`Sizer.measure()` 一次遍历同时返回 `logical` / `allocated`；
  `size()` 仍是逻辑值，新增 `allocated()` 与 `footprint()`。目录自身也计入 `st_blocks`。
- `Analyze.swift`：`DiskEntry` 增加 `allocated`，派生 `footprint`（= `allocated`，**不回退**）、
  `inflated`、`isInflated`（多出 512 MB 以上且至少翻倍）。扫描用 `Sizer.measure()`，
  排序改按 `footprint`，新增 `footprintScannedSize`，顶部标签「本层合计」→「本层占用」。
  列表行主数字改 `footprint`，虚高条目补一行「逻辑 xxx」，悬停提示写清两个口径。
- `Treemap.swift`：块面积权重、显示、`help` 全改 `footprint`；纯稀疏条目（占用 0）仍保留在图中，
  权重按最小 1 字节给一点面积，避免凭空消失。
- `Uninstall.swift` / `Privacy.swift` / `SystemLeftovers.swift`：`Sizer.size` → `Sizer.footprint`。
- 清理页（`Cleanup.swift`）本就自带 `logical` / `allocated` / `reclaimable` 三口径，未改动。

## 验证

1. 回归 `zsh Scripts/test.sh` → **158/158**（新增 9 条）
   - 稀疏文件保留逻辑长度、按块计量、目录口径、`footprint == allocated`、`size == logical`
   - 纯稀疏条目（`allocated == 0`）占用为 0 且不回退、被标为 inflated
   - 占用排序不被逻辑长度带偏、普通文件不标 inflated
   测试用 `ftruncate` 在临时目录造一个 512 MB 稀疏文件，APFS 上 `st_blocks == 0`，断言成立。
2. 真机对账（0.7.3 实拍，见 `verification/ui-analyze-list-0.7.3.png`）

| 项 | 修复前 | 修复后 | du/df 参照 |
| --- | --- | --- | --- |
| `~/Library` | 262.94 GB | **18.32 GB**（副行「逻辑 263.01 GB」） | 18 G |
| 本层（家目录） | 313.4 GB | **71.78 GB** | — |

## 备注

- 阈值取 512 MB 是为了让 228 GB 这种量级的虚高一定被提示，同时不打扰正常文件。
- 逻辑长度与占用不一致还可能来自 APFS 克隆与压缩，这类差额同样会被标成 inflated。
