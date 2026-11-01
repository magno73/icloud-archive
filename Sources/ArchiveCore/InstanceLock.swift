import Foundation
import Darwin

/// Prevent two GUI instances (or a headless mutator and the GUI) from owning
/// the same cache and activity journal. Read-only CLI commands need no lock.
public final class InstanceLock: @unchecked Sendable {
    private let descriptor: Int32
    public init() throws {
        try FileManager.default.createDirectory(at: Locations.support, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        descriptor = Darwin.open(Locations.support.appendingPathComponent("session.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw ArchiveError.unavailable("Could not open the application lock.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw ArchiveError.busy("iCloud Archive is already running. Use its menu, or quit it before running a headless mutation.")
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    }
    deinit { _ = flock(descriptor, LOCK_UN); close(descriptor) }
}
