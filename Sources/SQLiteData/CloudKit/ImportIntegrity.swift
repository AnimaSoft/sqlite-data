#if canImport(CloudKit)
import CloudKit
import Foundation
import GRDB
import StructuredQueries

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
extension SyncEngine {
  /// Finds acknowledged live identities whose local rows are absent. This only
  /// queues current-server lookups; it never uploads or recreates cached content.
  /// Each checkpoint commits with its retry identities, so cancellation resumes.
  public func checkImportIntegrity() async throws -> Int {
    var queued = 0
    for table in tables {
      func open<T>(_: some SynchronizableTable<T>) async throws {
        let name = T.tableName
        let quotedTable = name.replacing("\"", with: "\"\"")
        let quotedKey = T.primaryKey.name.replacing("\"", with: "\"\"")
        var cursor = try await metadatabase.read {
          try String.fetchOne($0, sql: "SELECT cursor FROM sqlitedata_icloud_integrityProgress WHERE tableName = ?", arguments: [name]) ?? ""
        }
        while true {
          try Task.checkCancellation()
          let position = cursor
          let batch = try await metadatabase.read { db in
            try Row.fetchAll(db, sql: """
              SELECT recordPrimaryKey, recordName, zoneName, ownerName
              FROM sqlitedata_icloud_metadata
              WHERE recordType = ? AND recordPrimaryKey > ? AND _isDeleted = 0
                AND hasLastKnownServerRecord = 1
              ORDER BY recordPrimaryKey LIMIT 100
              """, arguments: [name, position]).map { row -> (String, CKRecord.ID) in
                (row["recordPrimaryKey"], .init(recordName: row["recordName"],
                  zoneID: .init(zoneName: row["zoneName"], ownerName: row["ownerName"])))
              }
          }
          guard let last = batch.last else {
            try await metadatabase.write {
              try $0.execute(sql: "DELETE FROM sqlitedata_icloud_integrityProgress WHERE tableName = ?", arguments: [name])
            }
            return
          }
          let keys = batch.map { $0.0 }
          let existing = try await userDatabase.read { db in
            Set(try String.fetchAll(db, sql: "SELECT CAST(\"\(quotedKey)\" AS TEXT) FROM \"\(quotedTable)\" WHERE \"\(quotedKey)\" IN (\(Array(repeating: "?", count: keys.count).joined(separator: ",")))", arguments: StatementArguments(keys)))
          }
          let missing = batch.filter { !existing.contains($0.0) }.map { $0.1 }
          try await metadatabase.write { db in
            for id in missing {
              try UnsyncedRecordID.insert { UnsyncedRecordID(recordID: id) }
                onConflictDoUpdate: { _ in }.execute(db)
            }
            try db.execute(sql: "INSERT INTO sqlitedata_icloud_integrityProgress(tableName, cursor) VALUES (?, ?) ON CONFLICT(tableName) DO UPDATE SET cursor = excluded.cursor", arguments: [name, last.0])
          }
          queued += missing.count
          cursor = last.0
          await Task.yield()
        }
      }
      try await open(table)
    }
    return queued
  }
}
#endif
