# Verification record

This record distinguishes automated tests from an actual iCloud round trip.
It is not a guarantee that every application, macOS version, or iCloud account
behaves identically. Never run destructive tests against existing user files.

## Local environment

- Date: 2026-11-01.
- Apple Silicon Mac, macOS 27.0.1.
- Swift 6.1.2, Command Line Tools with macOS 15.5 SDK; no full Xcode required.
- rclone 1.75.1; local, ad-hoc signed app bundle.

## Passed

`swift test --disable-xctest`: **18 tests passed**. Coverage includes unknown
iCloud resource flags, uploads/downloads/conflicts/errors, open-file protection,
pending writes, repeated metadata observations, hydration and inode replacement,
inactivity grace periods, JSON journal round trips, symlink/path traversal
rejection, native eviction delegation, and a sync-state change during the
open-file probe. An actual `lsof` probe detects a held handle and its closure.

A sparse **2,000,000,000-byte** local file was inspected repeatedly without
reading its payload, changing its access time, or allocating its logical size.
This tests metadata behavior, not a 2 GB iCloud upload.

`scripts/smoke-mount.sh`: a disposable, non-iCloud NFS volume passed repeated
listing/stat checks without source access-time changes, a **128 MiB** streamed
write/read with matching SHA-256, and rename. The test uses bounded client
buffers; it is not a measurement of peak whole-system memory usage.

The release app and CLI compiled, the helper was embedded, and the bundle passed
`codesign --verify --deep --strict`. Rebuilding an existing bundle was also
checked, including replacement of the initially read-only Homebrew helper.

## Actual iCloud round trip

Only a newly created synthetic text fixture was used; no existing user data was
moved or evicted. The following sequence was observed with native metadata and
the CLI-mounted volume:

1. iCloud reported the fixture uploaded and current: logical size **48,128 B**,
   locally allocated size **49,152 B**.
2. A safe native eviction request completed. The same logical size remained,
   downloading status became `notDownloaded`, allocated bytes became **0**.
3. Repeated listing and `stat` through the mounted NFS volume left the backing
   file at **0 allocated bytes**.
4. Reading the mounted file hydrated it. SHA-256 matched the original payload,
   and native status returned to current/local.

Zero allocated data blocks does not mean zero bytes of filesystem metadata,
nor does it measure APFS snapshots, kernel caches, or unrelated system caches.

## UI and privacy consent

The installed native window was launched and inspected. On first launch, macOS
requested iCloud Drive consent in a system-owned dialog. While consent was
pending, filesystem operations waited; a prematurely mounted NFS volume also
waited. Startup now obtains backing-folder access before mounting and displays
an explanation while waiting. The old test mount was ejected normally.

The settings window was verified with automatic eviction enabled and a 24-hour
interval. Native **Open at login** was enabled and its switch confirmed on.
Full packaged-app interaction after granting iCloud access and Finder window
automation still need an interactive user check. Automated CI cannot validate these OS
prompts or grant access to an Apple account.

## Not yet established

- A continuous 24-hour wall-clock soak test (the interval is tested with supplied
  timestamps, and the production scheduler checks every five minutes).
- Multi-gigabyte real iCloud transfers, quota exhaustion, prolonged offline
  writes, crash/power-loss recovery, or simultaneous edits on another device.
- Intel hardware, every supported macOS version, or all video editors.
- App Store distribution, Developer ID signing, or notarization.

## Reproduce safely

Run deterministic tests and the local mount smoke test first. For an iCloud
check, create one unmistakably disposable fixture in a dedicated archive,
wait for confirmed upload, record logical/allocated sizes, request native
eviction, inspect names/stat, then deliberately read and compare its contents.
Do not use a checksum as a metadata check: hashing reads and downloads content.
Close all handles before testing eviction, and never discard a write cache.
