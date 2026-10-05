# Gigs CloudKit safety patches

Upstream: Point-Free SQLiteData 1.12.0 (`164bb5f223738af3d5da7a1b8de14e67e4d9cd5d`).

Retained fixes: explicit dependency-ordered import retry, failed-import retention, full asset downloads for conflict resolution, non-destructive reference-violation recovery, and deletion-generation protection. Database read failures retain pending saves. The read-only `pendingRecordChanges` snapshot lets applications scope and batch work without modifying the native queue.

Native automatic syncing remains enabled. Scheduling, posters, diagnostics UI, and duplicate policy belong to Gigs. CloudKit schemas, record identities, database filenames, and tokens are unchanged. Additive local metadata tables retain schema replay, received deletions, and integrity scan checkpoints. Upstream history and license are retained.

Regression coverage: `GigsImportRetryTests` and Gigs application sync/storage tests. Update from an upstream release on a maintenance branch, drop adopted patches, run these tests and mixed-version device trials, then pin the verified commit. Never depend on this branch by name. Return to upstream when all regressions pass without patches.

No upstream issue or pull request is published by this change.

## Durable imports and upgrades

A received known record is queued before user-database writes. A staging failure stops the engine and withholds advanced state serialization, so a subsequent start uses the durable cursor. Record-specific schema replay failures retain their affected columns while other rows and schema caching proceed. Replay is batched and cannot overwrite edits made after staging. Received deletion receipts survive failed transactions and are retired atomically with application. Missing asset files throw instead of writing NULL/default bytes. Integrity checks enqueue missing acknowledged rows for a current-server lookup; cached payloads are never used as authority for restoration.

Removal criteria: unmodified upstream must pass `GigsImportRetryTests` including schema replay across restart, staged import failure, received deletion rollback, current-server integrity recovery, and missing asset preservation, alongside schema/asset/reference/upgrade suites and app regressions. These changes have no Gigs-specific tables or duplicate policy.

Schema replay never recreates an absent local row from a cached payload. It retains a current-server lookup obligation; new synchronized tables import their existing records through the normal retry path. The schema upgrade fixture exercises this extra verification step.
