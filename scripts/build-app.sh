#!/bin/bash
# Build locally without an Xcode project, Apple account, or downloaded binaries.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

install_app=false
launch_app=false
for arg in "$@"; do
    case "$arg" in
        --install) install_app=true ;;
        --launch) install_app=true; launch_app=true ;;
        *) echo "Usage: scripts/build-app.sh [--install] [--launch]" >&2; exit 2 ;;
    esac
done

rclone_path="${RCLONE_BINARY:-$(command -v rclone || true)}"
if [[ ! -x "$rclone_path" ]]; then
    echo "Install rclone first: brew install rclone" >&2
    exit 1
fi
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
bundle="$project_dir/dist/iCloud Archive.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$bundle/Contents/Helpers"
cp "$binary_dir/iCloudArchive" "$bundle/Contents/MacOS/iCloudArchive"
cp "$binary_dir/icloud-archive" "$bundle/Contents/MacOS/icloud-archive"
# Homebrew installs read-only executables. Make our previous build artifact
# writable before replacing it; never modify the package manager's binary.
if [[ -f "$bundle/Contents/Helpers/rclone" ]]; then
    chmod u+w "$bundle/Contents/Helpers/rclone"
fi
cp -L "$rclone_path" "$bundle/Contents/Helpers/rclone"
chmod 755 "$bundle/Contents/Helpers/rclone"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
cp LICENSE "$bundle/Contents/Resources/LICENSE"
cp Resources/THIRD-PARTY-NOTICES.txt "$bundle/Contents/Resources/THIRD-PARTY-NOTICES.txt"
xcrun swift scripts/generate-icon.swift "$project_dir/dist/AppIcon.iconset"
iconutil -c icns "$project_dir/dist/AppIcon.iconset" -o "$bundle/Contents/Resources/AppIcon.icns"

# Ad-hoc signing permits local execution. Public notarized distribution requires
# the maintainer's own Developer ID identity; never commit signing credentials.
identity="${SIGNING_IDENTITY:--}"
codesign --force --sign "$identity" "$bundle/Contents/Helpers/rclone"
codesign --force --sign "$identity" "$bundle/Contents/MacOS/icloud-archive"
codesign --force --sign "$identity" "$bundle"
codesign --verify --deep --strict "$bundle"

if $install_app; then
    destination="$HOME/Applications/iCloud Archive.app"
    if pgrep -x iCloudArchive >/dev/null; then
        echo "Quit iCloud Archive before replacing its app bundle." >&2
        exit 1
    fi
    mkdir -p "$HOME/Applications"
    ditto "$bundle" "$destination"
    echo "Installed: $destination"
    if $launch_app; then open "$destination"; fi
else
    echo "Built: $bundle"
fi
