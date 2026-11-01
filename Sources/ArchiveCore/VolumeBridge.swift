import Foundation
import Darwin

/// rclone translates native NFS into ordinary filesystem operations. It never
/// signs in to Apple: the user's existing macOS iCloud Drive session does that.
public actor VolumeBridge {
    private var process: Process?
    private var controlURL: URL?
    private var password = ""
    public let mountURL: URL
    public let cacheURL: URL

    public init(mountURL: URL = Locations.mount, cacheURL: URL = Locations.cache) {
        self.mountURL = mountURL
        self.cacheURL = cacheURL
    }

    public static func findRclone() -> URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/rclone")
        let candidates = [bundled.path, "/opt/homebrew/bin/rclone", "/usr/local/bin/rclone"]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    public static func isMounted(at url: URL) -> Bool {
        // MNT_NOWAIT inspects the kernel's mount table without touching an
        // unavailable NFS server or blocking the main thread on network I/O.
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard let mounts, count > 0 else { return false }
        let target = url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).path
        for index in 0..<Int(count) {
            var info = mounts[index]
            let path = withUnsafePointer(to: &info.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if path == target { return true }
        }
        return false
    }

    public func start(root: URL) async throws {
        if process?.isRunning == true, Self.isMounted(at: mountURL) { return }
        guard !Self.isMounted(at: mountURL) else {
            throw ArchiveError.busy("An earlier archive volume is still mounted. Eject it in Finder, then reconnect.")
        }
        guard let executable = Self.findRclone() else {
            throw ArchiveError.unavailable("rclone is missing. Install it with ‘brew install rclone’, or use an app bundle containing the helper.")
        }
        _ = try SafePaths.resolve("", under: root)
        let manager = FileManager.default
        try manager.createDirectory(at: mountURL, withIntermediateDirectories: true)
        guard try manager.contentsOfDirectory(atPath: mountURL.path).isEmpty else {
            throw ArchiveError.invalidPath("The mountpoint must be empty. Its existing files will not be changed.")
        }
        try manager.createDirectory(at: cacheURL, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.createDirectory(at: Locations.support, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let port = try Self.availablePort()
        controlURL = URL(string: "http://127.0.0.1:\(port)/")!
        password = UUID().uuidString + UUID().uuidString
        let child = Process()
        child.executableURL = executable
        let logURL = Locations.support.appendingPathComponent("bridge.log")
        child.arguments = [
            "nfsmount", root.path, mountURL.path,
            "--addr", "127.0.0.1:0", "--volname", "iCloud Archive",
            "--config", "/dev/null", "--cache-dir", cacheURL.path,
            "--vfs-cache-mode", "writes", "--vfs-write-back", "5s",
            "--vfs-cache-max-age", "1m", "--vfs-cache-poll-interval", "30s",
            "--buffer-size", "1M", "--vfs-read-chunk-size", "4M",
            "--vfs-read-chunk-size-limit", "4M", "--vfs-read-ahead", "0",
            "--dir-cache-time", "5s", "--attr-timeout", "1s", "--poll-interval", "0",
            "--nfs-cache-handle-limit", "10000",
            "--rc", "--rc-addr", "127.0.0.1:\(port)", "--log-level", "ERROR",
            "--log-file", logURL.path, "--log-file-max-size", "1M", "--log-file-max-backups", "1",
        ]
        // Avoid inheriting unrelated cloud credentials or rclone settings.
        child.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
            "RCLONE_RC_USER": "archive", "RCLONE_RC_PASS": password,
        ]
        if !manager.fileExists(atPath: logURL.path) {
            manager.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.standardInput = FileHandle.nullDevice
        try child.run()
        process = child
        for _ in 0..<100 {
            guard child.isRunning else {
                throw ArchiveError.bridge("The volume helper exited. See bridge.log in the application support folder.")
            }
            if Self.isMounted(at: mountURL) {
                _ = try await stats()
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        if !Self.isMounted(at: mountURL) { child.terminate() }
        throw ArchiveError.bridge("The Finder volume did not mount within 10 seconds.")
    }

    public struct CacheStats: Decodable, Sendable {
        public let bytesUsed: Int64
        public let files: Int
        public let erroredFiles: Int
        public let uploadsInProgress: Int
        public let uploadsQueued: Int
        public let outOfSpace: Bool
        public var hasUnsettledWrites: Bool {
            // Waiting for a *completely empty* write cache is conservative:
            // even recently committed staging files get their cleanup minute.
            files > 0 || erroredFiles > 0 || uploadsInProgress > 0 || uploadsQueued > 0 || outOfSpace
        }
    }

    private struct Stats: Decodable { let diskCache: CacheStats }

    public func stats() async throws -> CacheStats {
        guard let controlURL, process?.isRunning == true else {
            throw ArchiveError.bridge("The volume helper is not running.")
        }
        var request = URLRequest(url: controlURL.appendingPathComponent("vfs/stats"))
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic " + Data("archive:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 3
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ArchiveError.bridge("Could not verify the write cache.")
        }
        return try JSONDecoder().decode(Stats.self, from: data).diskCache
    }

    public func hasUnsettledWrites() async -> Bool {
        if process?.isRunning == true {
            do { return try await stats().hasUnsettledWrites } catch { return true }
        }
        return Self.hasCachedFiles(in: cacheURL)
    }

    public static func hasCachedFiles(in directory: URL) -> Bool {
        // After a crash, only the helper may interpret/replay cached writes.
        // Any remaining payload blocks eviction; never purge this directory.
        let payload = directory.appendingPathComponent("vfs")
        guard FileManager.default.fileExists(atPath: payload.path) else { return false }
        guard let e = FileManager.default.enumerator(at: payload,
            includingPropertiesForKeys: [.isRegularFileKey], errorHandler: { _, _ in false }) else { return true }
        for case let url as URL in e {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else { return true }
            if values.isRegularFile == true { return true }
        }
        return false
    }

    public func stop() async throws {
        if Self.isMounted(at: mountURL) {
            // Never force an unmount: active editors and pending writes matter.
            if await hasUnsettledWrites() {
                throw ArchiveError.busy("Writes are still staged. Wait for them to finish before ejecting or quitting.")
            }
            let result = try await ProcessRunner.run("/sbin/umount", [mountURL.path])
            guard result.status == 0 else { throw ArchiveError.busy("Close files using the archive, then try ejecting again.") }
        }
        if let process, process.isRunning {
            process.terminate()
            for _ in 0..<30 where process.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        }
        self.process = nil
        controlURL = nil
        password = ""
    }

    private static func availablePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ArchiveError.bridge("Cannot allocate a local port.") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw ArchiveError.bridge("Cannot bind a local port.") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard status == 0 else { throw ArchiveError.bridge("Cannot read the local port.") }
        return UInt16(bigEndian: address.sin_port)
    }
}
