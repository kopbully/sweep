import Foundation
import AppKit

@main
@MainActor
struct Regression {
    static var failures = 0
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        if condition() {
            print("PASS \(name)")
        } else {
            failures += 1
            print("FAIL \(name)")
        }
    }

    static func main() async throws {
        check(BlackHoleController.trashDragOperation(for: .every) == .generic,
              "Trash owns file handling instead of requesting source deletion")
        check(BlackHoleController.trashDragOperation(for: [.copy, .generic]) == .generic,
              "Trash accepts a Finder generic operation without move")
        check(BlackHoleController.trashDragOperation(for: [.move, .delete]).isEmpty,
              "Trash rejects operations that ask the source to remove its data")
        check(BlackHoleController.trashDragOperation(for: [.copy, .link]).isEmpty,
              "Trash rejects a source that only permits copying or linking")
        check(BlackHoleMetrics.side <= 176, "desktop hole stays small enough to work around")
        check(BlackHoleMetrics.dropRadius * 2 < BlackHoleMetrics.side,
              "drop ring fits inside the panel instead of touching its edge")
        check(BlackHoleMetrics.passThroughRadius > BlackHoleMetrics.dropRadius,
              "the ring is clickable while the empty corners fall through")
        check(BlackHoleMetrics.passThroughRadius < BlackHoleMetrics.side / 2,
              "pass-through radius never claims the whole panel")
        check(BlackHoleMetrics.center == NSPoint(x: BlackHoleMetrics.side / 2, y: BlackHoleMetrics.side / 2),
              "pointer center matches the panel midpoint")
        check(BlackHoleMetrics.strength(distance: 0) == 1, "full response at the center")
        check(BlackHoleMetrics.strength(distance: BlackHoleMetrics.dropRadius) > 0,
              "the whole drop ring responds to the pointer")
        check(BlackHoleMetrics.strength(distance: BlackHoleMetrics.hoverOuter) == 0,
              "no response at the hover radius")
        check(BlackHoleMetrics.strength(distance: BlackHoleMetrics.hoverOuter + 40) == 0,
              "response is clamped outside the hover radius")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sweep-regression-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        // 测试产生的清理记录写到临时目录，不能污染用户的操作历史
        let logDir = root.appendingPathComponent("logs").path
        try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        RuntimePaths.logDirectoryOverride = logDir

        let lockPath = root.appendingPathComponent("instance.lock").path
        let primary = SingleInstanceLock(path: lockPath)
        let secondary = SingleInstanceLock(path: lockPath)
        check(primary.acquire(), "first instance takes the single-instance lock")
        check(!secondary.acquire(), "second instance is refused so it cannot add a duplicate floating window")
        check(primary.isHeld && !secondary.isHeld, "only the first instance reports holding the lock")
        primary.release()
        check(secondary.acquire(), "the lock is reusable once the first instance quits")
        secondary.release()

        // 启动项：plist 解析、launchctl 输出解析、停用目录位置
        let agent = root.appendingPathComponent("com.example.agent.plist")
        let agentPlist: [String: Any] = ["Label": "com.example.agent",
                                         "ProgramArguments": ["/bin/echo", "hi"],
                                         "RunAtLoad": true]
        try PropertyListSerialization.data(fromPropertyList: agentPlist, format: .xml, options: 0)
            .write(to: agent)
        let parsedAgent = LaunchPlist.parse(url: agent)
        check(parsedAgent?.label == "com.example.agent", "launch agent label comes from the plist")
        check(parsedAgent?.program == "/bin/echo", "launch agent program falls back to ProgramArguments[0]")
        check(parsedAgent?.runAtLoad == true, "launch agent RunAtLoad flag is preserved")
        let linkAgent = root.appendingPathComponent("linked-agent.plist")
        try fm.createSymbolicLink(at: linkAgent, withDestinationURL: agent)
        check(LaunchPlist.parse(url: linkAgent) == nil, "symlinked launch agents stay unmanaged")
        check(LaunchPlist.disabledStoreDirectory(home: "/Users/sample")
              == "/Users/sample/Library/Application Support/Sweep/disabled-launch-agents",
              "disabled launch agents are moved inside Sweep's own support directory")
        let listing = "PID\tStatus\tLabel\n42\t0\tcom.example.agent\n-\t0\tcom.example.other\n"
        check(LaunchPlist.loadedLabels(from: listing) == ["com.example.agent", "com.example.other"],
              "launchctl list output yields every loaded label")

        // 清理目录：新增类别必须落在永久删除白名单内，且不能顺带放宽用户资料
        check(Set(CleanCatalog.categories.map(\.id)).count == CleanCatalog.categories.count,
              "clean categories keep unique identifiers")
        check(CleanCatalog.categories.count >= 24, "clean catalog keeps the expanded category coverage")
        check(PathSafety.canDelete(NSHomeDirectory() + "/Library/Application Support/Code/Cache"),
              "VS Code cache directory is whitelisted for permanent deletion")
        check(PathSafety.canDelete(NSHomeDirectory() + "/Library/pnpm/store"),
              "pnpm content store is whitelisted for the explicit review item")
        check(!PathSafety.canDelete(NSHomeDirectory() + "/Library/Application Support/Code/User/settings.json"),
              "VS Code settings and workspace data stay protected")
        check(CleanCatalog.scanTargets().allSatisfy {
            PathSafety.canDelete($0.path) || !fm.fileExists(atPath: $0.path)
        }, "every scannable cleanup target is covered by the safety whitelist")

        // 删除闸门：根目录不能再把每条绝对路径都吃掉
        check(PathSafety.isProtected("/"), "filesystem root stays protected")
        check(PathSafety.isProtected(NSHomeDirectory() + "/Documents"), "Documents root stays protected")
        check(PathSafety.canDelete(NSHomeDirectory() + "/Library/Caches/pip"),
              "known cache roots stay permanently deletable")
        check(!PathSafety.canDelete(NSHomeDirectory() + "/Documents/secret.txt"),
              "permanent deletion still refuses paths outside the whitelist")
        check(!PathSafety.canDelete("/System/Library/Kernels/kernel"),
              "system files cannot reach the permanent deletion path")
        check(PathSafety.canTrash(NSHomeDirectory() + "/Desktop/note.txt"),
              "trash stays available for files the user picks under home")
        func file(_ name: String, bytes: Int) throws -> URL {
            let url = root.appendingPathComponent(name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: bytes).write(to: url)
            return url
        }
        let log = try file("sample.log", bytes: 4096)
        check(Sizer.size(log.path) == 4096, "ordinary file counts its own bytes")
        check(Sizer.sizeIfPresent(log.path) == 4096, "sizeIfPresent includes ordinary files")
        let apps = root.appendingPathComponent("apps")
        _ = try file("apps/Fake.app/Contents/MacOS/executable", bytes: 8192)
        _ = try file("apps/Fake.app/Contents/Helpers/Helper.app/Contents/MacOS/helper", bytes: 2048)
        check(Sizer.size(apps.path) == 10240, "nested application packages are included")
        let links = root.appendingPathComponent("links")
        let original = try file("links/original", bytes: 512)
        try fm.linkItem(at: original, to: links.appendingPathComponent("hardlink"))
        check(Sizer.size(links.path) == 512, "hard links count once within one tree")
        let symlink = links.appendingPathComponent("symlink")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: apps)
        check(Sizer.size(symlink.path) == 0, "root symlink is not followed")
        check(Sizer.size(links.path) == 512, "nested symlink is not followed")
        check(Sizer.size(root.appendingPathComponent("missing").path) == 0, "missing path returns zero")

        let before: [UInt32] = [100, 50, 800, 0]
        check(Sizing.cpuUsage(previous: before, current: [130, 60, 860, 0]) == 40,
              "CPU uses interval ticks rather than uptime totals")
        check(Sizing.cpuUsage(previous: before, current: [100, 50, 900, 0]) == 0,
              "idle CPU reports a valid zero")
        check(Sizing.cpuUsage(previous: nil, current: before) == nil, "first CPU sample waits for baseline")
        check(Sizing.cpuUsage(previous: before, current: before) == nil, "unchanged ticks do not invent CPU load")
        check(Sizing.cpuUsage(previous: before, current: before + before) == nil,
              "CPU topology change waits for new baseline")
        check(Sizing.cpuUsage(previous: [UInt32.max - 4, 0, 100, 0], current: [5, 0, 110, 0]) == 50,
              "CPU tick overflow is handled")
        if let ticks = Sizing.cpuTicks() {
            check(!ticks.isEmpty && ticks.count % 4 == 0, "live CPU counters have the kernel layout")
        } else {
            check(false, "live CPU counters are available")
        }

        func network(_ received: UInt32, _ sent: UInt32, at time: Double, changed: Int64 = 1) -> NetworkSample {
            NetworkSample(interfaces: ["en0": InterfaceCounters(received: received, sent: sent, changedAt: changed)], uptime: time)
        }
        let old = network(1000, 300, at: 10)
        let rates = Sizing.networkRates(previous: old, current: network(3000, 500, at: 12))
        check(rates.received == 1000 && rates.sent == 100, "network uses elapsed monotonic seconds")
        check(Sizing.networkRates(previous: nil, current: old).received == nil,
              "first network sample waits for baseline")
        let reconnected = Sizing.networkRates(previous: old, current: network(10, 10, at: 12, changed: 2))
        check(reconnected.received == 0 && reconnected.sent == 0, "reconnected interface does not create a spike")
        let wrapped = Sizing.networkRates(previous: network(UInt32.max - 100, 0, at: 10),
                                         current: network(99, 0, at: 12))
        check(wrapped.received == 100, "32-bit network counters wrap correctly")
        let appeared = NetworkSample(interfaces: ["en1": InterfaceCounters(received: 900_000, sent: 700_000, changedAt: 1)], uptime: 12)
        check(Sizing.networkRates(previous: old, current: appeared).received == 0,
              "new interface does not count historical traffic")

        let processes = ProcList.parse("""
          42  12.5  204800 /Applications/Example Tool.app/Contents/MacOS/Example Tool
          43  0.0   1      /usr/libexec/worker
          invalid row
          44  1.0   -1     /invalid
        """)
        check(processes.count == 2, "process parser skips malformed rows")
        check(processes.first?.memoryBytes == 209_715_200, "RSS KiB converts to bytes exactly")
        check(processes.first?.name == "Example Tool", "process names preserve spaces")
        check(ProcList.parse("42 1 100 /test", excludingPID: 42).isEmpty, "ps child is excluded by PID")

        let cache = root.appendingPathComponent("cache")
        _ = try file("cache/Browser/data", bytes: 100)
        _ = try file("cache/Other/data", bytes: 200)
        let categories = [
            CleanCategory(id: "appCaches", title: "general", subtitle: "", paths: [cache.path + "/*"], icon: "", safe: true),
            CleanCategory(id: "browser", title: "browser", subtitle: "", paths: [cache.path + "//Browser"], icon: "", safe: true),
        ]
        let targets = CleanCatalog.scanTargets(categories: categories)
        check(targets.count == 2 && Set(targets.map(\.path)).count == 2, "cache candidates deduplicate normalized paths")
        check(targets.first { $0.path.hasSuffix("/Browser") }?.category == "browser",
              "specialized cache category takes precedence")
        check(targets.reduce(Int64(0)) { $0 + Sizer.size($1.path) } == 300,
              "cache total counts each candidate once")

        let cleanupFixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/regression/cleanup-fixture-\(UUID().uuidString)")
        try fm.createDirectory(at: cleanupFixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: cleanupFixture) }
        let cleanupHome = cleanupFixture.appendingPathComponent("cleanup-home")
        try fm.createDirectory(at: cleanupHome.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
        func cleanupFile(_ relative: String, bytes: Int) throws -> URL {
            let url = cleanupHome.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: bytes).write(to: url)
            return url
        }
        let cleanupCategories = [
            CleanCategory(id: "known", title: "Known cache", subtitle: "", paths: ["~/Library/Caches/com.example.Known"],
                          icon: "", safe: true, appBundleIDs: ["com.example.known"]),
            CleanCategory(id: "appCaches", title: "Other app caches", subtitle: "", paths: ["~/Library/Caches/*"],
                          icon: "", safe: true, recommended: false, reviewReason: "Review each app cache"),
            // explicitOnly：即使可清理也不默认勾选（例如废纸篓里可能还有要找回的文件）
            CleanCategory(id: "explicit", title: "Explicit only", subtitle: "",
                          paths: ["~/Library/Caches/com.example.Explicit"], icon: "", safe: true,
                          recommended: false, explicitOnly: true),
        ]
        _ = try cleanupFile("Library/Caches/com.example.Known/data", bytes: 2048)
        _ = try cleanupFile("Library/Caches/com.example.Active/data", bytes: 512)
        _ = try cleanupFile("Library/Caches/com.example.Manual/data", bytes: 1024)
        _ = try cleanupFile("Library/Caches/com.example.Explicit/data", bytes: 256)
        _ = try cleanupFile("Library/Caches/com.example.RemoveMe/data", bytes: 1536)
        _ = try cleanupFile("Library/Caches/com.sweep.macos/data", bytes: 128)
        _ = try cleanupFile("Library/Caches/com.example.icloud/data", bytes: 64)
        _ = try cleanupFile("Library/Caches/com.apple.CloudDocs/metadata.db", bytes: 64)
        let externalHardLink = cleanupFixture.appendingPathComponent("cleanup-external-hardlink")
        try Data(repeating: 1, count: 256).write(to: externalHardLink)
        let hardLinkPath = cleanupHome.appendingPathComponent("Library/Caches/com.example.Shared/data")
        try fm.createDirectory(at: hardLinkPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.linkItem(at: externalHardLink, to: hardLinkPath)
        let outside = cleanupFixture.appendingPathComponent("cleanup-outside-target")
        try Data(repeating: 1, count: 512).write(to: outside)
        let symlinkPath = cleanupHome.appendingPathComponent("Library/Caches/com.example.Link")
        try fm.createSymbolicLink(at: symlinkPath, withDestinationURL: outside)

        let cleanupScan = CleanupScanner.scan(categories: cleanupCategories, home: cleanupHome.path,
                                              runningBundleIDs: ["com.example.active"])
        let knownCandidate = cleanupScan.items.first { $0.path.hasSuffix("/com.example.Known") }
        let manualCandidate = cleanupScan.items.first { $0.path.hasSuffix("/com.example.Manual") }
        let activeCandidate = cleanupScan.items.first { $0.path.hasSuffix("/com.example.Active") }
        let appCandidate = cleanupScan.items.first { $0.path.hasSuffix("/com.sweep.macos") }
        let cloudCandidate = cleanupScan.items.first { $0.path.hasSuffix("/com.example.icloud") }
        let cloudDocsCandidate = cleanupScan.items.first { $0.path.hasSuffix("/com.apple.CloudDocs") }
        let linkCandidate = cleanupScan.items.first { $0.path.hasSuffix("/com.example.Link") }
        let sharedCandidate = cleanupScan.items.first { $0.path.hasSuffix("/com.example.Shared") }
        check(knownCandidate?.recommended == true && knownCandidate?.selected == false,
              "cleanup scan recommends known cache without selecting it")
        check(manualCandidate?.canSelect == true && manualCandidate?.recommended == false,
              "generic app caches require manual selection")
        check(knownCandidate?.autoSelected == true && manualCandidate?.autoSelected == true,
              "every safe selectable cache is preselected, not just the conservative recommended set")
        check(cleanupScan.items.first { $0.path.hasSuffix("/com.example.Explicit") }?.autoSelected == false,
              "explicit-only categories are never preselected")
        check(activeCandidate?.canSelect == false && activeCandidate?.reason?.contains("正在运行") == true,
              "running app cache is locked")
        check(appCandidate?.canSelect == false && appCandidate?.reason?.contains("排除") == true,
              "Sweep cache is protected")
        check(cloudCandidate?.canSelect == false && cloudCandidate?.reason?.contains("排除") == true,
              "sync-state cache is protected")
        check(cloudDocsCandidate?.canSelect == false && cloudDocsCandidate?.reason?.contains("排除") == true,
              "CloudDocs state is protected")
        check(linkCandidate?.canSelect == false && fm.fileExists(atPath: outside.path),
              "cache symlink is not followed or selectable")
        check(sharedCandidate?.hasExternalHardLinks == true && sharedCandidate?.estimatedReclaimableSize == 0,
              "external hard link is excluded from reclaim estimate")

        let internalLinkRoot = cleanupHome.appendingPathComponent("Library/Caches/com.example.InternalLinks")
        try fm.createDirectory(at: internalLinkRoot, withIntermediateDirectories: true)
        let firstLink = internalLinkRoot.appendingPathComponent("first")
        let secondLink = internalLinkRoot.appendingPathComponent("second")
        try Data(repeating: 2, count: 256).write(to: firstLink)
        try fm.linkItem(at: firstLink, to: secondLink)
        var internalLinkCandidate = CleanupScanner.scan(categories: cleanupCategories, home: cleanupHome.path)
            .items.first { $0.path == internalLinkRoot.path }!
        internalLinkCandidate.selected = true
        let internalLinkReport = CleanupExecutor.clean(items: [internalLinkCandidate],
                                                       categories: cleanupCategories, home: cleanupHome.path)
        check(internalLinkReport.successfulCount == 1 && internalLinkReport.removedBytes == 256 &&
              !fm.fileExists(atPath: firstLink.path) && !fm.fileExists(atPath: secondLink.path),
              "in-candidate hard links clear once without a false changed result")

        var knownSelected = knownCandidate!
        knownSelected.selected = true
        let launchedAppReport = CleanupExecutor.clean(items: [knownSelected], categories: cleanupCategories,
                                                      home: cleanupHome.path,
                                                      runningBundleIDsProvider: { ["com.example.known"] })
        check(launchedAppReport.outcomes.first?.status == .blocked && fm.fileExists(atPath: knownSelected.path),
              "application launched after scan blocks cleanup")

        let xcodeHome = cleanupFixture.appendingPathComponent("xcode-home")
        let derivedData = xcodeHome.appendingPathComponent("Library/Developer/Xcode/DerivedData")
        try fm.createDirectory(at: derivedData.appendingPathComponent("Build"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64).write(to: derivedData.appendingPathComponent("Build/index"))
        let xcodeCategory = CleanCategory(id: "devXcode", title: "Xcode", subtitle: "",
                                          paths: ["~/Library/Developer/Xcode/DerivedData"], icon: "", safe: true,
                                          appBundleIDs: ["com.apple.dt.Xcode"])
        let activeBuildScan = CleanupScanner.scan(categories: [xcodeCategory], home: xcodeHome.path,
                                                  processNames: ["xcodebuild"])
        check(activeBuildScan.items.first?.canSelect == false && activeBuildScan.items.first?.reason?.contains("xcodebuild") == true,
              "active command-line build locks DerivedData")

        let containerPath = try cleanupFile("Library/Caches/com.example.Container/other/data", bytes: 32)
        let missingRuleCategories = [
            CleanCategory(id: "nested", title: "Nested", subtitle: "",
                          paths: ["~/Library/Caches/com.example.Container/absent"], icon: "", safe: true),
            cleanupCategories[1],
        ]
        let missingRuleScan = CleanupScanner.scan(categories: missingRuleCategories, home: cleanupHome.path)
        check(missingRuleScan.items.contains(where: { $0.path.hasSuffix("/com.example.Container") }) &&
              fm.fileExists(atPath: containerPath.path),
              "missing specialized rule does not hide an existing manual cache")

        var staleCandidate = manualCandidate!
        staleCandidate.selected = true
        _ = try cleanupFile("Library/Caches/com.example.Manual/data", bytes: 2049)
        let staleReport = CleanupExecutor.clean(items: [staleCandidate], categories: cleanupCategories, home: cleanupHome.path)
        check(staleReport.outcomes.first?.status == .changed && fm.fileExists(atPath: manualCandidate!.path),
              "changed cache is kept after the scan")

        var removable = cleanupScan.items.first { $0.path.hasSuffix("/com.example.RemoveMe") }!
        removable.selected = true
        let removalPath = removable.path
        let removalReport = CleanupExecutor.clean(items: [removable], categories: cleanupCategories, home: cleanupHome.path)
        check(removalReport.successfulCount == 1 && removalReport.removedBytes == 1536,
              "confirmed fixture cleanup reports actual logical bytes")
        check(!fm.fileExists(atPath: removalPath), "confirmed fixture cleanup removes only its reviewed target")

        let raceFile = try cleanupFile("Library/Caches/com.example.Race/data/old", bytes: 256)
        let raceCandidate = CleanupScanner.scan(categories: cleanupCategories, home: cleanupHome.path)
            .items.first { $0.path.hasSuffix("/com.example.Race") }
        var selectedRaceCandidate = raceCandidate!
        selectedRaceCandidate.selected = true
        let lateProtectedPath = raceFile.deletingLastPathComponent().appendingPathComponent("models")
        let raceReport = CleanupExecutor.clean(items: [selectedRaceCandidate], categories: cleanupCategories,
                                               home: cleanupHome.path, beforeRemoval: {
            try? fm.createDirectory(at: lateProtectedPath, withIntermediateDirectories: true)
            try? Data(repeating: 5, count: 16).write(to: lateProtectedPath.appendingPathComponent("new"))
        })
        check(raceReport.outcomes.first?.status == .changed && fm.fileExists(atPath: raceFile.path),
              "new protected content after preflight is preserved")

        let modifiedFile = try cleanupFile("Library/Caches/com.example.Modified/data", bytes: 256)
        var modifiedCandidate = CleanupScanner.scan(categories: cleanupCategories, home: cleanupHome.path)
            .items.first { $0.path.hasSuffix("/com.example.Modified") }!
        modifiedCandidate.selected = true
        let modifiedReport = CleanupExecutor.clean(items: [modifiedCandidate], categories: cleanupCategories,
                                                   home: cleanupHome.path, beforeRemoval: {
            try? Data(repeating: 9, count: 512).write(to: modifiedFile)
        })
        let modifiedSize = (try? fm.attributesOfItem(atPath: modifiedFile.path)[.size] as? NSNumber)?.intValue
        check(modifiedReport.outcomes.first?.status == .changed && modifiedSize == 512,
              "file changed after preflight is preserved")

        let movedFile = try cleanupFile("Library/Caches/com.example.Moved/data/file", bytes: 256)
        var movedCandidate = CleanupScanner.scan(categories: cleanupCategories, home: cleanupHome.path)
            .items.first { $0.path.hasSuffix("/com.example.Moved") }!
        movedCandidate.selected = true
        let movedCache = cleanupFixture.appendingPathComponent("moved-cache")
        let movedReport = CleanupExecutor.clean(items: [movedCandidate], categories: cleanupCategories,
                                                home: cleanupHome.path, afterDirectoryOpen: { path in
            if path == movedCandidate.path { try? fm.moveItem(atPath: path, toPath: movedCache.path) }
        })
        check(movedReport.outcomes.first?.status == .changed && fm.fileExists(atPath: movedFile.path.replacingOccurrences(of: movedCandidate.path, with: movedCache.path)),
              "directory moved outside the cache root is left intact")

        let cancelledToken = CleanupCancellationToken()
        cancelledToken.cancel()
        let cancelledScan = CleanupScanner.scan(categories: cleanupCategories, home: cleanupHome.path, cancellation: cancelledToken)
        check(cancelledScan.cancelled && cancelledScan.items.isEmpty, "cancelled scan stops before publishing candidates")

        let engineHome = cleanupFixture.appendingPathComponent("engine-home")
        let engineTarget = engineHome.appendingPathComponent("Library/Caches/com.example.Engine")
        try fm.createDirectory(at: engineTarget, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 128).write(to: engineTarget.appendingPathComponent("data"))
        let engineCategory = CleanCategory(id: "engine", title: "Engine", subtitle: "",
                                           paths: ["~/Library/Caches/com.example.Engine"], icon: "", safe: true)
        let engine = CleanEngine(categories: [engineCategory], home: engineHome.path)
        engine.scan()
        for _ in 0..<200 where engine.busy { try? await Task.sleep(nanoseconds: 10_000_000) }
        // 首次扫描后自动勾选全部可清理项：只勾「推荐项」时，120 个候选里只勾中 17MB，
        // 用户点清理几乎看不出变化，会以为功能坏了。
        check(engine.items.count == 1 && engine.selectedItems.count == 1,
              "cleanup UI preselects every eligible candidate after the first scan")
        engine.deselectAll()
        check(engine.selectedItems.isEmpty, "deselect all clears the preselection")
        check(engine.prepareForCleaning().count == 1 && engine.selectedItems.count == 1,
              "one-click clean re-selects every eligible candidate when nothing is chosen")
        check(engine.selectableCount == engine.items.count && engine.selectableTotal > 0,
              "selectable totals describe every eligible candidate")
        engine.selectLargest(1)
        check(engine.selectedItems.count == 1, "select largest keeps the picked count bounded")
        engine.selectRecommended()
        check(engine.selectedItems.count == 1, "select recommended includes only reviewed eligible items")
        engine.cleanConfirmed(engine.selectedItems)
        for _ in 0..<300 where engine.busy { try? await Task.sleep(nanoseconds: 10_000_000) }
        check(engine.lastReport?.successfulCount == 1 && engine.hasScanned,
              "cleanup result remains available after the automatic rescan")
        check(engine.items.isEmpty && !fm.fileExists(atPath: engineTarget.path),
              "automatic rescan removes only the completed candidate")

        let analyze = AnalyzeEngine()
        let originalPath = analyze.path
        analyze.scanning = true
        analyze.go(to: root.path)
        analyze.goUp()
        check(analyze.path == originalPath, "scan navigation cannot relabel in-flight results")

        let sampler = SystemSampler()
        sampler.start()
        sampler.start()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        check(sampler.cpuHistory.count == 1, "repeated start has one sampling loop")
        check(sampler.snapshot.cpuUsage != nil, "live CPU gets a valid interval sample")
        sampler.stop()
        let stoppedAt = sampler.snapshot.timestamp
        try await Task.sleep(nanoseconds: 1_100_000_000)
        check(sampler.snapshot.timestamp == stoppedAt, "stop cancels future publication")
        sampler.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        check(sampler.snapshot.cpuUsage == nil, "restart establishes a fresh CPU baseline")
        check(sampler.cpuHistory.isEmpty, "restart clears history across a sampling gap")
        sampler.stop()

        let dropRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("verification/black-hole-fixtures/\(UUID().uuidString)")
        try fm.createDirectory(at: dropRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dropRoot) }
        let dropFile = dropRoot.appendingPathComponent("  Sweep 黑洞测试.txt  ")
        try Data("Sweep-owned fixture".utf8).write(to: dropFile)
        check(BlackHoleTrash.validationError(for: dropFile) == nil, "explicit workspace file can be trashed")
        check(BlackHoleTrash.validationError(for: URL(fileURLWithPath: NSHomeDirectory())) != nil,
              "home root is protected")
        check(BlackHoleTrash.validationError(for: URL(fileURLWithPath: NSHomeDirectory() + "/Documents")) != nil,
              "Documents root is protected")
        check(BlackHoleTrash.validationError(for: URL(fileURLWithPath: "/System")) != nil,
              "system root is protected")
        check(BlackHoleTrash.validationError(for: URL(string: "https://example.com/file")!) != nil,
              "remote URL is rejected")
        let canonicalDropFile = BlackHoleTrash.canonicalURL(dropFile)
        check(canonicalDropFile.lastPathComponent == dropFile.lastPathComponent,
              "leading and trailing spaces in file names are preserved")
        check(BlackHoleTrash.candidates([dropFile, dropFile]).count == 1, "duplicate dropped paths are processed once")
        check(BlackHoleTrash.candidates([dropRoot, dropFile]).count == 1,
              "child of a dropped folder is not processed a second time")
        let privateAlias = dropRoot.appendingPathComponent("private-alias")
        try fm.createSymbolicLink(at: privateAlias,
                                 withDestinationURL: URL(fileURLWithPath: NSHomeDirectory() + "/.ssh"))
        check(BlackHoleTrash.validationError(for: privateAlias.appendingPathComponent("unread-fixture")) != nil,
              "a parent alias cannot enter protected credentials")
        let anchor = dropRoot.appendingPathComponent("anchor.txt")
        try Data("Keep the target".utf8).write(to: anchor)
        let dropLink = dropRoot.appendingPathComponent("link-to-anchor")
        try fm.createSymbolicLink(at: dropLink, withDestinationURL: anchor)
        check(BlackHoleTrash.canonicalURL(dropLink).path == dropLink.path,
              "the final symlink is moved rather than its target")

        if ProcessInfo.processInfo.environment["SWEEP_TEST_REAL_TRASH"] == "1" {
            let folder = dropRoot.appendingPathComponent("folder")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("Nested fixture".utf8).write(to: folder.appendingPathComponent("inside.txt"))
            let outcomes = BlackHoleTrash.moveToTrash([dropFile, folder, dropLink,
                                                       URL(fileURLWithPath: NSHomeDirectory())])
            let trashErrors = outcomes.filter { !$0.ok }.map { outcome in
                "\(outcome.id): \(outcome.error ?? "未知错误")"
            }
            if !trashErrors.isEmpty { print("Trash integration errors: " + trashErrors.joined(separator: " | ")) }
            check(outcomes.filter(\.ok).count == 3, "real files, folder and symlink reach system Trash")
            check(outcomes.filter { !$0.ok }.count == 1, "protected drop reports a real failure")
            check(!fm.fileExists(atPath: dropFile.path) && !fm.fileExists(atPath: folder.path),
                  "successful sources are removed from their original locations")
            check((try? Data(contentsOf: anchor)) == Data("Keep the target".utf8),
                  "trashing a symlink leaves its target unchanged")
            for outcome in outcomes where outcome.ok {
                check(outcome.destination.map { fm.fileExists(atPath: $0.path) } == true,
                      "successful item has a recoverable Trash destination")
                if let destination = outcome.destination {
                    try fm.moveItem(at: destination, to: URL(fileURLWithPath: outcome.id))
                }
            }
            check((try? Data(contentsOf: dropFile)) == Data("Sweep-owned fixture".utf8),
                  "test file is recovered intact from Trash")
        } else {
            print("SKIP real Trash integration; use SWEEP_TEST_REAL_TRASH=1 for owned fixtures")
        }

        // MARK: 矩形树图
        let tiles = TreemapLayout.squarify(weights: [6, 3, 1], in: CGRect(x: 0, y: 0, width: 100, height: 100))
        check(tiles.count == 3, "treemap returns one rect per weight")
        check(tiles.allSatisfy { $0.width > 0 && $0.height > 0 }, "every treemap tile has a positive area")
        check(tiles.allSatisfy { $0.minX >= -0.01 && $0.minY >= -0.01 && $0.maxX <= 100.01 && $0.maxY <= 100.01 },
              "treemap tiles stay inside the canvas")
        let areaSum = tiles.reduce(0.0) { $0 + $1.width * $1.height }
        check(abs(areaSum - 10_000) < 1, "treemap tiles fill the canvas without overflow")
        check(abs((tiles[0].width * tiles[0].height) / (tiles[1].width * tiles[1].height) - 2) < 0.05,
              "treemap area ratio follows the weight ratio")
        check(TreemapLayout.squarify(weights: [], in: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty,
              "treemap handles an empty level")

        // MARK: 重复文件分组
        let olderStamp = Date(timeIntervalSince1970: 1_000)
        let recent = Date(timeIntervalSince1970: 9_000)
        let dupes = DuplicateGroup(id: "g", size: 1_000, files: [
            DuplicateFile(id: "/b/deep/path.bin", path: "/b/deep/path.bin", name: "path.bin", size: 1_000, modified: recent),
            DuplicateFile(id: "/a/x.bin", path: "/a/x.bin", name: "x.bin", size: 1_000, modified: olderStamp),
            DuplicateFile(id: "/c/y.bin", path: "/c/y.bin", name: "y.bin", size: 1_000, modified: recent),
        ])
        check(dupes.keeper?.path == "/a/x.bin", "duplicate keeper is the oldest copy")
        check(dupes.wasted == 2_000, "wasted space counts every copy except the keeper")

        // MARK: 操作历史解析
        check(HistoryFormat.kind(for: "CLEAN") == .clean, "history recognises clean lines")
        check(HistoryFormat.kind(for: "TRASH") == .trash, "history recognises trash lines")
        check(HistoryFormat.kind(for: "ADMIN-DELETE") == .delete, "history recognises admin delete lines")
        check(HistoryFormat.kind(for: "UNKNOWN") == .system, "unknown log lines fall back to system")
        if let parsed = HistoryFormat.parse("2026/10/26 13:52:52") {
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour], from: parsed)
            check(parts.year == 2026 && parts.month == 10 && parts.day == 26 && parts.hour == 13,
                  "history parses legacy log timestamps")
        } else {
            check(false, "history parses legacy log timestamps")
        }
        check(HistoryFormat.parse("not a date") == nil, "history leaves unparseable timestamps empty")
        check(OperationKind.allCases.count >= 10, "history exposes every operation category")

        // MARK: 隐私目录
        let privacy = PrivacyCatalog.items()
        check(Set(privacy.map(\.id)).count == privacy.count, "privacy item ids are unique")
        check(privacy.contains { $0.clearsClipboard && $0.paths.isEmpty },
              "clipboard item carries no file path")
        check(privacy.allSatisfy { $0.paths.allSatisfy { $0.hasPrefix("/") } },
              "privacy paths are absolute")
        check(privacy.allSatisfy { item in
            item.paths.allSatisfy { $0 != NSHomeDirectory() && $0 != NSHomeDirectory() + "/Library" }
        }, "privacy never targets the home root or the Library root")
        check(!PathSafety.canDelete(NSHomeDirectory() + "/Library/Safari/History.db"),
              "the global delete whitelist stays narrow without an explicit allowlist")
        check(!PathSafety.canDelete(NSHomeDirectory() + "/Documents/notes.txt"),
              "documents remain outside the permanent delete whitelist")

        // MARK: 大文件门槛
        check(LargeSizeThreshold.allCases.map(\.rawValue) == LargeSizeThreshold.allCases.map(\.rawValue).sorted(),
              "large file thresholds increase monotonically")
        check(LargeFileScanner.exclusions.contains(NSHomeDirectory() + "/Library/Caches"),
              "large file scan skips the cache tree owned by the clean module")

        // MARK: 内存采样
        let memory = MemoryProbe.read()
        check(memory.total > 0, "memory sampler reports installed RAM")
        check(memory.used > 0 && memory.used <= memory.total, "memory usage stays within physical RAM")
        check((1...4).contains(memory.pressureLevel), "memory pressure level is a known value")

        // MARK: 隐私白名单
        let privacyRoot = root.appendingPathComponent("privacy-fixture")
        try fm.createDirectory(at: privacyRoot, withIntermediateDirectories: true)
        let privacyFile = privacyRoot.appendingPathComponent("Cookies")
        try Data("fixture".utf8).write(to: privacyFile)
        check(!PathSafety.canDelete(privacyFile.path),
              "a privacy path outside the global whitelist is refused by default")
        let allowed = Remover.remove([privacyFile.path], mode: .permanent, extraAllow: [privacyRoot.path])
        check(allowed.removed == 1 && !fm.fileExists(atPath: privacyFile.path),
              "an explicitly declared privacy path can be deleted permanently")
        let outsideScope = root.appendingPathComponent("outside.txt")
        try Data("keep".utf8).write(to: outsideScope)
        let blocked = Remover.remove([outsideScope.path], mode: .permanent, extraAllow: [privacyRoot.path])
        check(blocked.removed == 0 && fm.fileExists(atPath: outsideScope.path),
              "the privacy allowlist does not widen the delete scope")

        // MARK: 重复文件端到端
        let dupRoot = root.appendingPathComponent("dup-fixture")
        try fm.createDirectory(at: dupRoot, withIntermediateDirectories: true)
        let payload = Data(repeating: 0x5A, count: 1_200_000)
        let dupOlder = dupRoot.appendingPathComponent("older.bin")
        let dupNewer = dupRoot.appendingPathComponent("newer.bin")
        let dupUnique = dupRoot.appendingPathComponent("unique.bin")
        try payload.write(to: dupOlder)
        try payload.write(to: dupNewer)
        try Data(repeating: 0x11, count: 1_200_000).write(to: dupUnique)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: dupOlder.path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000_000)], ofItemAtPath: dupNewer.path)
        let dupCancellation = CleanupCancellationToken()
        let found = DuplicateScanner.scan(minSize: 1_000_000, roots: [dupRoot.path],
                                          cancellation: dupCancellation,
                                          progress: { _, _, _ in })
        check(found.count == 1 && found[0].files.count == 2,
              "duplicate scan groups only byte-identical files of equal size")
        check(found.first?.keeper?.path == dupOlder.path,
              "duplicate scan keeps the oldest copy of each group")

        // MARK: 模块分组
        let grouped = ModuleGroup.all.flatMap(\.modules)
        check(grouped.count == Module.allCases.count && Set(grouped) == Set(Module.allCases),
              "every module appears in exactly one sidebar group")

        // 家目录之外的系统残留：只报告体积，可移除项必须逐类标注权限要求
        let leftovers = SystemLeftovers.locations(tempDirectory: "/var/folders/xx/abcdef/T/")
        check(leftovers.contains { $0.id == "macOSInstallData" && $0.needsAdmin },
              "system leftover list marks the macOS install staging as admin-only")
        check(leftovers.contains { $0.id == "diagnostics" && !$0.isRemovable },
              "system diagnostics are reported but never removed by the tool")
        check(leftovers.first { $0.id == "updaterClones" }?.path == "/var/folders/xx/abcdef/X",
              "updater clone probe resolves to the per-user X directory")
        check(leftovers.filter(\.isRemovable).allSatisfy { $0.kind == .adminStaging || $0.kind == .userTempClone },
              "only staging and updater clones are offered for removal")
        check(leftovers.allSatisfy { $0.path.hasPrefix("/") },
              "system leftover paths stay absolute so they can be shown verbatim")

        print("\(checks - failures)/\(checks) checks passed")
        if failures > 0 { exit(1) }
    }
}
