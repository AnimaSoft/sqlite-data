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
}
#endif
