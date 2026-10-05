#if canImport(CloudKit)
import Clocks
import CloudKit
import DependenciesTestSupport
@testable import SQLiteData
import SQLiteDataTestSupport
import Testing
import TestLocals

@Suite(.dependencies {
  $0.currentTime.now = 0
  $0.continuousClock = TestClock<Duration>()
  $0.dataManager = InMemoryDataManager()
}, .taskLocal($attachMetadatabase, false))
struct GigsImportRetryTests {
  @MainActor @Test func unreadableRowStaysQueuedWhileHealthyRowsProgress() async throws {
    let fixture = try await BaseCloudKitTests()
    try await fixture.userDatabase.userWrite { db in
      try db.seed {
        RemindersList(id: 1, title: "Healthy")
        Reminder(id: 1, title: "Retained", remindersListID: 1)
      }
    }
    let id = Reminder.recordID(for: 1)
    try await fixture.userDatabase.userWrite { db in
      try db.execute(sql: "DROP TABLE reminders")
    }
    await withKnownIssue {
      let batch = await fixture.syncEngine.nextRecordZoneChangeBatch(syncEngine: fixture.syncEngine.private)
      #expect(batch?.recordsToSave.contains { $0.recordID == RemindersList.recordID(for: 1) } == true)
    }
    #expect(fixture.syncEngine.private.state.pendingRecordZoneChanges.contains(.saveRecord(id)))
    // This intentionally broken fixture cannot retry; clear only mock state
    // after verifying retention so BaseCloudKitTests can check its teardown.
    fixture.syncEngine.private.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
  }

