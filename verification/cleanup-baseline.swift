import Foundation

@main
struct CleanupBaseline {
    static func main() {
        let home = NSHomeDirectory()
        let checks: [(String, Bool)] = [
            ("known cache is admitted by the old cleanup gate", PathSafety.canDelete(home + "/Library/Caches/com.sweep.owned-fixture/data")),
            ("cache preview begins unselected", !CacheItem(id: "fixture", name: "fixture", path: home + "/Library/Caches/fixture", category: "fixture", size: 100).selected),
            ("Xcode Archives is excluded from recommended cleanup", !CleanCatalog.categories.contains { $0.safe && $0.paths.contains { $0.contains("/Archives") } }),
            ("Trash is excluded from recommended cache cleanup", !CleanCatalog.categories.contains { $0.id == "trash" && $0.safe }),
        ]
        for (name, ok) in checks { print("\(ok ? "PASS" : "FAIL") \(name)") }
        print("\(checks.filter { $0.1 }.count)/\(checks.count) expected cleanup behaviors passed before changes")
        if checks.contains(where: { !$0.1 }) { exit(1) }
    }
}
