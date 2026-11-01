# Architecture and invariants

## Boundaries

| Component | Responsibility |
| --- | --- |
| `ArchiveCore` | Metadata snapshots, inactivity journal, eviction policy, path validation, native iCloud adapter, bridge lifecycle |
| `ArchiveApp` | SwiftUI window and menu bar, preferences, login item, five-minute scheduler |
| `ArchiveCLI` | Metadata-only inspection and explicit headless commands, JSON output |
| rclone | Loopback NFS translation and durable write staging; no Apple authentication |
| macOS | NFS client, on-demand iCloud hydration, sync, native eviction and placeholders |

Swift was chosen for direct Foundation, SwiftUI and ServiceManagement integration.
Network and storage dominate the workload. The application does not implement a
new filesystem protocol, buffer whole videos, or encode user data.

## Storage locations

- Cloud-backed files: `~/Library/Mobile Documents/com~apple~CloudDocs/iCloud Archive`
- Finder mountpoint: `~/iCloud Archive` (must be empty before mounting)
- Configuration/activity/diagnostics: `~/Library/Application Support/iCloud Archive`
- Durable staging: `~/Library/Application Support/iCloud Archive/WriteCache`

Activity journals are keyed by a digest of the archive root. They contain local
relative paths, inodes and timestamps; they are private runtime state and must
never be committed. JSON writes are atomic and mode 0600. The runtime directory
is private to the user. Read-only CLI operations do not need the GUI ownership
lock; mutations do. Neither process ever reads an Apple password.

## Metadata versus data

`NativeFileSystem.snapshot` uses URL resource values plus `lstat`. It does not
open the file, hash it, generate a thumbnail, or request hydration. Logical size
comes from `st_size`; allocation is `st_blocks * 512`, which may include filesystem
overhead and is not a promise about every APFS snapshot/system cache.

`list` updates observations without refreshing last-use time. Atime/mtime changes
count as content activity. A new inode, first observation or cloud-only -> local
transition receives a fresh grace period. Future timestamps postpone eviction.
Unknown fields remain optional; do not coalesce unknown to a safe value.

NFS serves filesystem metadata without touching contents. Thumbnail generation,
Quick Look, `file`, checksums and embedded media metadata are real data reads.
They are not distinguishable from a user's read at the filesystem boundary.

## Eviction transaction

1. Validate root-relative path, refusing symlinks and traversal.
2. Read current iCloud state and content-use timestamps.
3. Check regular-file status, confirmed upload, no conflict/error/in-flight sync,
   inactivity, and an empty write cache.
4. Run a bounded `lsof` probe against backing and mounted paths. A failure is
   “unknown”, never “closed”.
5. Recheck the bridge write cache, resolve the path and read native state again.
   Refuse if the file was replaced or became ineligible during the probe.
6. Call `FileManager.evictUbiquitousItem(at:)` for that individual file.

Do not wrap native eviction in a coordinated write: Apple's API documents that
it performs its own coordination. This is a best-effort policy for a trusted
user environment, not a sandbox against malicious same-user filesystem races.
Native iCloud remains the authority on whether eviction is possible.

There is deliberately no filesystem delete/trash operation in the eviction path.
The normal writable Finder volume still supports normal filesystem deletion;
that is a distinct, user-initiated cloud deletion, documented in the UI/README.

## Mount and cache lifecycle

The app starts `rclone nfsmount` with an isolated configuration and a sanitized
environment. NFS and the control API bind to 127.0.0.1. Control credentials are
random per run and passed in the child environment, never on the command line.
The NFS endpoint itself relies on the trusted local-machine environment.

Read caching is off (`writes`, not `full`). Write staging supports editors and
non-sequential writes. The helper has a five-second write-back delay, one-minute
clean-cache age and thirty-second cleanup interval. Dirty or errored writes
must never be removed to save space. The policy waits for an entirely empty
write cache before evicting anything, favoring safety over aggressive cleanup.

Normal quit refuses to stop with staged writes. It uses non-forced `umount` and
only then terminates its own helper process. It never kills a process by a stale
PID. A crash can leave a helper or mount; recovery must preserve the cache. There
is no privileged daemon, kernel extension or modification to `/etc/hosts`.

The kernel mount table is inspected with `getmntinfo(MNT_NOWAIT)` so an unavailable
NFS server cannot block the menu UI merely while determining mount state.

## Extension points

- `CloudFileSystem` is injected for deterministic race/safety tests.
- `EvictionPolicy` is a pure, fail-closed decision function.
- `ActivityLedger` is independent of UI, network and clocks supplied by tests.
- `ArchiveStore` serializes its own state with a Swift actor.
- `VolumeBridge` contains helper details, so a future native File Provider or
  different transport does not need to weaken storage policy.

Before adding a new backend or protocol, preserve metadata-only operations,
bounded memory, crash-safe staging, and proof of remote upload before eviction.
