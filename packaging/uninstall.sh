#!/bin/bash
# Uninstall Inertia: stop it, then remove the app, the LaunchAgent, and the installer receipt.
# Run:  sudo bash /Applications/Inertia.app/Contents/Resources/uninstall.sh
# (also kept at packaging/uninstall.sh in the source tree)
set -e
if [ "$(id -u)" -ne 0 ]; then echo "Run with sudo: sudo bash $0"; exit 1; fi

PLIST="/Library/LaunchAgents/com.inertia.Inertia.plist"
user=$(stat -f%Su /dev/console)
uid=$(id -u "$user" 2>/dev/null || echo "")
if [ -n "$uid" ]; then launchctl bootout "gui/$uid" "$PLIST" 2>/dev/null || true; fi
pkill -x Inertia 2>/dev/null || true

rm -f "$PLIST"
rm -rf /Applications/Inertia.app
pkgutil --forget com.inertia.Inertia 2>/dev/null || true

echo "Inertia is uninstalled."
echo "Optional: remove its entry in System Settings > Privacy & Security > Accessibility."
