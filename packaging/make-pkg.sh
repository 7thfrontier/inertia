#!/bin/bash
# Build Inertia-Installer.pkg (interactive, welcome + conclusion panes).
# Payload: /Applications/Inertia.app + /Library/LaunchAgents/com.inertia.Inertia.plist
# Optional signing:  INSTALLER_ID="Developer ID Installer: You (TEAMID)" ./packaging/make-pkg.sh
set -e
export COPYFILE_DISABLE=1        # keeps tar from adding AppleDouble entries. Note: the payload still
                                 # carries ._ entries for macOS's unremovable com.apple.provenance xattr;
                                 # the installer restores those as metadata, not as visible files.
cd "$(dirname "$0")/.."          # repo root
APP="Inertia.app"
./build.sh                       # always rebuild: a stale .app from an older main.swift must never ship

# Info.plist is the single source of truth for the version; bump it before every release.
#   CFBundleShortVersionString = semver MAJOR.MINOR.PATCH — the marketing version users and the pkg see.
#     MAJOR breaking change, MINOR new or changed behavior, PATCH bug fixes only.
#     A preferences-key rename counts as MINOR even when migrated, since the stored schema changed.
#   CFBundleVersion = build number, monotonically increasing, never reused. Bump it too, always.
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)

BUILD=$(mktemp -d)
ROOT="$BUILD/root"
mkdir -p "$ROOT/Applications" "$ROOT/Library/LaunchAgents"
cp -R "$APP" "$ROOT/Applications/"
cp packaging/com.inertia.Inertia.plist "$ROOT/Library/LaunchAgents/"

# Pin the app to /Applications (relocatable off) so it can't retarget an old copy elsewhere.
pkgbuild --analyze --root "$ROOT" "$BUILD/component.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$BUILD/component.plist"

pkgbuild --root "$ROOT" --component-plist "$BUILD/component.plist" \
    --scripts packaging/scripts \
    --identifier com.inertia.Inertia --version "$VERSION" \
    --install-location / "$BUILD/component.pkg" >/dev/null

# stamp the app's version into the distribution — pkg-ref line only (the XML declaration
# and minSpecVersion also carry version-shaped attributes and must not be touched)
sed "/pkg-ref/s/version=\"[0-9.]*\"/version=\"$VERSION\"/" packaging/distribution.xml > "$BUILD/distribution.xml"
productbuild --distribution "$BUILD/distribution.xml" \
    --resources packaging/resources --package-path "$BUILD" \
    Inertia-Installer.pkg >/dev/null

if [ -n "$INSTALLER_ID" ]; then
    productsign --sign "$INSTALLER_ID" Inertia-Installer.pkg "$BUILD/signed.pkg"
    mv "$BUILD/signed.pkg" Inertia-Installer.pkg
    echo "Signed with: $INSTALLER_ID"
else
    echo "UNSIGNED — for distribution, run with INSTALLER_ID set (Developer ID Installer) + notarize."
fi
rm -rf "$BUILD"
echo "Built Inertia-Installer.pkg"
