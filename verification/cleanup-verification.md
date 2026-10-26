# Sweep 0.3.0 cleanup verification

## Scope

MangoDisk was inspected read-only. Sweep implements a small, independent cache-cleanup flow; no MangoDisk source or rule catalog was copied. The cleanup screen covers named browser/developer caches plus manually reviewed app-cache entries. Candidates start unselected, running apps/build processes are blocked, and each confirmed target is revalidated before removal.

The scan excludes protected home/document/sync/Sweep paths, links, cloud placeholders and cross-volume objects. It can be cancelled and reports per-item outcomes. Logical bytes and allocated bytes are shown separately; space reclaimed remains an estimate because APFS snapshots/clones and hard links can affect the result.

## Verification

- Regression suite: **69/69 passed** in `cleanup-tests.txt`.
- Release build: `Scripts/make_app.sh` completed; `/Applications/Sweep.app` is version **0.3.0** and passes strict codesign verification.
- Black hole preservation: `BlackHole.swift`, `BlackHoleTrash.swift`, and all five files under `Sources/Sweep/Resources/BlackHole` match the 0.2.1 checkpoint hashes. The packaged resource tree also matches the source tree.
- Duplicate app bundles: six exact duplicate bundles were removed after matching full-tree hashes. The installed 0.3.0, one 0.2.1 rollback, and unique historical builds remain; see `duplicate-sweep-apps.json`. Removed bundle payload totals 10,997,762 bytes.
- No real cache directories were selected or cleaned during verification.

## Runtime boundary

The installed cleanup screen was inspected through accessibility state and screenshot. Its scan completed in 14.0 seconds with 75 permission-limited reads; zero items were selected. Chrome was locked while running, Safari cache locations were denied by macOS, and general app caches remained manual-review entries. The black-hole control reports `隐藏桌面黑洞`, indicating the feature is visible; its implementation and resources match the previously user-verified 0.2.1 build byte-for-byte. After the duplicate-overlay report, the old Sweep process (PID 32052) was quit through the app menu and `/Applications/Sweep.app` relaunched (PID 32444). The app list now has one running Sweep process. The clean page still reports zero selected items. No cache cleanup was started.

An optional system-Trash integration run against owned workspace fixtures finished 71/74: macOS denied Trash access to three synthetic fixture paths. This is separate from the cache-cleanup regression suite and did not touch user files.

## Remaining behavior limits

The active-process monitor samples about every 500 ms, leaving a short window before the final filesystem checks. A small race also remains between the last metadata/path check and the unlink syscall. Shared hard links spanning separate candidates may conservatively cause a later candidate to be retained until rescanned. These cases do not change the default-unselected policy.
