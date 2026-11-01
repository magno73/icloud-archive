import AppKit
import ArchiveCore

enum FinderView {
    /// Configure this archive window, not the user's global Finder preferences.
    /// Apple Events permission is optional: a denied request falls back to an
    /// ordinary open and the UI documents how to disable previews manually.
    @MainActor static func openMetadataView(at url: URL) async {
        let script = """
        on run argv
            tell application "Finder"
                set archiveFolder to folder (POSIX file (item 1 of argv) as alias)
                set archiveWindow to container window of archiveFolder
                set current view of archiveWindow to list view
                set shows icon preview of list view options of archiveWindow to false
                set shows icon preview of icon view options of archiveWindow to false
                set shows icon preview of column view options of archiveWindow to false
                set shows preview column of column view options of archiveWindow to false
                set discloses preview pane of column view options of archiveWindow to false
                open archiveFolder
                activate
            end tell
        end run
        """
        do {
            let result = try await ProcessRunner.run("/usr/bin/osascript", ["-e", script, url.path], timeout: 30)
            if result.status != 0 { NSWorkspace.shared.open(url) }
        } catch { NSWorkspace.shared.open(url) }
    }
}
