# Security and data safety

Use GitHub's private vulnerability reporting for exploitable issues. Do not put
Apple credentials, session tokens, personal filenames, file contents, or full
runtime logs in a public issue.

The app runs with the logged-in user's permissions and intentionally accesses an
ordinary iCloud Drive folder. It is not sandboxed. The loopback NFS transport is
intended for trusted personal Macs; it is not a security boundary against other
local users. The control API is authenticated, and no endpoint binds to a LAN
address. Apple authentication stays with macOS.

Data-loss bugs in eviction, write staging, path resolution or crash recovery
should be treated as security-sensitive. Unknown or failed safety checks must
block eviction. Local builds are ad-hoc signed, and this release is not notarized.
