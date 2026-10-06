#!/bin/bash
# Assemble Inertia.app (no Xcode). Ad-hoc signs so TCC keeps the Accessibility grant across rebuilds.
set -e
cd "$(dirname "$0")"
APP=Inertia.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp Inertia.icns "$APP/Contents/Resources/Inertia.icns"
# Apple Silicon only (arm64, no universal slice) on macOS 15+. The 15.0 target lets the coast loop
# use CADisplayLink (vsync-paced); binary minOS matches Info.plist. Only long-stable APIs otherwise.
swiftc -O main.swift -o "$APP/Contents/MacOS/Inertia" \
    -target arm64-apple-macos15.0 \
    -framework Cocoa -framework ApplicationServices
codesign --force -s - "$APP"   # ad-hoc; real distribution needs a Developer ID + notarization
"$APP/Contents/MacOS/Inertia" --selftest   # physics, glyph, panel, and version checks; a failure fails the build
ditto -c -k --keepParent "$APP" Inertia.zip   # release asset; ditto keeps the signature intact
echo "Built $APP and Inertia.zip"
