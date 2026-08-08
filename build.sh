#!/bin/bash
# Assemble Inertia.app (no Xcode). Ad-hoc signs so TCC keeps the Accessibility grant across rebuilds.
set -e
cd "$(dirname "$0")"
APP=Inertia.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp Inertia.icns "$APP/Contents/Resources/Inertia.icns"
cp packaging/uninstall.sh "$APP/Contents/Resources/uninstall.sh"   # every installed copy carries its own uninstaller
# Apple Silicon only (arm64, no universal slice) on macOS 15+. The 15.0 target lets the coast loop
# use CADisplayLink (vsync-paced); binary minOS matches Info.plist. Only long-stable APIs otherwise.
swiftc -O main.swift -o "$APP/Contents/MacOS/Inertia" \
    -target arm64-apple-macos15.0 \
    -framework Cocoa -framework ApplicationServices
codesign --force -s - "$APP"   # ad-hoc; real distribution needs a Developer ID + notarization
echo "Built $APP"
