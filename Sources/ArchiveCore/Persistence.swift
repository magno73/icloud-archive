import Foundation

public enum Persistence {
    public static func loadConfiguration() -> ArchiveConfiguration {
        guard let data = try? Data(contentsOf: Locations.settings),
              let config = try? JSONDecoder().decode(ArchiveConfiguration.self, from: data),
              config.idleHours.isFinite, config.idleHours >= 1 else { return .init() }
        return config
    }

    public static func saveConfiguration(_ value: ArchiveConfiguration) throws {
        try save(value, to: Locations.settings)
    }

    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
