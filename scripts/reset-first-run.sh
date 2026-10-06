#!/bin/bash
# Replay Inertia's first-run flow without reinstalling anything.
#
#   ./scripts/reset-first-run.sh                the ⌃⌘ gesture hint comes back
#   ./scripts/reset-first-run.sh --permission   ...and so does the "Grant Accessibility Access" CTA
#
# Those are exactly the two first-run states the panel can show (see layoutContents: no trust -> CTA,
# trusted but never thrown -> hint), so the two modes here map onto them one for one.
#
# Deliberately leaves your sliders, shortcut, and Preview state alone. The panel's own Reset button
# already restores those, and settings tuned by feel are the one thing here that's expensive to recreate.
set -e
BUNDLE=com.7thfrontier.Inertia

# Relaunch whichever copy was running, not whichever one LaunchServices happens to prefer. During
# development the installed /Applications copy and the repo build are different binaries, and reviving
# the wrong one silently tests the wrong code.
APP=""
PID=$(pgrep -x Inertia | head -1)
[ -n "$PID" ] && APP=$(ps -o comm= -p "$PID" | sed 's|/Contents/MacOS/Inertia$||')

pkill -x Inertia 2>/dev/null || true      # prefs must change with the app down: a live copy caches them
for _ in $(seq 1 20); do pgrep -x Inertia >/dev/null 2>&1 || break; sleep 0.1; done

defaults delete "$BUNDLE" hasThrown 2>/dev/null || true   # delete, not "false" — a new user has no such key
echo "Cleared hasThrown; the gesture hint will show again."

if [ "$1" = "--permission" ]; then
    # Always scoped to our bundle id. A bare `tccutil reset Accessibility` revokes EVERY app's grant.
    tccutil reset Accessibility "$BUNDLE" >/dev/null
    echo "Revoked Accessibility; macOS will prompt again and the panel will show the CTA."
    echo "You will have to re-tick Inertia in System Settings > Privacy & Security > Accessibility."
fi

if [ -z "$APP" ]; then
    cd "$(dirname "$0")/.."
    if [ -d /Applications/Inertia.app ]; then APP=/Applications/Inertia.app; else APP="$PWD/Inertia.app"; fi
fi
[ -d "$APP" ] || { echo "No Inertia.app to relaunch; run ./build.sh first."; exit 1; }
open -a "$APP"
echo "Relaunched $APP"
