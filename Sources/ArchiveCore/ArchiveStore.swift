import Foundation
import CryptoKit

public actor ArchiveStore {
    public let root: URL
    private let fileSystem: any CloudFileSystem
    private let ledgerURL: URL?
    private var ledger: ActivityLedger

    public init(root: URL, fileSystem: any CloudFileSystem = NativeFileSystem(),
                persistActivity: Bool = true) {
        self.root = root.standardizedFileURL
        self.fileSystem = fileSystem
        let digest = SHA256.hash(data: Data(self.root.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let savedURL = Locations.support.appendingPathComponent("activity-\(digest.prefix(16)).json")
        ledgerURL = persistActivity ? savedURL : nil
        // Read-only CLI previews share existing observations without writing
        // them back or competing with the GUI's journal ownership.
        if let data = try? Data(contentsOf: savedURL),
           let saved = try? JSONDecoder().decode(ActivityLedger.self, from: data) {
            ledger = saved
        } else {
            // Missing/corrupt activity state grants a fresh grace period.
            ledger = ActivityLedger()
        }
    }

    public func prepareDefaultArchive() throws {
        let parent = root.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else {
            throw ArchiveError.unavailable("Enable iCloud Drive in System Settings before creating the archive.")
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw ArchiveError.invalidPath("The archive path already exists and is not a directory.") }
        } else {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }
        _ = try SafePaths.resolve("", under: root)
    }

    public func list(_ folder: String = "") throws -> [FileSnapshot] {
        let directory = try SafePaths.resolve(folder, under: root)
        let children = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles])
        var items: [FileSnapshot] = []
        for url in children {
            let relative = try SafePaths.relative(url, under: root)
            guard (try? SafePaths.resolve(relative, under: root)) != nil else { continue }
            let item = try fileSystem.snapshot(url, relativePath: relative)
            ledger.observe(item, now: Date())
            items.append(item)
        }
        try saveLedger()
        return items.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public func snapshot(_ path: String) throws -> FileSnapshot {
        let url = try SafePaths.resolve(path, under: root)
        let file = try fileSystem.snapshot(url, relativePath: path)
        ledger.observe(file, now: Date())
        return file
    }

    public func download(_ path: String) throws {
        let url = try SafePaths.resolve(path, under: root)
        let item = try fileSystem.snapshot(url, relativePath: path)
        guard !item.isDirectory, item.isUbiquitous == true else {
            throw ArchiveError.unavailable("Select an individual file confirmed to be in iCloud.")
        }
        ledger.markUse(path)
        try saveLedger()
        try fileSystem.requestDownload(url)
    }

    public func lastUse(_ path: String) -> Date? { ledger.lastUse(for: path) }

    /// Enumeration reads attributes only. Directories/symlinks/hidden control
    /// files are never evicted as units: each regular file gets its own guards.
    public func allFiles(limit: Int = 100_000) throws -> [FileSnapshot] {
        _ = try SafePaths.resolve("", under: root)
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var result: [FileSnapshot] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let relative = try SafePaths.relative(url, under: root)
            guard (try? SafePaths.resolve(relative, under: root)) != nil else {
                enumerator.skipDescendants()
                continue
            }
            let item = try fileSystem.snapshot(url, relativePath: relative)
            if item.isRegularFile {
                ledger.observe(item, now: Date())
                result.append(item)
                if result.count >= limit { break }
            }
        }
        try saveLedger()
        return result
    }

    /// The callback checks both the native archive path and the mounted path.
    /// It is injectable so tests can prove fail-closed behavior without iCloud.
    public func evict(_ paths: [String], idleInterval: TimeInterval?, pendingWrites: Bool,
                      dryRun: Bool = false,
                      writeCheck: (@Sendable () async -> Bool)? = nil,
                      openCheck: @Sendable (URL, String) async -> OpenFileStatus = { url, path in
                          var urls = [url]
                          if VolumeBridge.isMounted(at: Locations.mount) {
                              urls.append(Locations.mount.appendingPathComponent(path))
                          }
                          return await OpenFileProbe.check(urls)
                      }) async -> EvictionResult {
        var result = EvictionResult()
        for path in paths {
            do {
                try Task.checkCancellation()
                let url = try SafePaths.resolve(path, under: root)
                let first = try fileSystem.snapshot(url, relativePath: path)
                ledger.observe(first, now: Date())
                // Avoid expensive lsof calls for clearly ineligible files.
                if let reason = EvictionPolicy.refusal(for: first, lastUse: ledger.lastUse(for: path),
                    now: Date(), idleInterval: idleInterval, open: .closed, pendingWrites: pendingWrites) {
                    result.skipped[path] = reason
                    continue
                }
                let open = await openCheck(url, path)
                // Long editing sessions can outlive the idle interval. Give a
                // recently observed open file a new interval after it closes,
                // even if reads were served from the kernel's page cache.
                if case .open = open { ledger.markUse(path) }
                let currentWrites = if let writeCheck { await writeCheck() } else { pendingWrites }
                // Actor reentrancy and filesystem writers can change state
                // while lsof runs. Resolve and inspect the file again now.
                let checkedURL = try SafePaths.resolve(path, under: root)
                let latest = try fileSystem.snapshot(checkedURL, relativePath: path)
                ledger.observe(latest, now: Date())
                if latest.inode != first.inode {
                    result.skipped[path] = "fileReplaced"
                    continue
                }
                if let reason = EvictionPolicy.refusal(for: latest, lastUse: ledger.lastUse(for: path),
                    now: Date(), idleInterval: idleInterval, open: open, pendingWrites: currentWrites) {
                    result.skipped[path] = reason
                    continue
                }
                if !dryRun { try fileSystem.evict(checkedURL) }
                result.requested.append(path)
                result.requestedBytes += latest.allocatedSize
            } catch { result.errors[path] = error.localizedDescription }
        }
        do { try saveLedger() } catch { result.errors["activity"] = error.localizedDescription }
        return result
    }

    private func saveLedger() throws {
        if let ledgerURL { try Persistence.save(ledger, to: ledgerURL) }
    }
}
