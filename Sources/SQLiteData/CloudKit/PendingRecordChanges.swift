#if canImport(CloudKit)
public import CloudKit

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
extension SyncEngine {
  /// A read-only snapshot of native pending record changes. Nil means the
  /// engines are not prepared. The engine remains the sole owner of the queue.
  /// Unlike the persistent pending table, this includes changes held in memory.
  public var pendingRecordChanges: [CKSyncEngine.PendingRecordZoneChange]? {
    syncEngines.withValue { engines in
      guard let privateEngine = engines.private, let sharedEngine = engines.shared else { return nil }
      return privateEngine.state.pendingRecordZoneChanges + sharedEngine.state.pendingRecordZoneChanges
    }
  }
}
#endif
