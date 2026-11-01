import Foundation

public enum ArchiveError: Error, LocalizedError, Sendable {
    case invalidPath(String)
    case unavailable(String)
    case bridge(String)
    case busy(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let s), .unavailable(let s), .bridge(let s), .busy(let s): s
        }
    }
}

public struct ArchiveConfiguration: Codable, Sendable {
    public var archivePath: String
    public var idleHours: Double
    public var automaticEviction: Bool
    public var mountOnLaunch: Bool

    public init(archivePath: String = Locations.defaultArchive.path,
                idleHours: Double = 24, automaticEviction: Bool = true,
                mountOnLaunch: Bool = true) {
        self.archivePath = archivePath
        self.idleHours = idleHours
        self.automaticEviction = automaticEviction
        self.mountOnLaunch = mountOnLaunch
    }

    public var archiveURL: URL { URL(fileURLWithPath: archivePath, isDirectory: true) }
    public var idleInterval: TimeInterval { max(1, idleHours) * 3600 }
}

public enum Locations {
    public static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/iCloud Archive", isDirectory: true)
    }
    public static var defaultArchive: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/iCloud Archive", isDirectory: true)
    }
    // A user-owned mountpoint avoids sudo and remains addressable from Terminal.
    public static var mount: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("iCloud Archive", isDirectory: true)
    }
    public static var cache: URL { support.appendingPathComponent("WriteCache", isDirectory: true) }
    public static var settings: URL { support.appendingPathComponent("settings.json") }
    public static var activity: URL { support.appendingPathComponent("activity.json") }
}

public enum CloudState: String, Codable, Sendable {
    case cloudOnly, downloaded, uploading, downloading, conflict, error, unconfirmed
}

/// All fields come from filesystem metadata. Constructing this value must not
/// open the data fork: doing so would hydrate an otherwise cloud-only item.
public struct FileSnapshot: Codable, Sendable, Identifiable {
    public var id: String { relativePath }
    public var relativePath: String
    public var name: String
    public var isDirectory: Bool
    public var logicalSize: Int64
    public var allocatedSize: Int64
    public var modifiedAt: Date?
    public var accessedAt: Date?
    public var isUbiquitous: Bool?
    public var isUploaded: Bool?
    public var isUploading: Bool?
    public var isDownloading: Bool?
    public var hasConflicts: Bool?
    public var downloadStatus: String?
    public var syncError: String?
    public var isRegularFile: Bool
    public var inode: UInt64

    public var isLocal: Bool { downloadStatus == "current" || downloadStatus == "downloaded" }
    public var state: CloudState {
        if syncError != nil { return .error }
        if hasConflicts == true { return .conflict }
        if isUploading == true { return .uploading }
        if isDownloading == true { return .downloading }
        if isUbiquitous == true && downloadStatus == "notDownloaded" { return .cloudOnly }
        if isLocal && isUploaded == true { return .downloaded }
        return .unconfirmed
    }
}

public struct EvictionResult: Codable, Sendable {
    public var requested: [String] = []
    public var skipped: [String: String] = [:]
    public var errors: [String: String] = [:]
    public var requestedBytes: Int64 = 0
    public init() {}
}

public enum OpenFileStatus: Sendable { case closed, open, unknown }

public enum EvictionPolicy {
    /// Fail closed. In particular `nil` is not interchangeable with `false`:
    /// iCloud can temporarily stop supplying resource keys during account changes.
    public static func refusal(for file: FileSnapshot, lastUse: Date?, now: Date,
                               idleInterval: TimeInterval?, open: OpenFileStatus,
                               pendingWrites: Bool) -> String? {
        if !file.isRegularFile || file.isDirectory { return "notRegularFile" }
        if file.isUbiquitous != true { return "notConfirmedICloud" }
        if file.syncError != nil { return "syncError" }
        if file.hasConflicts != false { return "conflictOrUnknown" }
        if file.isUploaded != true || file.isUploading != false { return "uploadNotConfirmed" }
        if file.isDownloading != false { return "downloadActiveOrUnknown" }
        if !file.isLocal { return "alreadyCloudOnlyOrUnknown" }
        if pendingWrites { return "pendingWrites" }
        switch open {
        case .open: return "fileInUse"
        case .unknown: return "openFileCheckFailed"
        case .closed: break
        }
        if let interval = idleInterval {
            guard let lastUse else { return "activityUnknown" }
            if now.timeIntervalSince(lastUse) < interval { return "recentlyUsed" }
        }
        return nil
    }
}
