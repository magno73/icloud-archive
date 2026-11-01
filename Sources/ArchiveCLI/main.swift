import Foundation
import ArchiveCore
import Darwin

@main
struct ArchiveCLI {
    static func main() async {
        do { try await run(Array(CommandLine.arguments.dropFirst())) }
        catch {
            FileHandle.standardError.write(Data("icloud-archive: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func run(_ arguments: [String]) async throws {
        if arguments.isEmpty || arguments.contains("--help") || arguments.first == "help" {
            print("""
            iCloud Archive — metadata-first storage for macOS

            Usage: icloud-archive <command> [relative-path] [options]

              list [folder]       List metadata only; never download content
              status <file>       Inspect native iCloud state
              download <file>     Ask iCloud to download one file
              evict <file>        Preview safe local eviction (--apply to perform)
              prune               Preview files idle long enough (--apply to perform)
              mount               Connect the Finder disk; keep running until Ctrl-C

            Options:
              --json              Machine-readable JSON output
              --root PATH         Archive directory (defaults to the saved iCloud folder)
              --idle-hours N      Inactivity threshold for prune (minimum 1, default 24)
              --apply             Perform eviction; otherwise no files are changed

            Eviction never deletes the cloud file. Unknown sync states, open
            files and staged writes are always protected. Quit the GUI before
            running headless mutations. No recursive delete command is provided.
            """)
            return
        }
        var config = Persistence.loadConfiguration()
        var positionals: [String] = []
        var json = false
        var apply = false
        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--json": json = true
            case "--apply": apply = true
            case "--root", "--idle-hours":
                let flag = arguments[i]
                i += 1
                guard i < arguments.count else { throw ArchiveError.invalidPath("Missing value for \(flag).") }
                if flag == "--root" { config.archivePath = URL(fileURLWithPath: arguments[i]).resolvingSymlinksInPath().path }
                else {
                    guard let hours = Double(arguments[i]), hours.isFinite, hours >= 1 else {
                        throw ArchiveError.invalidPath("idle-hours must be a finite number of at least 1.")
                    }
                    config.idleHours = hours
                }
            default:
                guard !arguments[i].hasPrefix("--") else { throw ArchiveError.invalidPath("Unknown option \(arguments[i]).") }
                positionals.append(arguments[i])
            }
            i += 1
        }
        guard let command = positionals.first else { return }
        let path = positionals.dropFirst().first ?? ""
        let mutates = command == "mount" || command == "download" || (apply && ["evict", "prune"].contains(command))
        let ownership = mutates ? try InstanceLock() : nil
        defer { withExtendedLifetime(ownership) {} }
        let store = ArchiveStore(root: config.archiveURL, persistActivity: mutates)
        switch command {
        case "list":
            let items = try await store.list(path)
            if json { try emit(items) }
            else {
                for item in items {
                    print("\(item.isDirectory ? "dir" : item.state.rawValue)\t\(item.logicalSize)\t\(item.allocatedSize)\t\(item.name)")
                }
            }
        case "status":
            guard !path.isEmpty else { throw ArchiveError.invalidPath("Specify a relative file path.") }
            try emit(await store.snapshot(path))
        case "download":
            guard !path.isEmpty else { throw ArchiveError.invalidPath("Specify a relative file path.") }
            try await store.download(path)
            try emit(["status": "downloadRequested", "path": path])
        case "evict", "prune":
            let paths: [String]
            if command == "prune" { paths = try await store.allFiles().map(\.relativePath) }
            else {
                guard !path.isEmpty else { throw ArchiveError.invalidPath("Specify one relative file path.") }
                paths = [path]
            }
            // A separate process cannot verify a live helper's write queue.
            // Mutations require the ownership lock; previews stay conservative.
            let pending = VolumeBridge.hasCachedFiles(in: Locations.cache) || VolumeBridge.isMounted(at: Locations.mount)
            let result = await store.evict(paths, idleInterval: command == "prune" ? config.idleInterval : nil,
                                            pendingWrites: pending, dryRun: !apply)
            try emit(result)
        case "mount":
            try await store.prepareDefaultArchive()
            let bridge = VolumeBridge()
            try await bridge.start(root: config.archiveURL)
            print("Mounted at \(Locations.mount.path). Press Ctrl-C to eject safely.")
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            let events = AsyncStream<Void> { continuation in
                interrupt.setEventHandler { continuation.yield(()) }
                terminate.setEventHandler { continuation.yield(()) }
                interrupt.resume(); terminate.resume()
            }
            for await _ in events {
                do { try await bridge.stop(); break }
                catch { FileHandle.standardError.write(Data("\(error.localizedDescription) Try Ctrl-C again after writes finish.\n".utf8)) }
            }
            interrupt.cancel(); terminate.cancel()
        default: throw ArchiveError.invalidPath("Unknown command: \(command). Use --help.")
        }
    }

    static func emit<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
}
