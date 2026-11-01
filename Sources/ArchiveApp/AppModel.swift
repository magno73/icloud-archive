import SwiftUI
import ServiceManagement
import ArchiveCore

enum L {
    static func text(_ english: String, _ italian: String) -> String {
        Locale.preferredLanguages.first?.hasPrefix("it") == true ? italian : english
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var config = Persistence.loadConfiguration()
    @Published var items: [FileSnapshot] = []
    @Published var folder = ""
    @Published var mounted = false
    @Published var busy = false
    @Published var message = ""
    @Published var error: String?
    @Published var lastCleanup: Date?
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    let bridge = VolumeBridge()
    private var store: ArchiveStore!
    private var ownership: InstanceLock?
    private var started = false
    private var timer: Task<Void, Never>?

    var logicalBytes: Int64 { items.filter { !$0.isDirectory }.reduce(0) { $0 + $1.logicalSize } }
    var localBytes: Int64 { items.filter { !$0.isDirectory }.reduce(0) { $0 + $1.allocatedSize } }

    func start() async {
        guard !started else { return }
        started = true
        busy = true
        defer { busy = false }
        do {
            ownership = try InstanceLock()
            store = ArchiveStore(root: config.archiveURL)
            message = L.text("Waiting for iCloud Drive access. Allow access in the macOS permission dialog if asked.",
                             "Accesso a iCloud Drive in corso. Se macOS lo richiede, premi Consenti nella finestra di autorizzazione.")
            try await store.prepareDefaultArchive()
            // Resolve macOS privacy consent before exporting a filesystem.
            // Otherwise NFS clients can block while the OS waits for consent.
            items = try await store.list(folder)
            message = ""
            try Persistence.saveConfiguration(config)
            if config.mountOnLaunch {
                do { try await bridge.start(root: config.archiveURL) }
                catch { self.error = error.localizedDescription }
            }
            if CommandLine.arguments.contains("--enable-login-item") { setLogin(true) }
            await refresh()
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(300))
                    guard !Task.isCancelled, let self else { return }
                    if self.config.automaticEviction && !self.busy { await self.cleanIdle() }
                    await self.refresh()
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func refresh() async {
        guard store != nil else { return }
        do {
            items = try await store.list(folder)
            mounted = VolumeBridge.isMounted(at: Locations.mount)
        } catch { self.error = error.localizedDescription }
    }

    func connect() async {
        guard !busy, ownership != nil else { return }
        busy = true
        defer { busy = false }
        do { try await bridge.start(root: config.archiveURL); await refresh() }
        catch { self.error = error.localizedDescription }
    }

    func disconnect() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { try await bridge.stop(); await refresh() }
        catch { self.error = error.localizedDescription }
    }

    func showVolume() {
        Task {
            if !mounted { await connect() }
            guard mounted else { return }
            await FinderView.openMetadataView(at: Locations.mount)
        }
    }

    func browse(_ path: String) async { folder = path; await refresh() }

    func parent() async {
        folder = folder.split(separator: "/").dropLast().joined(separator: "/")
        await refresh()
    }

    func open(_ item: FileSnapshot) async {
        if item.isDirectory { await browse(item.relativePath); return }
        do {
            try await store.download(item.relativePath)
            // Opening the mounted file lets the native filesystem wait for
            // hydration. No whole-file buffers or duplicate app cache are used.
            let base = mounted ? Locations.mount : config.archiveURL
            NSWorkspace.shared.open(base.appendingPathComponent(item.relativePath))
        } catch { self.error = error.localizedDescription }
        await refresh()
    }

    func download(_ paths: Set<String>) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            for path in paths { try await store.download(path) }
            message = L.text("Download requested. iCloud will transfer the selected files.", "Download richiesto. iCloud trasferirà i file selezionati.")
        } catch { self.error = error.localizedDescription }
        await refresh()
    }

    func release(_ paths: Set<String>) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let pending = await bridge.hasUnsettledWrites()
        let result = await store.evict(Array(paths), idleInterval: nil, pendingWrites: pending,
                                       writeCheck: { [bridge] in await bridge.hasUnsettledWrites() })
        report(result)
        await refresh()
    }

    func cleanIdle() async {
        guard !busy, store != nil else { return }
        busy = true
        defer { busy = false }
        do {
            // A non-empty staging cache blocks the whole sweep. It is usually
            // empty within 90 seconds of a successful write-back.
            guard !(await bridge.hasUnsettledWrites()) else { return }
            let files = try await store.allFiles()
            let result = await store.evict(files.map(\.relativePath), idleInterval: config.idleInterval,
                                           pendingWrites: await bridge.hasUnsettledWrites(),
                                           writeCheck: { [bridge] in await bridge.hasUnsettledWrites() })
            lastCleanup = Date()
            if !result.requested.isEmpty || !result.errors.isEmpty { report(result) }
        } catch { self.error = error.localizedDescription }
    }

    private func report(_ result: EvictionResult) {
        message = L.text(
            "Local removal requested for \(result.requested.count) files; \(result.skipped.count) kept by safety checks.",
            "Rimozione locale richiesta per \(result.requested.count) file; \(result.skipped.count) conservati dai controlli.")
        if !result.errors.isEmpty { error = result.errors.values.sorted().joined(separator: "\n") }
    }

    func saveSettings() {
        do { try Persistence.saveConfiguration(config) }
        catch { self.error = error.localizedDescription }
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
        } catch { self.error = error.localizedDescription }
    }

    func shutdown() async -> Bool {
        guard !busy else {
            error = L.text("An operation is running. Wait for it to finish.", "Un’operazione è in corso. Attendi che termini.")
            return false
        }
        do { try await bridge.stop(); timer?.cancel(); return true }
        catch { self.error = error.localizedDescription; return false }
    }
}
