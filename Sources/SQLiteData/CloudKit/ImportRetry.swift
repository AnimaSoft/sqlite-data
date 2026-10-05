#if canImport(CloudKit)
import CloudKit
import Foundation
import GRDB
import StructuredQueries

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
extension SyncEngine {
  /// Retries blocked imports even when CloudKit has no new zone changes.
  /// Fetches absent foreign-key dependencies, then uses the existing merge path.
  /// Call from the application's coalesced fetch lane. Tokens are untouched.
  public func retryFailedImports() async throws {
    guard isRunning else { return }
    try await replaySchemaChanges(propagateServiceErrors: true)
    let engines = syncEngines.withValue { [$0.private, $0.shared].compactMap { $0 } }
    for engine in engines {
      try Task.checkCancellation()
      let deletions = try await metadatabase.read { db in
        try Row.fetchAll(db, sql: "SELECT * FROM sqlitedata_icloud_receivedDeletions")
          .compactMap { row -> (CKRecord.ID, String)? in
            let owner: String = row["ownerName"]
            guard (owner == CKCurrentUserDefaultName) == (engine.database.databaseScope == .private) else { return nil }
            return (.init(recordName: row["recordName"], zoneID: .init(zoneName: row["zoneName"], ownerName: owner)), row["recordType"])
          }
      }
      for offset in stride(from: 0, to: deletions.count, by: 100) {
        try Task.checkCancellation()
        await handleFetchedRecordZoneChanges(deletions: Array(deletions.dropFirst(offset).prefix(100)), syncEngine: engine)
      }
      let ids = try await metadatabase.read { db in
        try UnsyncedRecordID.all.fetchAll(db)
          .map(CKRecord.ID.init(unsyncedRecordID:))
          .filter {
            ($0.zoneID.ownerName == CKCurrentUserDefaultName)
              == (engine.database.databaseScope == .private)
          }
      }.sorted { importOrder($0.tableName, $1.tableName) }
      var retainedFailure: (any Error)?
      for start in stride(from: 0, to: ids.count, by: 150) {
        try Task.checkCancellation()
        let deletionGeneration = receivedDeletionGeneration.value
        let results = try await engine.database.records(for: Array(ids.dropFirst(start).prefix(150)))
        var records: [CKRecord] = []
        var failure: (any Error)?
        for result in results.values {
          switch result {
          case .success(let record): records.append(record)
          case .failure(let error as CKError) where error.code == .unknownItem:
            // A server lookup failure isn't a received deletion. Keep the retry
            // pending so a surviving source device can restore this identity.
            continue
          case .failure(let error): failure = failure ?? error
          }
        }
        if let cloud = failure as? CKError,
          [.notAuthenticated, .accountTemporarilyUnavailable, .serviceUnavailable,
           .requestRateLimited, .zoneBusy, .networkFailure, .networkUnavailable].contains(cloud.code) { throw cloud }
        let recovery = try await recordsWithMissingDependencies(records, engine: engine)
        for record in recovery.records.sorted(by: { importOrder($0.recordType, $1.recordType) }) {
          try Task.checkCancellation()
          guard isRunning else { throw CancellationError() }
          await upsertFromServerRecord(record, expectedDeletionGeneration: deletionGeneration)
        }
        if let error = failure ?? recovery.failure {
          retainedFailure = retainedFailure ?? error
          if let cloud = error as? CKError,
            [.notAuthenticated, .accountTemporarilyUnavailable, .serviceUnavailable,
             .requestRateLimited, .zoneBusy, .networkFailure, .networkUnavailable].contains(cloud.code) { throw error }
        }
      }
      try await replaySchemaChanges(propagateServiceErrors: true)
      if let retainedFailure { throw retainedFailure }
    }
  }

  private func importOrder(_ lhs: String?, _ rhs: String?) -> Bool {
    let left = lhs.flatMap { tablesByOrder[$0] } ?? .max
    let right = rhs.flatMap { tablesByOrder[$0] } ?? .max
    return left == right ? (lhs ?? "") < (rhs ?? "") : left < right
  }

  private func recordsWithMissingDependencies(
    _ records: [CKRecord], engine: any SyncEngineProtocol
  ) async throws -> (records: [CKRecord], failure: (any Error)?) {
    var recovered = Dictionary(records.map { ($0.recordID, $0) }, uniquingKeysWith: { _, latest in latest })
    var visited = Set(recovered.keys)
    var failure: (any Error)?
    // The validated table graph is acyclic. Bound traversal by its depth.
    for _ in 0..<tables.count {
      try Task.checkCancellation()
      let currentRecords = Array(recovered.values)
      let tombstones = Set(try await metadatabase.read { db in
        try SyncMetadata.where(\._isDeleted).fetchAll(db)
          .map { CKRecord.ID(recordName: $0.recordName, zoneID: CKRecordZone.ID(zoneName: $0.zoneName, ownerName: $0.ownerName)) }
      })
      let dependencies = try await userDatabase.read { db in
        var missing: Set<CKRecord.ID> = []
        for record in currentRecords {
          guard tablesByName[record.recordType] != nil else { continue }
          for key in foreignKeysByTableName[record.recordType] ?? [] {
            guard tablesByName[key.table] != nil else { continue }
            let value = record.encryptedValues[key.from]
            let id: CKRecord.ID
            let primaryKey: String
            if let reference = value as? CKRecord.Reference,
               let key = reference.recordID.recordPrimaryKey {
              id = reference.recordID
              primaryKey = key
            } else if let value = (value as? String) ?? (value as? NSNumber)?.stringValue {
              id = CKRecord.ID(recordName: "\(value):\(key.table)", zoneID: record.recordID.zoneID)
              primaryKey = value
            } else { continue }
            if tombstones.contains(id) { continue }
            let table = key.table.replacing("\"", with: "\"\"")
            let column = key.to.replacing("\"", with: "\"\"")
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \"\(table)\" WHERE \"\(column)\" = ?)", arguments: [primaryKey]) != true {
              missing.insert(id)
            }
          }
        }
        return missing
      }.subtracting(visited)
      guard !dependencies.isEmpty else { break }
      visited.formUnion(dependencies)
      let ordered = dependencies.sorted { $0.recordName < $1.recordName }
      for start in stride(from: 0, to: ordered.count, by: 150) {
        try Task.checkCancellation()
        let results = try await engine.database.records(for: Array(ordered.dropFirst(start).prefix(150)))
        for (id, result) in results {
          switch result {
          case .success(let record): recovered[id] = record
          case .failure(let error as CKError) where error.code == .unknownItem: continue
          case .failure(let error): failure = failure ?? error
          }
        }
        if let cloud = failure as? CKError,
          [.notAuthenticated, .accountTemporarilyUnavailable, .serviceUnavailable,
           .requestRateLimited, .zoneBusy, .networkFailure, .networkUnavailable].contains(cloud.code) { throw cloud }
      }
      if failure != nil { break }
    }
    return (Array(recovered.values), failure)
  }
}
#endif
