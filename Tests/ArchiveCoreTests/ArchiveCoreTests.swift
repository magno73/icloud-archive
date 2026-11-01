import Testing
import Foundation
@testable import ArchiveCore

private func uploadedFile(path: String = "video.mov", now: Date = Date(timeIntervalSince1970: 1000)) -> FileSnapshot {
    FileSnapshot(relativePath: path, name: URL(fileURLWithPath: path).lastPathComponent,
        isDirectory: false, logicalSize: 4096, allocatedSize: 4096,
        modifiedAt: now, accessedAt: now, isUbiquitous: true, isUploaded: true,
        isUploading: false, isDownloading: false, hasConflicts: false,
        downloadStatus: "current", syncError: nil, isRegularFile: true, inode: 123)
}

struct EvictionPolicyTests {
    let now = Date(timeIntervalSince1970: 200_000)
    func refusal(_ file: FileSnapshot, lastUse: Date? = Date(timeIntervalSince1970: 1000),
                 open: OpenFileStatus = .closed, pending: Bool = false) -> String? {
        EvictionPolicy.refusal(for: file, lastUse: lastUse, now: now,
                               idleInterval: 86400, open: open, pendingWrites: pending)
    }
    @Test func testConfirmedClosedIdleFileIsEligible() {
        expectNil(refusal(uploadedFile()))
    }
    @Test func testEveryUnknownOrUnsafeCloudFlagBlocksEviction() {
        let changes: [(inout FileSnapshot) -> Void] = [
            { $0.isUbiquitous = nil }, { $0.isUbiquitous = false },
            { $0.isUploaded = nil }, { $0.isUploaded = false },
            { $0.isUploading = nil }, { $0.isUploading = true },
            { $0.isDownloading = nil }, { $0.isDownloading = true },
            { $0.hasConflicts = nil }, { $0.hasConflicts = true },
            { $0.syncError = "quota exceeded" }, { $0.downloadStatus = nil },
            { $0.downloadStatus = "notDownloaded" }, { $0.isRegularFile = false },
            { $0.isDirectory = true },
        ]
        for change in changes {
            var file = uploadedFile(); change(&file)
            expectNotNil(refusal(file))
        }
    }
    @Test func testActivityAndStagedWritesAreProtected() {
        expectEqual(refusal(uploadedFile(), open: .open), "fileInUse")
        expectEqual(refusal(uploadedFile(), open: .unknown), "openFileCheckFailed")
        expectEqual(refusal(uploadedFile(), pending: true), "pendingWrites")
        expectEqual(refusal(uploadedFile(), lastUse: nil), "activityUnknown")
        expectEqual(refusal(uploadedFile(), lastUse: now), "recentlyUsed")
        expectEqual(refusal(uploadedFile(), lastUse: now.addingTimeInterval(10000)), "recentlyUsed")
    }
    @Test func testManualEvictionStillRequiresCloudAndOpenFileGuards() {
        expectNil(EvictionPolicy.refusal(for: uploadedFile(), lastUse: now, now: now,
            idleInterval: nil, open: .closed, pendingWrites: false))
        expectEqual(EvictionPolicy.refusal(for: uploadedFile(), lastUse: now, now: now,
            idleInterval: nil, open: .open, pendingWrites: false), "fileInUse")
    }
}

