#!/bin/bash
# Real NFS integration, isolated from iCloud. Cleanup never force-unmounts or
# removes the temp tree while mounted. A failing test leaves data for inspection.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
command -v rclone >/dev/null
probe_dir=$(mktemp -d /tmp/icloud-archive-smoke.XXXXXX)
mkdir "$probe_dir/data" "$probe_dir/mount" "$probe_dir/cache"
bridge_pid=""
cleanup() {
    if mount | grep -F " on $probe_dir/mount " >/dev/null || mount | grep -F " on /private$probe_dir/mount " >/dev/null; then
        if ! umount "$probe_dir/mount"; then
            echo "Mount is busy. Test data retained at $probe_dir; eject it manually." >&2
            return
        fi
    fi
    if [[ -n "$bridge_pid" ]] && kill -0 "$bridge_pid" 2>/dev/null; then kill -TERM "$bridge_pid"; fi
    # Only this script's unpredictable temporary directory is eligible.
    case "$probe_dir" in /tmp/icloud-archive-smoke.*) rm -rf "$probe_dir" ;; esac
}
trap cleanup EXIT
printf 'metadata fixture\n' > "$probe_dir/data/sample.txt"
rclone nfsmount "$probe_dir/data" "$probe_dir/mount" \
    --addr 127.0.0.1:0 --config /dev/null --cache-dir "$probe_dir/cache" \
    --vfs-cache-mode writes --vfs-write-back 1s --buffer-size 1M \
    --dir-cache-time 1s --poll-interval 0 --log-level ERROR \
    > "$probe_dir/bridge.log" 2>&1 &
bridge_pid=$!
for attempt in $(seq 1 100); do
    if [[ -f "$probe_dir/mount/sample.txt" ]]; then break; fi
    if ! kill -0 "$bridge_pid" 2>/dev/null; then cat "$probe_dir/bridge.log"; exit 1; fi
    sleep 0.1
done
python3 - "$probe_dir" <<'PY'
from pathlib import Path
import hashlib, os, sys, time
root = Path(sys.argv[1])
source = root / 'data/sample.txt'
volume = root / 'mount/sample.txt'
before = source.stat().st_atime_ns
for _ in range(20):
    list((root / 'mount').iterdir())
    assert volume.stat().st_size == source.stat().st_size
assert source.stat().st_atime_ns == before, 'Listing/stat read the source contents'
assert volume.read_bytes() == b'metadata fixture\n'

# Stream 128 MiB through the mounted volume with constant client memory.
block = bytes(range(256)) * 4096
expected = hashlib.sha256()
with (root / 'mount/large.bin').open('wb') as output:
    for _ in range(128):
        output.write(block)
        expected.update(block)
backing = root / 'data/large.bin'
for _ in range(200):
    if backing.exists() and backing.stat().st_size == 128 * len(block): break
    time.sleep(0.1)
assert backing.exists(), 'Write-back did not reach the backing folder'
with (root / 'mount/large.bin').open('rb') as stream:
    actual = hashlib.file_digest(stream, 'sha256').hexdigest()
assert actual == expected.hexdigest(), 'Mounted read did not preserve the payload'
(root / 'mount/large.bin').rename(root / 'mount/renamed.bin')
assert (root / 'mount/renamed.bin').stat().st_size == 128 * len(block)
print('PASS: metadata-only listing/stat, 128 MiB streamed write/read SHA-256, rename')
PY
