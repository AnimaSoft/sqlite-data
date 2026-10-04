# Gigs CloudKit safety patches

Upstream: Point-Free SQLiteData 1.12.0 (`164bb5f223738af3d5da7a1b8de14e67e4d9cd5d`).

Retained fixes: explicit dependency-ordered import retry, failed-import retention, full asset downloads for conflict resolution, non-destructive reference-violation recovery, and deletion-generation protection. Database read failures retain pending saves. The read-only `pendingRecordChanges` snapshot lets applications scope and batch work without modifying the native queue.

Native automatic syncing remains enabled. Scheduling, posters, diagnostics UI, and duplicate policy belong to Gigs. No schema, record identity, database filename, or token changes are made by this fork. Upstream history and license are retained.

Regression coverage: `GigsImportRetryTests` and Gigs application sync/storage tests. Update from an upstream release on a maintenance branch, drop adopted patches, run these tests and mixed-version device trials, then pin the verified commit. Never depend on this branch by name. Return to upstream when all regressions pass without patches.

No upstream issue or pull request is published by this change.
