#if canImport(CloudKit)
/// Missing temporary asset files must never become SQL NULL or an empty default.
package struct ImportAssetUnavailable: Error {}
#endif