struct ActivityLedgerTests {
    @Test func testRepeatedMetadataObservationsDoNotExtendTheTimer() {
        var ledger = ActivityLedger()
        let file = uploadedFile()
        let firstSeen = Date(timeIntervalSince1970: 5000)
        ledger.observe(file, now: firstSeen)
        for day in 1...10 { ledger.observe(file, now: firstSeen.addingTimeInterval(Double(day) * 86400)) }
        expectEqual(ledger.lastUse(for: file.relativePath), firstSeen)
    }
    @Test func testContentReadAndWriteExtendTimer() {
        var ledger = ActivityLedger(); var file = uploadedFile()
        ledger.observe(file, now: Date(timeIntervalSince1970: 5000))
        file.accessedAt = Date(timeIntervalSince1970: 10000)
        ledger.observe(file, now: Date(timeIntervalSince1970: 20000))
        expectEqual(ledger.lastUse(for: file.relativePath), file.accessedAt)
        file.modifiedAt = Date(timeIntervalSince1970: 30000)
        ledger.observe(file, now: Date(timeIntervalSince1970: 40000))
        expectEqual(ledger.lastUse(for: file.relativePath), file.modifiedAt)
    }
    @Test func testHydrationAndReplacementReceiveFreshGracePeriod() {
        var ledger = ActivityLedger(); var file = uploadedFile()
        file.downloadStatus = "notDownloaded"
        ledger.observe(file, now: Date(timeIntervalSince1970: 5000))
        file.downloadStatus = "current"
        ledger.observe(file, now: Date(timeIntervalSince1970: 10000))
        expectEqual(ledger.lastUse(for: file.relativePath), Date(timeIntervalSince1970: 10000))
        file.inode = 999
        ledger.observe(file, now: Date(timeIntervalSince1970: 20000))
        expectEqual(ledger.lastUse(for: file.relativePath), Date(timeIntervalSince1970: 20000))
    }
    @Test func testJournalRoundTripPreservesLastContentUse() throws {
        var ledger = ActivityLedger()
        ledger.observe(uploadedFile(), now: Date(timeIntervalSince1970: 5000))
        let restored = try JSONDecoder().decode(ActivityLedger.self, from: JSONEncoder().encode(ledger))
        expectEqual(restored.lastUse(for: "video.mov"), Date(timeIntervalSince1970: 5000))
    }
}

struct SafePathTests {
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @Test func testRejectsTraversalAbsolutePathsAndSymlinks() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for bad in ["../outside", "/etc/passwd", "a/../outside", "./file", "bad\0path"] {
            expectThrows(try SafePaths.resolve(bad, under: root))
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: root.deletingLastPathComponent())
        expectThrows(try SafePaths.resolve("escape", under: root))
        expectThrows(try SafePaths.relative(root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-other/file"), under: root))
    }
    @Test func testOrdinaryUnicodeAndShellCharactersAreLiteralNames() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "Città $(nothing) 'video'.mov"
        let file = root.appendingPathComponent(name)
        try Data("test".utf8).write(to: file)
        expectEqual(try SafePaths.resolve(name, under: root), file)
    }
}

struct NativeMetadataTests {
    @Test func testInspectingLargeSparseFileDoesNotReadContentsOrChangeAtime() throws {
        let root = try SafePathTests().temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("large-video.mov")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 2_000_000_000)
        try handle.close()
        let fs = NativeFileSystem()
        let before = try fs.snapshot(url, relativePath: "large-video.mov")
        for _ in 0..<20 {
            let snapshot = try fs.snapshot(url, relativePath: "large-video.mov")
            expectEqual(snapshot.logicalSize, 2_000_000_000)
            expectEqual(snapshot.accessedAt, before.accessedAt)
            expectLessThan(snapshot.allocatedSize, 100_000)
        }
    }
}

private final class FakeFileSystem: CloudFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [FileSnapshot]
    private var evictions: [String] = []
    init(_ snapshots: [FileSnapshot]) { self.snapshots = snapshots }
    func snapshot(_ url: URL, relativePath: String) throws -> FileSnapshot {
        lock.lock(); defer { lock.unlock() }
        let value = snapshots[0]
        if snapshots.count > 1 { snapshots.removeFirst() }
        return value
    }
    func requestDownload(_ url: URL) throws {}
    func evict(_ url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        evictions.append(url.path)
    }
    var evictionCount: Int { lock.lock(); defer { lock.unlock() }; return evictions.count }
}

