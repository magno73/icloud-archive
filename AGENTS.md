# Working on iCloud Archive

Read `README.md` and `docs/ARCHITECTURE.md` before changing storage behavior.
This is a native macOS Swift application. `ArchiveCore` owns the filesystem
policy; `ArchiveApp` owns SwiftUI and lifecycle; `ArchiveCLI` is the headless,
JSON-capable interface. rclone supplies a loopback NFS bridge, not cloud auth.

## Non-negotiable data invariants

- A directory listing, `stat`, or UI refresh must never read file contents,
  calculate a content hash, request a download, or refresh content-use time.
- Local eviction means `FileManager.evictUbiquitousItem(at:)`. Never implement
  space reclamation with unlink, `removeItem`, trash, or an rclone delete.
- Unknown sync state, upload errors, conflicts, active downloads, pending
  writes, open files, or failed open-file checks must prevent eviction.
- Immediately recheck iCloud metadata before each eviction. Never trust the
  status displayed earlier in the UI. Do not evict entire directories.
- Stay inside the configured archive. Reject symlinks and path traversal.
- No destructive tests on a developer's existing iCloud data. Use temporary
  directories, injected filesystem adapters, or explicitly created fixtures.
- Keep read caching off in the bridge. The write cache is a durable staging
  area: never purge it to recover space or discard failed/queued writes.
- Never log or commit Apple credentials, user file names, local inventories,
  runtime state, signing material, or authentication tokens.

## Development

- `swift test --disable-xctest` runs deterministic policy and filesystem tests.
- `scripts/build-app.sh` builds the native app and CLI and embeds a locally
  installed rclone. It uses ad-hoc signing unless a signing identity is supplied.
- `scripts/smoke-mount.sh` tests the actual Finder-compatible NFS bridge using
  disposable files. It never uses iCloud or needs administrator privileges.
- Keep UI work on the main actor; scans and process I/O belong off it. Use
  streaming I/O, bounded logs, and metadata-only enumeration for large files.
- Comment *why* a storage guard exists. Keep documentation in English and UI
  strings in the small English/Italian localization table.
- Update the architecture, limitations, and verification notes when behavior
  changes. Do not claim real iCloud round trips unless they were performed.
- AI agents must not publish releases, push changes, change login items, or
  migrate user files without task authorization. The initial project request
  explicitly authorizes creating and publishing this repository.
