import SwiftUI
import ArchiveCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await AppModel.shared.start() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            let safe = await AppModel.shared.shutdown()
            if !safe { NSApp.activate(ignoringOtherApps: true) }
            sender.reply(toApplicationShouldTerminate: safe)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct iCloudArchiveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("iCloud Archive", id: "archive") {
            ArchiveWindow(model: model)
                .frame(minWidth: 760, minHeight: 500)
        }
        .defaultSize(width: 960, height: 650)
        .windowToolbarStyle(.unified)
        MenuBarExtra("iCloud Archive", systemImage: "externaldrive.badge.icloud") {
            ArchiveMenu(model: model)
        }
        Settings { PreferencesView(model: model) }
    }
}

struct ArchiveMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.mounted ? L.text("Archive connected", "Archivio connesso") : L.text("Archive disconnected", "Archivio disconnesso"))
        Button(L.text("Open archive", "Apri archivio")) {
            openWindow(id: "archive")
            NSApp.activate(ignoringOtherApps: true)
        }.keyboardShortcut("o")
        Button(L.text("Show disk in Finder", "Mostra disco nel Finder")) { model.showVolume() }
        Divider()
        Button(L.text("Release inactive files now", "Libera i file inattivi adesso")) { Task { await model.cleanIdle(); await model.refresh() } }
            .disabled(model.busy)
        Text(L.text("Automatic release: \(Int(model.config.idleHours)) hours", "Rilascio automatico: \(Int(model.config.idleHours)) ore"))
        Divider()
        SettingsLink { Text(L.text("Settings…", "Impostazioni…")) }
        Button(model.mounted ? L.text("Eject disk", "Espelli disco") : L.text("Connect disk", "Collega disco")) {
            Task { if model.mounted { await model.disconnect() } else { await model.connect() } }
        }.disabled(model.busy)
        Button(L.text("Quit", "Esci")) { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct ArchiveWindow: View {
    @ObservedObject var model: AppModel
    @State private var selection = Set<String>()
    @State private var search = ""

    private var filtered: [FileSnapshot] {
        search.isEmpty ? model.items : model.items.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 18) {
                Image(systemName: "externaldrive.badge.icloud")
                    .font(.system(size: 42, weight: .light)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 5) {
                    Text("iCloud Archive").font(.largeTitle.bold())
                    Text(L.text("All your files. Local only when you need them.", "Tutti i tuoi file. Sul Mac solo quando servono."))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(model.mounted ? L.text("Connected", "Connesso") : L.text("Disconnected", "Disconnesso"),
                      systemImage: model.mounted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(model.mounted ? .teal : .secondary)
                    .padding(10).background(.quaternary, in: Capsule())
            }.padding(24)

            HStack(spacing: 14) {
                MetricCard(title: L.text("Files in this folder", "File nella cartella"), value: "\(model.items.filter { !$0.isDirectory }.count)")
                MetricCard(title: L.text("Logical size", "Dimensione logica"), value: bytes(model.logicalBytes))
                MetricCard(title: L.text("Allocated on this Mac", "Allocati su questo Mac"), value: bytes(model.localBytes))
            }.padding(.horizontal, 24).padding(.bottom, 20)

            HStack {
                Button { Task { await model.parent(); selection.removeAll() } } label: { Image(systemName: "chevron.left") }
                    .disabled(model.folder.isEmpty)
                Text(model.folder.isEmpty ? L.text("Archive", "Archivio") : "Archive / " + model.folder)
                    .font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help(L.text("Refresh metadata only", "Aggiorna solo i metadati"))
            }.padding(.horizontal, 24).padding(.bottom, 12)

            Table(filtered, selection: $selection) {
                TableColumn(L.text("Name", "Nome")) { item in
                    HStack {
                        Image(systemName: item.isDirectory ? "folder.fill" : "doc").foregroundStyle(item.isDirectory ? .teal : .secondary)
                        Text(item.name).lineLimit(1)
                    }.onTapGesture(count: 2) { Task { await model.open(item) } }
                }.width(min: 180, ideal: 300)
                TableColumn(L.text("Size", "Dimensione")) { item in Text(item.isDirectory ? "—" : bytes(item.logicalSize)).monospacedDigit() }
                    .width(min: 80, ideal: 100)
                TableColumn(L.text("On Mac", "Sul Mac")) { item in Text(item.isDirectory ? "—" : bytes(item.allocatedSize)).monospacedDigit() }
                    .width(min: 80, ideal: 100)
                TableColumn(L.text("iCloud status", "Stato iCloud")) { item in
                    Text(item.isDirectory ? "—" : stateLabel(item.state)).foregroundStyle(item.state == .cloudOnly ? .teal : .secondary)
                }.width(min: 110, ideal: 145)
                TableColumn(L.text("Modified", "Modificato")) { item in
                    if let date = item.modifiedAt { Text(date, format: .dateTime.day().month().year()).foregroundStyle(.secondary) }
                }.width(min: 95, ideal: 110)
            }
            .overlay {
                if model.items.isEmpty {
                    ContentUnavailableView {
                        Label(L.text("Room for your next project", "Spazio per il prossimo progetto"), systemImage: "icloud.and.arrow.up")
                    } description: {
                        Text(L.text("Open the disk in Finder and drag in your files. Their names remain visible after local copies are released.",
                                    "Apri il disco nel Finder e trascina i tuoi file. I nomi restano visibili anche dopo il rilascio delle copie locali."))
                    } actions: { Button(L.text("Open disk in Finder", "Apri disco nel Finder")) { model.showVolume() } }
                }
            }
            HStack {
                Label(L.text("Metadata browsing does not download file contents.", "Consultare i metadati non scarica il contenuto."), systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L.text("Download", "Scarica")) { Task { await model.download(selection) } }
                    .disabled(selection.isEmpty || model.busy)
                Button(L.text("Free local space", "Libera spazio locale")) { Task { await model.release(selection) } }
                    .disabled(selection.isEmpty || model.busy)
            }.padding(16)
            if !model.message.isEmpty {
                Text(model.message).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
        .searchable(text: $search, prompt: L.text("Search this folder", "Cerca nella cartella"))
        .toolbar {
            ToolbarItem { Button { model.showVolume() } label: { Label("Finder", systemImage: "folder") } }
            ToolbarItem { SettingsLink { Image(systemName: "gearshape") } }
        }
        .alert(L.text("Archive notice", "Avviso archivio"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .task { await model.start(); await model.refresh() }
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
    private func stateLabel(_ state: CloudState) -> String {
        switch state {
        case .cloudOnly: L.text("Only in iCloud", "Solo su iCloud")
        case .downloaded: L.text("On Mac + iCloud", "Su Mac e iCloud")
        case .uploading: L.text("Uploading", "Caricamento")
        case .downloading: L.text("Downloading", "Download")
        case .conflict: L.text("Conflict", "Conflitto")
        case .error: L.text("Sync error", "Errore sincronizzazione")
        case .unconfirmed: L.text("Awaiting iCloud", "In attesa di iCloud")
        }
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct PreferencesView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section(L.text("Storage", "Archiviazione")) {
                Toggle(L.text("Automatically free inactive files", "Libera automaticamente i file inattivi"), isOn: $model.config.automaticEviction)
                Picker(L.text("After inactivity of", "Dopo un’inattività di"), selection: $model.config.idleHours) {
                    ForEach([1.0, 6, 24, 72, 168], id: \.self) { hours in Text("\(Int(hours)) " + L.text("hours", "ore")).tag(hours) }
                }.disabled(!model.config.automaticEviction)
                Text(L.text("Only uploaded, closed files are eligible. Names, dates and sizes remain available. Checks run every five minutes while the app is open.",
                            "Solo i file caricati e chiusi possono essere rimossi localmente. Nomi, date e dimensioni restano disponibili. L’app controlla ogni cinque minuti mentre è aperta."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L.text("Availability", "Disponibilità")) {
                Toggle(L.text("Connect disk when the app starts", "Collega il disco all’avvio dell’app"), isOn: $model.config.mountOnLaunch)
                Toggle(L.text("Open at login", "Apri al login"), isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
            }
            Section(L.text("Locations", "Posizioni")) {
                LabeledContent("iCloud Drive") { Text(model.config.archivePath).font(.caption).textSelection(.enabled) }
                LabeledContent(L.text("Terminal path", "Percorso terminale")) { Text(Locations.mount.path).font(.caption).textSelection(.enabled) }
                Button(L.text("Show original iCloud folder", "Mostra cartella iCloud originale")) { NSWorkspace.shared.open(model.config.archiveURL) }
            }
            Section {
                Text(L.text("Finder previews and Quick Look read content and may download a file. Turn off icon previews and the preview pane for metadata-only browsing. Deleting from the disk also deletes from iCloud; use Free local space to retain the cloud file.",
                            "Anteprime del Finder e Visualizzazione rapida leggono il contenuto e possono scaricare un file. Disattiva anteprime icone e pannello anteprima per consultare solo i metadati. Eliminare dal disco elimina anche da iCloud; usa Libera spazio locale per conservare il file sul cloud."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).frame(width: 560, height: 570)
        .onChange(of: model.config.idleHours) { model.saveSettings() }
        .onChange(of: model.config.automaticEviction) { model.saveSettings() }
        .onChange(of: model.config.mountOnLaunch) { model.saveSettings() }
    }
}
