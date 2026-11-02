#!/usr/bin/env bash
# Packages build/FocusDock.app for a GitHub release: FocusDock.dmg (drag to Applications) and
# FocusDock.zip (for the one-line Terminal install). Run ./scripts/build-app.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/FocusDock.app
[ -d "$APP" ] || { echo "Run ./scripts/build-app.sh first" >&2; exit 1; }

# dmgbuild lays out the disk image window (big icons, an arrow to Applications) without scripting Finder.
VENV=.build/dmgbuild-venv
if [ ! -x "$VENV/bin/dmgbuild" ]; then
    echo "Installing dmgbuild..."
    /usr/bin/python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q --disable-pip-version-check "dmgbuild==1.6.5"
fi

rm -f build/FocusDock.dmg build/FocusDock.zip
"$VENV/bin/dmgbuild" -s scripts/dmg-settings.py -D app="$APP" FocusDock build/FocusDock.dmg >/dev/null
ditto -c -k --keepParent "$APP" build/FocusDock.zip

echo "Built build/FocusDock.dmg and build/FocusDock.zip"
