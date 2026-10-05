#if canImport(CloudKit)
import CloudKit
import Foundation
import GRDB
import StructuredQueries

private struct ReplayRow: Sendable {
  let name: String
  let primaryKey: String
  let zone: String
  let owner: String
  let time: Int64
  let columns: String
  let expected: Int64
  init(_ row: Row) {
    name = row["recordName"]
    primaryKey = row.hasColumn("recordPrimaryKey") ? row["recordPrimaryKey"] : ""
    zone = row["zoneName"]
    owner = row["ownerName"]
    time = row.hasColumn("userModificationTime") ? row["userModificationTime"] : 0
    columns = row.hasColumn("columnNames") ? row["columnNames"] : "[]"
    expected = row.hasColumn("expectedModificationTime") ? row["expectedModificationTime"] : 0
  }
}

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
extension SyncEngine {
  package func stageSchemaReplay(tableName: String, columns: [String]) async throws {
    var cursor = ""
    while true {
      try Task.checkCancellation()
      let position = cursor
      let batch = try await metadatabase.read { db in
        try Row.fetchAll(db, sql: """
          SELECT recordName, recordPrimaryKey, zoneName, ownerName, userModificationTime
          FROM sqlitedata_icloud_metadata WHERE recordType = ? AND _isDeleted = 0
            AND _lastKnownServerRecordAllFields IS NOT NULL AND recordPrimaryKey > ?
          ORDER BY recordPrimaryKey LIMIT 100
          """, arguments: [tableName, position]).map { ReplayRow($0) }
      }
      guard !batch.isEmpty else { return }
      try await metadatabase.write { db in
        for row in batch {
          let name: String = row.name
          let zone: String = row.zone
          let owner: String = row.owner
          let old = try String.fetchOne(db, sql: "SELECT columnNames FROM sqlitedata_icloud_schemaReplay WHERE recordName = ? AND zoneName = ? AND ownerName = ?", arguments: [name, zone, owner])
          let previous = try old.map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
          let encoded = String(decoding: try JSONEncoder().encode(Set(previous + columns).sorted()), as: UTF8.self)
          let time: Int64 = row.time
          try db.execute(sql: """
            INSERT INTO sqlitedata_icloud_schemaReplay
              (recordName, zoneName, ownerName, columnNames, expectedModificationTime) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(recordName, zoneName, ownerName) DO UPDATE SET columnNames = excluded.columnNames
            """, arguments: [name, zone, owner, encoded, time])
        }
      }
      cursor = batch.last?.primaryKey ?? cursor
      await Task.yield()
    }
  }

  package func replaySchemaChanges() async throws {
    var cursor = ("", "", "")
    while true {
      try Task.checkCancellation()
      let position = cursor
      let batch = try await metadatabase.read { db in
        try Row.fetchAll(db, sql: """
          SELECT * FROM sqlitedata_icloud_schemaReplay
          WHERE (recordName, zoneName, ownerName) > (?, ?, ?)
          ORDER BY recordName, zoneName, ownerName LIMIT 100
          """, arguments: [position.0, position.1, position.2]).map { ReplayRow($0) }
      }
      guard !batch.isEmpty else { return }
      for row in batch {
        try Task.checkCancellation()
        let name: String = row.name
        let zone: String = row.zone
        let owner: String = row.owner
        cursor = (name, zone, owner)
        let id = CKRecord.ID(recordName: name, zoneID: .init(zoneName: zone, ownerName: owner))
        guard let tableName = id.tableName, let table = tablesByName[tableName] else { continue }
        do {
          let encoded: String = row.columns
          let columns = try JSONDecoder().decode([String].self, from: Data(encoded.utf8))
          let expected: Int64 = row.expected
          guard let metadata = try await metadatabase.read({ try SyncMetadata.find(id).fetchOne($0) }) else { continue }
          if metadata._isDeleted {
            try await userDatabase.write { try clearImportObligations(id, db: $0, schemaOnly: true) }
            continue
          }
          guard let record = metadata._lastKnownServerRecordAllFields else { continue }
          func open<T>(_ table: some SynchronizableTable<T>) async throws {
            guard let primaryKey = id.recordPrimaryKey else { return }
            let exists = try await userDatabase.read { db in
              try T.unscoped.find(#sql("\(bind: primaryKey)")).fetchOne(db) != nil
            }
            guard exists else {
              // Cached schema values cannot establish that an absent row still
              // exists on the server. Retain a current-server lookup obligation.
              try await metadatabase.write { db in
                try UnsyncedRecordID.insert { UnsyncedRecordID(recordID: id) } onConflictDoUpdate: { _ in }.execute(db)
              }
              return
            }
            let query = try await updateQuery(for: table, record: record,
              columnNames: T.TableColumns.writableColumns.map(\.name), changedColumnNames: columns)
            try await userDatabase.write { db in
              // Replay never overwrites a row edited since the obligation was staged.
              if let latest = try SyncMetadata.find(id).fetchOne(db), !latest._isDeleted,
                latest.userModificationTime == expected,
                try T.unscoped.find(#sql("\(bind: primaryKey)")).fetchOne(db) != nil {
                try $_isSynchronizingChanges.withValue(true) {
                  try $_currentZoneID.withValue(id.zoneID) { try #sql(query).execute(db) }
                }
              }
              try clearImportObligations(id, db: db, schemaOnly: true)
            }
          }
          try await open(table)
        } catch is CancellationError { throw CancellationError() }
        catch {
          // The durable obligation remains. Continue with independent records.
          reportIssue(NSError(domain: "SQLiteData.SchemaReplay", code: 1,
            userInfo: [NSUnderlyingErrorKey: error, "SQLiteDataRecordName": name,
                       "SQLiteDataOperation": "schemaReplay"]))
        }
      }
      await Task.yield()
    }
  }

  func clearImportObligations(_ id: CKRecord.ID, db: Database, schemaOnly: Bool = false) throws {
    let tables = schemaOnly ? ["sqlitedata_icloud_schemaReplay"]
      : ["sqlitedata_icloud_schemaReplay", "sqlitedata_icloud_receivedDeletions"]
    for table in tables {
      try db.execute(sql: "DELETE FROM \"\(table)\" WHERE recordName = ? AND zoneName = ? AND ownerName = ?",
        arguments: [id.recordName, id.zoneID.zoneName, id.zoneID.ownerName])
    }
  }
}
#endif
