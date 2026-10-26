# Sweep 监控只读排查

源码证据以 `verification/original-sources/Sweep/Status.swift` 与 `Theme.swift` 原始版本为准。本任务未改源码。

## Confirmed

- CPU stride 错误：Status.swift 108-109 用 `2 + CPU_STATE_MAX`，实际 SDK `processor_cpu_load_info_data_t` 只有 `CPU_STATE_MAX` 个 tick。本机 10 核，40 个 integer，错误预期60，原函数恒返回0。诊断中的正确1秒差分非0；修复还应做前后tick差分，原118-121算的是开机以来累计比例。
- 进程内存单位错误：Status.swift 226、240、246、249-251 先取 pmem 再算 `pmem * physicalGB`，结果是实际十进制MB的1/10，且pmem一位小数会丢失精度。man ps 明确RSS单位1024字节，直接 `rss * 1024` 再格式化。获准只读ps快照：Sweep PID35057 RSS115168KiB、pmem0.7、physical17179869184，原算法12.0MB，对应RSS117.9MB。
- 网络 ABI 错误：Status.swift 163 把 getifaddrs.ifa_data 当if_data64；本机man getifaddrs明确AF_LINK使用if_data，SDK大小96/128字节。原错误读取en0 rx0，tx约1.79e9；正确读取en0 rx约1.31e9/tx约1.19e9。最小修复使用if_data并按接口做UInt32差分，处理wrap/reset/新接口，物理接口口径避免lo/VPN重复。
- 磁盘可用空间错误：Status.swift 173-176 只用important usage key，本机返回0，普通available约20.68GB、总245.11GB。原显示100%满并错误扣健康分。使用普通available并校验边界；df可交叉对照。
- 主线程采样：Status.swift 34-36、45-46由主线程Timer同步sampleOnce，disk读取在主线程；5秒调用栈95个样本SystemSampler，其中91在Sizing.disk。即使本次临时采样约4ms，也不保证OS资源查询持续低延迟。
- 全量列表反复布局：Status.swift 334-376 的普通VStack+ForEach全量约634进程。5秒栈1883个主线程样本，769落事务提交，618+144 NSHostingView.layout，processCard多次命中。改列表惰性布局，隔离系统指标和进程刷新。
- 轮询重入条件存在：553-573 refreshProcs无guard且pollInFlight只写不查。旧asyncAfter在stop后若同state再次start看到true会复活，与新链并行；旧fetch也能覆盖新结果。使用受取消的串行Task或generation保护，停用后不发布结果。

## Rejected / Inconclusive

- Timer.start本身重复创建：正常连续start已由timer==nil guard防重（32-37），stop正常invalidate（40-43）。但无deinit兜底，最小化不等同onDisappear。
- 5个Published等于5次完整SwiftUI重绘：没有证据，SwiftUI可能合并更新；只能确认5次objectWillChange发送。
- Theme.swift自身为高CPU主因：未证实。GaugeRing动画0.4秒会增加持续渲染，但主要调用栈是布局/进程列表；Sparkline60点开销小。
- 内存统计与活动监视器完全一致：未证实。原公式total-free-inactive-purgeable是近似占用口径，不能仅靠占用百分比称为系统内存压力；`healthNote()` 533的浏览器推断也缺少来源。若改公式，需明确app/filecache/wired/compressed口径并相邻取样比较。
- 同视图state的消失/重现导致重复polling已在UI复现：未执行UI，属于确定代码重入路径，需验收界面生命周期。

## 建议验收

1. CPU：1秒间隔前后tick差分，0...100；起始可采样中；对照系统CPU且避免长期固定0。
2. RSS：同PID与`ps -p PID -o rss=`换算一致，bytesText采用一致十进制/二进制口径。
3. 网络：重复固定计数=>0，32位wrap=>小正数，新接口/移除/复位=>无负值或尖峰；观察en0有流量时UI更新。
4. 磁盘：free>0且接近df可用字节，本机不再误报100%。
5. 生命周期：快速在监控和其他模块间切换10轮，隐藏后不再采样/发布，返回后只有一条进程轮询；每次更新约2秒。
6. 性能：相同窗口、相同列表位置、稳定后比较15秒CPU平均/峰值与RSS；只读5秒sample检查布局栈降低；排序、置顶、滚动顺畅。

## 临时证据

- `/private/tmp/sweep-inspect-monitor.swift`：独立原版采样器+CPU/layout/网络/内存/磁盘/时耗诊断。
- `/private/tmp/sweep-inspect-monitor.result.txt`：本次诊断输出，可用 `swift -module-cache-path /private/tmp/sweep-inspect-monitor-cache /private/tmp/sweep-inspect-monitor.swift` 重跑。
- `/private/tmp/sweep-inspect-monitor.sample.txt`：原运行程序PID35057的5秒只读调用栈，关键原采样器3480-3483行、进程视图4044起、后台ps5922起。
