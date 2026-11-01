import Foundation

/// Metadata inspection is not use. Only actual access/modify times, explicit
/// downloads, or the transition from placeholder to local data reset the timer.
public struct ActivityLedger: Codable, Sendable {
    public struct Record: Codable, Sendable {
        public var lastUse: Date
        var wasLocal: Bool
        var inode: UInt64
    }
    public private(set) var records: [String: Record] = [:]
    public init() {}

    public mutating func observe(_ file: FileSnapshot, now: Date) {
        guard file.isRegularFile else { return }
        let old = records[file.relativePath]
        var lastUse = old?.lastUse ?? now
        // A new inode or a newly hydrated file receives a full grace period.
        if old?.inode != file.inode || (file.isLocal && old?.wasLocal != true) {
            lastUse = now
        }
        if file.isLocal {
            for event in [file.accessedAt, file.modifiedAt].compactMap({ $0 }) {
                if event > lastUse { lastUse = event }
            }
        }
        records[file.relativePath] = Record(lastUse: lastUse, wasLocal: file.isLocal, inode: file.inode)
    }

    public mutating func markUse(_ path: String, now: Date = Date()) {
        if var record = records[path] {
            record.lastUse = now
            records[path] = record
        } else {
            records[path] = Record(lastUse: now, wasLocal: false, inode: 0)
        }
    }

    public func lastUse(for path: String) -> Date? { records[path]?.lastUse }
}
