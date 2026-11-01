import Foundation
import Darwin

public protocol CloudFileSystem: Sendable {
    func snapshot(_ url: URL, relativePath: String) throws -> FileSnapshot
    func requestDownload(_ url: URL) throws
    func evict(_ url: URL) throws
}

public struct NativeFileSystem: CloudFileSystem {
    public init() {}
    public func snapshot(_ url: URL, relativePath: String) throws -> FileSnapshot {
        // Invalidate Foundation's per-URL cache: stale upload flags are unsafe.
        var fresh = URL(fileURLWithPath: url.path)
        fresh.removeAllCachedResourceValues()
        let values = try fresh.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .isUbiquitousItemKey, .ubiquitousItemIsUploadedKey,
            .ubiquitousItemIsUploadingKey, .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemHasUnresolvedConflictsKey, .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemUploadingErrorKey, .ubiquitousItemDownloadingErrorKey,
        ])
        guard values.isSymbolicLink != true else {
            throw ArchiveError.invalidPath("Symbolic links are not supported.")
        }
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let status: String?
        switch values.ubiquitousItemDownloadingStatus {
        case .current: status = "current"
        case .downloaded: status = "downloaded"
        case .notDownloaded: status = "notDownloaded"
        default: status = nil
        }
        return FileSnapshot(
            relativePath: relativePath, name: url.lastPathComponent,
            isDirectory: values.isDirectory == true,
            logicalSize: Int64(info.st_size), allocatedSize: Int64(info.st_blocks) * 512,
            modifiedAt: date(info.st_mtimespec), accessedAt: date(info.st_atimespec),
            isUbiquitous: values.isUbiquitousItem,
            isUploaded: values.ubiquitousItemIsUploaded,
            isUploading: values.ubiquitousItemIsUploading,
            isDownloading: values.ubiquitousItemIsDownloading,
            hasConflicts: values.ubiquitousItemHasUnresolvedConflicts,
            downloadStatus: status,
            syncError: (values.ubiquitousItemUploadingError ?? values.ubiquitousItemDownloadingError)?.localizedDescription,
            isRegularFile: values.isRegularFile == true, inode: UInt64(info.st_ino)
        )
    }

    public func requestDownload(_ url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    public func evict(_ url: URL) throws {
        // Never substitute removeItem/unlink. Native eviction preserves the
        // cloud object and its placeholder; it can fail while a file is busy.
        try FileManager.default.evictUbiquitousItem(at: url)
    }

    private func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
    }
}
