#!/usr/bin/env bash
# Builds FocusDock.app into ./build
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Building for production..."
swift build -c release

APP=build/FocusDock.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/FocusDock" "$APP/Contents/MacOS/FocusDock"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# llama.cpp's llama-server, which runs the embedding model for the reaction memory. A pinned release
# build, checked against its published SHA-256; only the server and the libraries it loads are copied.
LLAMA_TAG=b12038
LLAMA_SHA256=29edaa4ede66b305c080dad0856724d527c0161c94b9326d38a0b305ca747322
LLAMA_TGZ=".build/llama/llama-$LLAMA_TAG-bin-macos-arm64.tar.gz"
if [ ! -f "$LLAMA_TGZ" ] || [ "$(shasum -a 256 "$LLAMA_TGZ" | cut -d' ' -f1)" != "$LLAMA_SHA256" ]; then
    echo "Fetching llama.cpp $LLAMA_TAG..."
    mkdir -p .build/llama
    curl -fsSL -o "$LLAMA_TGZ" \
        "https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_TAG/llama-$LLAMA_TAG-bin-macos-arm64.tar.gz"
fi
if [ "$(shasum -a 256 "$LLAMA_TGZ" | cut -d' ' -f1)" != "$LLAMA_SHA256" ]; then
    echo "llama.cpp download doesn't match the pinned SHA-256" >&2
    exit 1
fi
LLAMA_SRC=".build/llama/llama-$LLAMA_TAG"
[ -d "$LLAMA_SRC" ] || tar -xzf "$LLAMA_TGZ" -C .build/llama
mkdir -p "$APP/Contents/Resources/llama"
# llama-server plus every @rpath library it pulls in, transitively (symlinks resolved to real files).
todo="llama-server"; done_list=""
while [ -n "$todo" ]; do
    set -- $todo; f=$1; shift; todo="$*"
    case " $done_list " in *" $f "*) continue ;; esac
    done_list="$done_list $f"
    cp -L "$LLAMA_SRC/$f" "$APP/Contents/Resources/llama/$f"
    for dep in $(otool -L "$LLAMA_SRC/$f" | awk 'NR > 1 && $1 ~ /^@rpath\// { sub("@rpath/", "", $1); print $1 }'); do
        todo="$todo $dep"
    done
done
cp "$LLAMA_SRC/LICENSE" "$APP/Contents/Resources/llama/LICENSE"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>FocusDock</string>
    <key>CFBundleDisplayName</key><string>FocusDock</string>
    <key>CFBundleIdentifier</key><string>com.focusdock.app</string>
    <key>CFBundleExecutable</key><string>FocusDock</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>FocusDock reads the current browser tab so it can tell which mode a website belongs to, and sends you back when you choose Stay.</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS remembers the Automation permission between launches.
codesign --force --deep --sign - "$APP" >/dev/null

echo "Build complete!"
echo "Built $APP"
