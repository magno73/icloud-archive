# Contributing

Read [AGENTS.md](AGENTS.md) and [the architecture](docs/ARCHITECTURE.md) first.
Human contributors and AI coding agents follow the same storage invariants.

Use Swift 6 and run `swift test --disable-xctest`. Changes to the transport also
need `scripts/smoke-mount.sh` on a Mac. Changes to native iCloud behavior need a
small, synthetic round-trip fixture on a signed-in Mac; record exactly what was
tested without publishing private paths, inventories, credentials or logs.

Keep changes focused. Explain the user-visible behavior, the relevant safety
boundary, tests performed, and any untested platform/OS assumptions in the PR.
Comment why a guard or asynchronous boundary exists rather than narrating each
line. UI strings need both English and Italian. Documentation and code comments
are English.

Never introduce a delete fallback for failed eviction. Never erase a staging
cache during recovery. Do not use production user files in automated tests, and
do not add authentication tokens, crash dumps with private filenames, or signing
identities to a commit. All binary bundles and runtime state are gitignored.
