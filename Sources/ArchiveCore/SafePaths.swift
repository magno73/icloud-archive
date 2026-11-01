import Foundation

public enum SafePaths {
    /// Component-by-component checks prevent traversal and symlink escapes.
    /// This app is not a sandbox against a malicious process running as its user;
    /// the check is repeated immediately before every native eviction call.
    public static func resolve(_ relative: String, under root: URL) throws -> URL {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.hasPrefix("/"), !relative.contains("\0"),
              !components.contains(".."), !components.contains(".") else {
            throw ArchiveError.invalidPath("The path must stay inside the archive.")
        }
        let base = root.standardizedFileURL
        guard base.resolvingSymlinksInPath().path == base.path else {
            throw ArchiveError.invalidPath("The archive root must not contain symbolic links.")
        }
        var current = base
        for component in components where !component.isEmpty {
            current.appendPathComponent(String(component))
            let attrs = try FileManager.default.attributesOfItem(atPath: current.path)
            if attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                throw ArchiveError.invalidPath("Symbolic links are not archived or evicted.")
            }
        }
        return current
    }

    public static func relative(_ url: URL, under root: URL) throws -> String {
        let path = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        guard path == base || path.hasPrefix(base + "/") else {
            throw ArchiveError.invalidPath("The item is outside the configured archive.")
        }
        return path == base ? "" : String(path.dropFirst(base.count + 1))
    }
}
