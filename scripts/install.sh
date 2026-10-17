#!/usr/bin/env bash
# Copies the released app to /Applications and enables "start at login".
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/release/export/SonosBar.app
[ -d "$APP" ] || { echo "run scripts/release.sh first"; exit 1; }
pkill -x SonosBar || true
rm -rf /Applications/SonosBar.app
cp -R "$APP" /Applications/
open /Applications/SonosBar.app --args --register-login-item
echo "✓ /Applications/SonosBar.app (Autostart an)"