  @MainActor @Test func assetConflictDownloadsTheCompleteServerRecordBeforeMerging() async throws {
    let fixture = try await BaseCloudKitTests()
    try await fixture.userDatabase.userWrite { db in
      try db.seed {
        RemindersList(id: 1, title: "Saved list")
        RemindersListAsset(remindersListID: 1, coverImage: Data("preserved image".utf8))
      }
    }
    try await fixture.syncEngine.processPendingRecordZoneChanges(scope: .private)
    let id = RemindersListAsset.recordID(for: 1)
    let full = try fixture.container.privateCloudDatabase.record(for: id)
    let imageURL = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try fixture.inMemoryDataManager.save(Data("downloaded server image".utf8), to: imageURL)
    full.setAsset(CKAsset(fileURL: imageURL), forKey: "coverImage", at: 1)
    _ = try fixture.syncEngine.modifyRecords(scope: .private, saving: [full])
    // Conflict payloads can omit usable asset contents. They are not a full
    // downloaded record and must not turn a required BLOB into SQL NULL.
    let partial = try #require(full.copy() as? CKRecord)
    partial["coverImage"] = nil
    let error = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: partial])
    await fixture.syncEngine.handleSentRecordZoneChanges(
      failedRecordSaves: [(full, error)], syncEngine: fixture.syncEngine.private
    )
    #expect(try await fixture.userDatabase.read { try RemindersListAsset.find(1).fetchOne($0)?.coverImage } == Data("downloaded server image".utf8))
    #expect(try await fixture.syncEngine.metadatabase.read { try UnsyncedRecordID.count().fetchOne($0) } == 0)
    #expect(fixture.syncEngine.private.state.pendingRecordZoneChanges.contains(.saveRecord(id)))
    try await fixture.syncEngine.processPendingRecordZoneChanges(scope: .private)
  }

  @MainActor @Test func receivedDeletionRejectsAnOlderDependencyLookup() async throws {
    let fixture = try await BaseCloudKitTests()
    let parent = CKRecord(recordType: RemindersList.tableName, recordID: RemindersList.recordID(for: 1))
    parent.setValue(1, forKey: "id", at: 0)
    let child = CKRecord(recordType: Reminder.tableName, recordID: Reminder.recordID(for: 1))
    child.setValue(1, forKey: "id", at: 0)
    child.setValue(1, forKey: "remindersListID", at: 0)
    _ = try fixture.syncEngine.modifyRecords(scope: .private, saving: [parent])
    try await fixture.syncEngine.modifyRecords(scope: .private, saving: [child]).notify()
    let generation = fixture.syncEngine.receivedDeletionGeneration.value
    let oldLookup = try fixture.container.privateCloudDatabase.record(for: parent.recordID)
    try await fixture.syncEngine.modifyRecords(scope: .private, deleting: [parent.recordID]).notify()
    await fixture.syncEngine.upsertFromServerRecord(oldLookup, expectedDeletionGeneration: generation)
    #expect(try await fixture.userDatabase.read { try RemindersList.count().fetchOne($0) } == 0)
    #expect(try await fixture.syncEngine.metadatabase.read { try UnsyncedRecordID.count().fetchOne($0) } == 1)
    // A fresh, subsequently restored source record remains recoverable.
    _ = try fixture.syncEngine.modifyRecords(scope: .private, saving: [parent])
    try await fixture.syncEngine.retryFailedImports()
    #expect(try await fixture.userDatabase.read { try Reminder.count().fetchOne($0) } == 1)
  }

  @MainActor @Test func parentOutsideRetryQueueImportsWithoutNewZoneChanges() async throws {
    let fixture = try await BaseCloudKitTests()
    let parent = CKRecord(recordType: RemindersList.tableName, recordID: RemindersList.recordID(for: 1))
    parent.setValue(1, forKey: "id", at: 0)
    parent.setValue("Saved list", forKey: "title", at: 0)
    let child = CKRecord(recordType: Reminder.tableName, recordID: Reminder.recordID(for: 1))
    child.setValue(1, forKey: "id", at: 0)
    child.setValue(1, forKey: "remindersListID", at: 0)
    child.setValue("Saved reminder", forKey: "title", at: 0)
    _ = try fixture.syncEngine.modifyRecords(scope: .private, saving: [parent])
    try await fixture.syncEngine.modifyRecords(scope: .private, saving: [child]).notify()
    #expect(try await fixture.userDatabase.read { try RemindersList.count().fetchOne($0) } == 0)
    #expect(try await fixture.syncEngine.metadatabase.read { try UnsyncedRecordID.count().fetchOne($0) } == 1)
    try await fixture.syncEngine.retryFailedImports()
    #expect(try await fixture.userDatabase.read { try RemindersList.find(1).fetchOne($0)?.title } == "Saved list")
    #expect(try await fixture.userDatabase.read { try Reminder.find(1).fetchOne($0)?.title } == "Saved reminder")
    #expect(try await fixture.syncEngine.metadatabase.read { try UnsyncedRecordID.count().fetchOne($0) } == 0)
    fixture.syncEngine.private.state.assertPendingRecordZoneChanges([])
    try await fixture.syncEngine.retryFailedImports()
  }

  @MainActor @Test func unavailableParentDoesNotDiscardChildAndRecoversWhenRestored() async throws {
    let fixture = try await BaseCloudKitTests()
    let child = CKRecord(recordType: Reminder.tableName, recordID: Reminder.recordID(for: 1))
    child.setValue(1, forKey: "id", at: 0)
    child.setValue(1, forKey: "remindersListID", at: 0)
    try await fixture.syncEngine.modifyRecords(scope: .private, saving: [child]).notify()
    try await fixture.syncEngine.retryFailedImports()
    #expect(try await fixture.syncEngine.metadatabase.read { try UnsyncedRecordID.count().fetchOne($0) } == 1)
    #expect(try await fixture.userDatabase.read { try Reminder.count().fetchOne($0) } == 0)
    let parent = CKRecord(recordType: RemindersList.tableName, recordID: RemindersList.recordID(for: 1))
    parent.setValue(1, forKey: "id", at: 0)
    _ = try fixture.syncEngine.modifyRecords(scope: .private, saving: [parent])
    try await fixture.syncEngine.retryFailedImports()
    #expect(try await fixture.userDatabase.read { try Reminder.count().fetchOne($0) } == 1)
    #expect(try await fixture.syncEngine.metadatabase.read { try UnsyncedRecordID.count().fetchOne($0) } == 0)
  }

  @MainActor @Test func accountFailurePropagatesWithoutDiscardingPendingImports() async throws {
    let fixture = try await BaseCloudKitTests()
    let parent = CKRecord(recordType: RemindersList.tableName, recordID: RemindersList.recordID(for: 1))
    parent.setValue(1, forKey: "id", at: 0)
    let child = CKRecord(recordType: Reminder.tableName, recordID: Reminder.recordID(for: 1))
    child.setValue(1, forKey: "id", at: 0)
    child.setValue(1, forKey: "remindersListID", at: 0)
    _ = try fixture.syncEngine.modifyRecords(scope: .private, saving: [parent])
    try await fixture.syncEngine.modifyRecords(scope: .private, saving: [child]).notify()
    await fixture.softSignOut()
    do {
      try await fixture.syncEngine.retryFailedImports()
      Issue.record("An unavailable account should propagate its error")
    } catch let error as CKError {
      #expect(error.code == .accountTemporarilyUnavailable)
    }
    #expect(try await fixture.syncEngine.metadatabase.read { try UnsyncedRecordID.count().fetchOne($0) } == 1)
    fixture.container._accountStatus.withValue { $0 = .available }
    try await fixture.syncEngine.retryFailedImports()
    #expect(try await fixture.syncEngine.metadatabase.read { try UnsyncedRecordID.count().fetchOne($0) } == 0)
  }

  @MainActor @Test func missingRecordLookupIsRetainedUntilARealDeletionArrives() async throws {
    let fixture = try await BaseCloudKitTests()
    let id = Reminder.recordID(for: 77)
    try await fixture.userDatabase.write { db in
      try UnsyncedRecordID.insert { UnsyncedRecordID(recordID: id) }.execute(db)
    }
    await fixture.syncEngine.handleFetchedRecordZoneChanges(syncEngine: fixture.syncEngine.private)
    #expect(try await fixture.syncEngine.metadatabase.read { try UnsyncedRecordID.count().fetchOne($0) } == 1)
    try await fixture.syncEngine.retryFailedImports()
    #expect(try await fixture.syncEngine.metadatabase.read { try UnsyncedRecordID.count().fetchOne($0) } == 1)
    await fixture.syncEngine.handleFetchedRecordZoneChanges(deletions: [(id, Reminder.tableName)], syncEngine: fixture.syncEngine.private)
    #expect(try await fixture.syncEngine.metadatabase.read { try UnsyncedRecordID.count().fetchOne($0) } == 0)
  }

  @MainActor @Test func cancelledRetryKeepsPendingImportsForTheNextAttempt() async throws {
    let fixture = try await BaseCloudKitTests()
    let child = CKRecord(recordType: Reminder.tableName, recordID: Reminder.recordID(for: 1))
    child.setValue(1, forKey: "id", at: 0)
    child.setValue(1, forKey: "remindersListID", at: 0)
    try await fixture.syncEngine.modifyRecords(scope: .private, saving: [child]).notify()
    let operation = Task {
      try Task.checkCancellation()
      try await fixture.syncEngine.retryFailedImports()
    }
    operation.cancel()
    do {
      try await operation.value
      Issue.record("A cancelled retry should throw")
    } catch is CancellationError {}
    #expect(try await fixture.syncEngine.metadatabase.read { try UnsyncedRecordID.count().fetchOne($0) } == 1)
    let parent = CKRecord(recordType: RemindersList.tableName, recordID: RemindersList.recordID(for: 1))
    parent.setValue(1, forKey: "id", at: 0)
    _ = try fixture.syncEngine.modifyRecords(scope: .private, saving: [parent])
    try await fixture.syncEngine.retryFailedImports()
    #expect(try await fixture.syncEngine.metadatabase.read { try UnsyncedRecordID.count().fetchOne($0) } == 0)
  }

  @MainActor @Test func failedParentReferencePreservesLocalContentAndRequeuesParentFirst() async throws {
    let fixture = try await BaseCloudKitTests()
    try await fixture.userDatabase.userWrite { db in
      try RemindersList.insert { RemindersList(id: 1, title: "Local list") }.execute(db)
      try Reminder.insert { Reminder(id: 1, title: "Private content", remindersListID: 1) }.execute(db)
    }
    let child = CKRecord(recordType: Reminder.tableName, recordID: Reminder.recordID(for: 1))
    child.parent = CKRecord.Reference(recordID: RemindersList.recordID(for: 1), action: .none)
    await fixture.syncEngine.handleSentRecordZoneChanges(
      failedRecordSaves: [(child, CKError(.referenceViolation))], syncEngine: fixture.syncEngine.private)
    #expect(try await fixture.userDatabase.read { try Reminder.find(1).fetchOne($0)?.title } == "Private content")
    #expect(Set(fixture.syncEngine.private.state.pendingRecordZoneChanges) == [
      .saveRecord(RemindersList.recordID(for: 1)), .saveRecord(Reminder.recordID(for: 1))
    ])
    try await fixture.syncEngine.processPendingRecordZoneChanges(scope: .private)
  }

  @MainActor @Test func recursiveDependenciesImportInOrderAndReceivedDeletionStillWorks() async throws {
    let fixture = try await BaseCloudKitTests()
    let root = CKRecord(recordType: ModelA.tableName, recordID: ModelA.recordID(for: 1))
    root.setValue(1, forKey: "id", at: 0)
    let middle = CKRecord(recordType: ModelB.tableName, recordID: ModelB.recordID(for: 1))
    middle.setValue(1, forKey: "id", at: 0)
    middle.setValue(1, forKey: "modelAID", at: 0)
    let leaf = CKRecord(recordType: ModelC.tableName, recordID: ModelC.recordID(for: 1))
    leaf.setValue(1, forKey: "id", at: 0)
    leaf.setValue(1, forKey: "modelBID", at: 0)
    _ = try fixture.syncEngine.modifyRecords(scope: .private, saving: [root, middle])
    try await fixture.syncEngine.modifyRecords(scope: .private, saving: [leaf]).notify()
    try await fixture.syncEngine.retryFailedImports()
    #expect(try await fixture.userDatabase.read { try ModelA.count().fetchOne($0) } == 1)
    #expect(try await fixture.userDatabase.read { try ModelB.count().fetchOne($0) } == 1)
    #expect(try await fixture.userDatabase.read { try ModelC.count().fetchOne($0) } == 1)
    try await fixture.syncEngine.modifyRecords(scope: .private, deleting: [leaf.recordID, middle.recordID, root.recordID]).notify()
    #expect(try await fixture.userDatabase.read { try ModelC.count().fetchOne($0) } == 0)
  }
  @MainActor @Test func schemaReplayFailureSurvivesRestartAndHealthyRowsProgress() async throws {
    let fixture = try await BaseCloudKitTests()
    try await fixture.userDatabase.userWrite { db in
      try db.seed {
        RemindersList(id: 1, title: "One")
        RemindersList(id: 2, title: "Two")
      }
    }
    try await fixture.syncEngine.processPendingRecordZoneChanges(scope: .private)
    try await fixture.userDatabase.write { db in
      try $_isSynchronizingChanges.withValue(true) {
        try db.execute(sql: "UPDATE remindersLists SET title = 'default'")
      }
      try db.execute(sql: "CREATE TRIGGER reject_one BEFORE UPDATE ON remindersLists WHEN NEW.id = 1 BEGIN SELECT RAISE(ABORT, 'fixture'); END")
    }
    try await fixture.syncEngine.stageSchemaReplay(tableName: RemindersList.tableName, columns: ["title"])
    await withKnownIssue { try await fixture.syncEngine.replaySchemaChanges() }
    #expect(try await fixture.userDatabase.read { try RemindersList.find(2).fetchOne($0)?.title } == "Two")
    #expect(try await fixture.syncEngine.metadatabase.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sqlitedata_icloud_schemaReplay") } == 1)
    try await fixture.userDatabase.write { try $0.execute(sql: "DROP TRIGGER reject_one") }
    let restarted = try await SyncEngine(container: fixture.syncEngine.container,
      userDatabase: fixture.userDatabase, tables: fixture.syncEngine.tables, privateTables: fixture.syncEngine.privateTables)
    try await restarted.retryFailedImports()
    #expect(try await fixture.userDatabase.read { try RemindersList.find(1).fetchOne($0)?.title } == "One")
    #expect(try await restarted.metadatabase.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sqlitedata_icloud_schemaReplay") } == 0)
    restarted.stop()
  }

  @MainActor @Test func schemaReplayPreservesAnEditMadeAfterStaging() async throws {
    let fixture = try await BaseCloudKitTests()
    try await fixture.userDatabase.userWrite { db in try RemindersList.insert { RemindersList(id: 1, title: "Remote") }.execute(db) }
    try await fixture.syncEngine.processPendingRecordZoneChanges(scope: .private)
    try await fixture.syncEngine.stageSchemaReplay(tableName: RemindersList.tableName, columns: ["title"])
    try await withDependencies { $0.currentTime.now = 60 } operation: {
      try await fixture.userDatabase.userWrite { db in try RemindersList.find(1).update { $0.title = "New local edit" }.execute(db) }
    }
    try await fixture.syncEngine.replaySchemaChanges()
    #expect(try await fixture.userDatabase.read { try RemindersList.find(1).fetchOne($0)?.title } == "New local edit")
    try await fixture.syncEngine.processPendingRecordZoneChanges(scope: .private)
  }

  @MainActor @Test func missingLocalAcknowledgedRecordIsRecoveredFromCurrentServerState() async throws {
    let fixture = try await BaseCloudKitTests()
    let parent = CKRecord(recordType: RemindersList.tableName, recordID: RemindersList.recordID(for: 1))
    parent.setValue(1, forKey: "id", at: 0)
    parent.setValue("Current", forKey: "title", at: 0)
    try await fixture.syncEngine.modifyRecords(scope: .private, saving: [parent]).notify()
    try await fixture.userDatabase.write { db in
      try db.execute(sql: "DROP TRIGGER IF EXISTS sqlitedata_icloud_after_delete_on_remindersLists_from_sync_engine")
      try $_isSynchronizingChanges.withValue(true) { try RemindersList.find(1).delete().execute(db) }
      // Reproduce legacy loss with live acknowledgement, not a deletion intent.
      try db.execute(sql: "UPDATE sqlitedata_icloud_metadata SET _isDeleted = 0 WHERE recordType = 'remindersLists'")
    }
    #expect(try await fixture.syncEngine.checkImportIntegrity() == 1)
    try await fixture.syncEngine.retryFailedImports()
    #expect(try await fixture.userDatabase.read { try RemindersList.find(1).fetchOne($0)?.title } == "Current")
    #expect(try await fixture.syncEngine.checkImportIntegrity() == 0)
  }

  @MainActor @Test func malformedRecordIsRetainedUntilAValidRevisionArrives() async throws {
    let fixture = try await BaseCloudKitTests()
    let malformed = CKRecord(recordType: RemindersList.tableName, recordID: RemindersList.recordID(for: 1))
    malformed["id"] = 1
    malformed["title"] = "Incomplete"
    let healthy = CKRecord(recordType: RemindersList.tableName, recordID: RemindersList.recordID(for: 2))
    healthy.setValue(2, forKey: "id", at: 0)
    healthy.setValue("Healthy", forKey: "title", at: 0)
    await fixture.syncEngine.handleFetchedRecordZoneChanges(modifications: [malformed, healthy], syncEngine: fixture.syncEngine.private)
    #expect(try await fixture.syncEngine.metadatabase.read { try UnsyncedRecordID.count().fetchOne($0) } == 1)
    #expect(try await fixture.userDatabase.read { try RemindersList.find(2).fetchOne($0)?.title } == "Healthy")
    let corrected = CKRecord(recordType: RemindersList.tableName, recordID: malformed.recordID)
    corrected.setValue(1, forKey: "id", at: 60)
    corrected.setValue("Complete", forKey: "title", at: 60)
    await fixture.syncEngine.handleFetchedRecordZoneChanges(modifications: [corrected], syncEngine: fixture.syncEngine.private)
    #expect(try await fixture.syncEngine.metadatabase.read { try UnsyncedRecordID.count().fetchOne($0) } == 0)
    #expect(try await fixture.userDatabase.read { try RemindersList.find(1).fetchOne($0)?.title } == "Complete")
  }

  @MainActor @Test func schemaReplayNeverRestoresAnAbsentRowFromCachedContent() async throws {
    let fixture = try await BaseCloudKitTests()
    let id = RemindersList.recordID(for: 1)
    let record = CKRecord(recordType: RemindersList.tableName, recordID: id)
    record.setValue(1, forKey: "id", at: 0)
    record.setValue("Old cached value", forKey: "title", at: 0)
    try await fixture.syncEngine.modifyRecords(scope: .private, saving: [record]).notify()
    try await fixture.userDatabase.write { db in
      try db.execute(sql: "DROP TRIGGER IF EXISTS sqlitedata_icloud_after_delete_on_remindersLists_from_sync_engine")
      try $_isSynchronizingChanges.withValue(true) { try RemindersList.find(1).delete().execute(db) }
      try db.execute(sql: "UPDATE sqlitedata_icloud_metadata SET _isDeleted = 0 WHERE recordType = 'remindersLists'")
    }
    // The server has newer content, while the acknowledged payload is stale.
    let current = try fixture.container.privateCloudDatabase.record(for: id)
    current.setValue("Current server value", forKey: "title", at: 60)
    _ = try fixture.syncEngine.modifyRecords(scope: .private, saving: [current])
    try await fixture.syncEngine.stageSchemaReplay(tableName: RemindersList.tableName, columns: ["title"])
    try await fixture.syncEngine.replaySchemaChanges()
    try await fixture.syncEngine.replaySchemaChanges()
    #expect(try await fixture.userDatabase.read { try RemindersList.count().fetchOne($0) } == 0)
    #expect(try await fixture.syncEngine.metadatabase.read { try UnsyncedRecordID.count().fetchOne($0) } == 1)
    try await fixture.syncEngine.retryFailedImports()
    let restored = try await fixture.userDatabase.read { try RemindersList.find(1).fetchOne($0) }
    #expect(restored?.title == "Current server value")
  }

  @MainActor @Test func unavailableAssetKeepsExistingBytesAndPendingImport() async throws {
    let fixture = try await BaseCloudKitTests()
    try await fixture.userDatabase.userWrite { db in
      try db.seed {
        RemindersList(id: 1, title: "List")
        RemindersListAsset(remindersListID: 1, coverImage: Data("original".utf8))
      }
    }
    try await fixture.syncEngine.processPendingRecordZoneChanges(scope: .private)
    let record = try fixture.container.privateCloudDatabase.record(for: RemindersListAsset.recordID(for: 1))
    let unavailable = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try fixture.inMemoryDataManager.save(Data("restored".utf8), to: unavailable)
    record.setAsset(CKAsset(fileURL: unavailable), forKey: "coverImage", at: 60)
    _ = try fixture.syncEngine.modifyRecords(scope: .private, saving: [record])
    fixture.inMemoryDataManager.storage.withValue { $0[unavailable] = nil }
    await withKnownIssue { await fixture.syncEngine.upsertFromServerRecord(record, force: true) }
    #expect(try await fixture.userDatabase.read { try RemindersListAsset.find(1).fetchOne($0)?.coverImage } == Data("original".utf8))
    #expect(try await fixture.syncEngine.metadatabase.read { try UnsyncedRecordID.count().fetchOne($0) } == 1)
    try fixture.inMemoryDataManager.save(Data("restored".utf8), to: unavailable)
    try await fixture.syncEngine.retryFailedImports()
    #expect(try await fixture.userDatabase.read { try RemindersListAsset.find(1).fetchOne($0)?.coverImage } == Data("restored".utf8))
  }

  @MainActor @Test func failedReceivedDeletionIsRetainedAndAppliedAfterRestart() async throws {
    let fixture = try await BaseCloudKitTests()
    try await fixture.userDatabase.userWrite { db in try RemindersList.insert { RemindersList(id: 1, title: "Deleted remotely") }.execute(db) }
    try await fixture.syncEngine.processPendingRecordZoneChanges(scope: .private)
    try await fixture.userDatabase.write { try $0.execute(sql: "CREATE TRIGGER reject_delete BEFORE DELETE ON remindersLists BEGIN SELECT RAISE(ABORT, 'fixture'); END") }
    await withKnownIssue {
      try await fixture.syncEngine.modifyRecords(scope: .private, deleting: [RemindersList.recordID(for: 1)]).notify()
    }
    #expect(try await fixture.syncEngine.metadatabase.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sqlitedata_icloud_receivedDeletions") } == 1)
    try await fixture.userDatabase.write { try $0.execute(sql: "DROP TRIGGER reject_delete") }
    let restarted = try await SyncEngine(container: fixture.syncEngine.container,
      userDatabase: fixture.userDatabase, tables: fixture.syncEngine.tables, privateTables: fixture.syncEngine.privateTables)
    try await restarted.retryFailedImports()
    #expect(try await fixture.userDatabase.read { try RemindersList.count().fetchOne($0) } == 0)
    #expect(try await restarted.metadatabase.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sqlitedata_icloud_receivedDeletions") } == 0)
    restarted.stop()
  }

  @MainActor @Test func stagingFailureStopsBeforeApplyingAnUnretainedImport() async throws {
    let fixture = try await BaseCloudKitTests()
    let record = CKRecord(recordType: RemindersList.tableName, recordID: RemindersList.recordID(for: 1))
    record.setValue(1, forKey: "id", at: 0)
    try await fixture.syncEngine.metadatabase.write { try $0.execute(sql: "CREATE TRIGGER reject_receipt BEFORE INSERT ON sqlitedata_icloud_unsyncedRecordIDs BEGIN SELECT RAISE(ABORT, 'fixture'); END") }
    await withKnownIssue { await fixture.syncEngine.handleFetchedRecordZoneChanges(modifications: [record], syncEngine: fixture.syncEngine.private) }
    #expect(!fixture.syncEngine.isRunning)
    #expect(fixture.syncEngine.unsafeImportScopes.value.contains(.private))
    #expect(try await fixture.userDatabase.read { try RemindersList.count().fetchOne($0) } == 0)
    try await fixture.syncEngine.metadatabase.write { try $0.execute(sql: "DROP TRIGGER reject_receipt") }
    try await fixture.syncEngine.start()
    try await fixture.syncEngine.processPendingDatabaseChanges(scope: .private)
    await fixture.syncEngine.handleFetchedRecordZoneChanges(modifications: [record], syncEngine: fixture.syncEngine.private)
    #expect(try await fixture.userDatabase.read { try RemindersList.count().fetchOne($0) } == 1)
  }

}
#endif
