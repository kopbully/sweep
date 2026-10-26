import Foundation

@main
struct LiveCheck {
    static func main() async throws {
        let cpuBefore = Sizing.cpuTicks()
        let netBefore = Sizing.netBytes()
        try await Task.sleep(nanoseconds: 1_100_000_000)
        let cpu = Sizing.cpuUsage(previous: cpuBefore, current: Sizing.cpuTicks())
        let rates = Sizing.networkRates(previous: netBefore, current: Sizing.netBytes())
        let memory = Sizing.memory()
        let disk = Sizing.disk()
        let processes = try ProcList.fetch()
        let examples = processes.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(5).map {
            ["pid": $0.id, "name": $0.name, "rss_bytes": $0.memoryBytes, "cpu": $0.cpu] as [String: Any]
        }
        let result: [String: Any] = [
            "cpu_interval_percent": cpu as Any? ?? NSNull(),
            "download_bytes_per_second": rates.received as Any? ?? NSNull(),
            "upload_bytes_per_second": rates.sent as Any? ?? NSNull(),
            "memory_used_bytes": memory.used,
            "memory_total_bytes": memory.total,
            "disk_total_bytes": disk.total,
            "disk_free_bytes": disk.free,
            "process_count": processes.count,
            "largest_rss_processes": examples,
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