struct ArchiveStoreTests {
    @Test func testPreparingAnExistingArchivePreservesItsFiles() async throws {
        let root = try makeFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ArchiveStore(root: root, persistActivity: false)
        try await store.prepareDefaultArchive()
        try await store.prepareDefaultArchive()
        expectTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("video.mov").path))
    }

    func makeFixture() throws -> URL {
        let root = try SafePathTests().temporaryDirectory()
        try Data("fixture".utf8).write(to: root.appendingPathComponent("video.mov"))
        return root
    }
    @Test func testRechecksCloudStatusAfterOpenFileProbe() async throws {
        let root = try makeFixture(); defer { try? FileManager.default.removeItem(at: root) }
        var changed = uploadedFile(); changed.isUploading = true
        let fake = FakeFileSystem([uploadedFile(), changed])
        let store = ArchiveStore(root: root, fileSystem: fake, persistActivity: false)
        let result = await store.evict(["video.mov"], idleInterval: nil, pendingWrites: false, openCheck: { _, _ in .closed })
        expectEqual(fake.evictionCount, 0)
        expectEqual(result.skipped["video.mov"], "uploadNotConfirmed")
        expectTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("video.mov").path))
    }
    @Test func testDryRunAndBusyFilesNeverCallEviction() async throws {
        let root = try makeFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeFileSystem([uploadedFile()])
        let store = ArchiveStore(root: root, fileSystem: fake, persistActivity: false)
        let preview = await store.evict(["video.mov"], idleInterval: nil, pendingWrites: false, dryRun: true, openCheck: { _, _ in .closed })
        expectEqual(preview.requested, ["video.mov"])
        expectEqual(fake.evictionCount, 0)
        _ = await store.evict(["video.mov"], idleInterval: nil, pendingWrites: false, openCheck: { _, _ in .open })
        expectEqual(fake.evictionCount, 0)
    }
    @Test func testConfirmedEvictionDelegatesToNativeAdapterWithoutDeletingFile() async throws {
        let root = try makeFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeFileSystem([uploadedFile()])
        let store = ArchiveStore(root: root, fileSystem: fake, persistActivity: false)
        let result = await store.evict(["video.mov"], idleInterval: nil, pendingWrites: false, openCheck: { _, _ in .closed })
        expectEqual(fake.evictionCount, 1)
        expectEqual(result.requested, ["video.mov"])
        expectTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("video.mov").path))
    }
    @Test func testNewlyDiscoveredLocalFileGetsFullInactivityGracePeriod() async throws {
        let root = try makeFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeFileSystem([uploadedFile()])
        let store = ArchiveStore(root: root, fileSystem: fake, persistActivity: false)
        let result = await store.evict(["video.mov"], idleInterval: 86400, pendingWrites: false, openCheck: { _, _ in .closed })
        expectEqual(fake.evictionCount, 0)
        expectEqual(result.skipped["video.mov"], "recentlyUsed")
    }
    @Test func testRealOpenFileProbeDetectsHeldHandle() async throws {
        let root = try makeFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("video.mov")
        let handle = try FileHandle(forReadingFrom: url)
        let status = await OpenFileProbe.check([url])
        if case .open = status {} else { Issue.record("An open fixture must be protected.") }
        try handle.close()
        let closed = await OpenFileProbe.check([url])
        if case .closed = closed {} else { Issue.record("The closed fixture should have no open handles.") }
    }

    @Test func testAnObservedOpenFileReceivesGraceAfterClosing() async throws {
        let root = try makeFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeFileSystem([uploadedFile()])
        let store = ArchiveStore(root: root, fileSystem: fake, persistActivity: false)
        _ = try await store.snapshot("video.mov")
        let initial = try #require(await store.lastUse("video.mov"))
        // Separate first discovery from the open-handle observation, so this
        // regression test cannot pass merely because discovery grants grace.
        try await Task.sleep(for: .milliseconds(20))
        let before = Date()
        _ = await store.evict(["video.mov"], idleInterval: nil, pendingWrites: false,
                              openCheck: { _, _ in .open })
        let lastUse = try #require(await store.lastUse("video.mov"))
        #expect(lastUse > initial)
        #expect(lastUse >= before)
        let result = await store.evict(["video.mov"], idleInterval: 86400, pendingWrites: false,
                                       openCheck: { _, _ in .closed })
        #expect(result.skipped["video.mov"] == "recentlyUsed")
        #expect(fake.evictionCount == 0)
    }
}

// Small assertion helpers keep repeated policy matrices readable while retaining
// the original call site's location in Swift Testing failure reports.
private func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(lhs == rhs, sourceLocation: sourceLocation)
}
private func expectNil<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(value == nil, sourceLocation: sourceLocation)
}
private func expectNotNil<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(value != nil, sourceLocation: sourceLocation)
}
private func expectTrue(_ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(value, sourceLocation: sourceLocation)
}
private func expectLessThan<T: Comparable>(_ lhs: T, _ rhs: T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(lhs < rhs, sourceLocation: sourceLocation)
}
private func expectThrows<T>(_ expression: @autoclosure () throws -> T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(throws: (any Error).self, sourceLocation: sourceLocation) { _ = try expression() }
}
