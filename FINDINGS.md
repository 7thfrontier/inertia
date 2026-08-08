# Inertia — Exploratory Findings

macOS window "throw" utility (maintain size + momentum). Built on macOS 26 Tahoe, Swift 6.1.

Compatibility: Apple Silicon only (arm64, no universal slice), deployment target macOS 15.0 (binary
`minos` matches `Info.plist`). Uses only
long-stable AppKit / CoreGraphics / ApplicationServices APIs plus CADisplayLink (macOS 14+) for the
coast — no deprecated or private calls, clean compile with no deprecation warnings, so it stays
forward-compatible through macOS 27. One soft spot: the Accessibility-pane deep-link URL scheme can
change between OS releases; if it ever stops resolving, `NSWorkspace.open` just no-ops and the
permission prompt + polling still work.

## 1. Core tech: GREEN LIGHT (measured, not guessed)

AX `kAXPositionAttribute` repositioning of *other apps'* windows is fast. Ran `spike2`
(120 sets/app against live windows). Original fear was a 30–60fps ceiling — wrong by 1–2 orders.

| App | ms/set | max fps |
|---|---|---|
| Brave (Chromium) | 0.09 | 11,602 |
| Mail | 0.10 | 9,898 |
| Finder | 0.29 | 3,434 |
| Terminal | 0.35 | 2,829 |
| Safari (worst) | 1.83 | 546 |

Worst case is still ~9x the 60fps budget. Electron/Chromium is the *fastest*, not the problem.
=> Per-frame physics repositioning via public AX API is smooth. No private APIs / no SIP-off needed.

Known AX limits (not blockers, just scope): can't move fullscreen/native-tiled windows.

## 2. Distribution: the "no user interaction" goal has a hard wall

Accessibility permission (TCC) **cannot be granted by a pkg** on a normal consumer Mac.
- No public API grants AX; `AXIsProcessTrustedWithOptions` only *prompts*.
- TCC.db is SIP-protected — even root pkg scripts can't write it.
- Only zero-touch path: **MDM + PPPC profile** (enterprise/supervised Macs only).

So the user must toggle Accessibility **once** on first launch — same as Rectangle/yabai/every WM.
That is the single unavoidable interaction unless deploying via MDM.

## What a signed+notarized pkg CAN do with zero extra clicks
- Double-click install (needs Apple Developer ID $99/yr to sign+notarize; else Gatekeeper friction).
- Install a LaunchAgent → app auto-starts at login.
- First-run window that deep-links straight to the Accessibility pane
  (`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`).

## 3. Grab-time targeting: PROVEN

`spike3` resolves a raw screen point -> the movable `AXUIElement` window under it
(`AXUIElementCopyElementAtPosition` on the system-wide element, walk up parents to `kAXWindowRole`).
Tested: cursor over a Terminal text area -> correctly resolved app+title+position of its window.
This is all a throw needs: at mouse-down, resolve + cache the handle, then coast it.

ponytail: spike3's Cocoa->CG y-flip uses per-screen height; correct for the focused screen but
multi-monitor global CG space needs the main-screen flip. Refine when adding multi-display support.

## Decision: CONSUMER, ONE TOGGLE (chosen)
Signed+notarized pkg + LaunchAgent auto-start + first-run screen deep-linking the Accessibility pane.
One unavoidable click. (MDM/PPPC zero-touch path declined — enterprise only.)

## Verdict: core tech fully de-risked. The remaining work was engineering, not research.
At the feasibility handoff the open items were CGEventTap drag capture, the physics loop, edge
bounce, the menu-bar shell, the permission flow, and packaging. All are built now (see §4, §5; the
coast runs on a 120Hz Timer, not CVDisplayLink). The one external dependency: an Apple Developer ID
($99/yr) for a frictionless signed+notarized install.

## 4. MVP built: Inertia.app (menu-bar accessory)

`main.swift` + `Info.plist` + `build.sh` -> `Inertia.app`. ⌃⌘ + drag any window, flick, release
-> it coasts with decaying momentum and bounces off screen edges, keeping its size.
- CGEventTap (session, default) swallows ⌃⌘ mouse-down/drag/up; velocity via EMA of drag deltas.
- Coast: CADisplayLink (vsync-paced, macOS 14+), `coastStep()` pure physics (exp decay tau=0.22s, restitution 0.35).
- First-run: AX trust check -> system prompt + deep-link to the Accessibility pane; polls until granted.
- Menu bar (`LSUIElement`, no dock icon), ad-hoc signed. Clicking the status item opens a designed
  NSPopover panel (`FlippedView`/`HeaderView`), rebuilt each open so its height/state are always right:
  gradient header → live physics preview → activation picker → grouped sliders → footer. Verified light
  + dark offscreen (PDF), both permission states.
- Permission: when Accessibility is missing, a clickable amber CTA banner deep-links the pane; it
  vanishes entirely once granted (no status text when all is well).
- Activation shortcut: any modifier combination, stored as raw flags. A preset row (⌃⌘/⌥⌘/⌃⌥/⇧⌘) plus
  a click-based ⌃ ⌥ ⇧ ⌘ toggle row (`.selectAny` segmented) to compose any combo. Replaced an earlier
  keyboard "recorder" (local `flagsChanged` monitor) that was unreliable in the popover and could
  leave a stale monitor that overwrote the saved shortcut — clicks are reliable, no capture needed.
- Live preview (`PreviewStrip`, the delight/overdrive piece): a little window glyph thrown with the
  real `coastStep` engine and the user's current values, CADisplayLink-driven, running only while the
  popover is open — tuning a slider visibly changes the coast/bounce.
- Settings (UserDefaults, live): Coast length / Bounciness / Throw strength (Motion) + Min throw speed
  / Stop speed (Sensitivity).
- Panel gotcha (caught in preview): macOS 14+ views don't clip to bounds by default, so the header's
  near-horizontal gradient bled over the whole panel until an explicit `ctx.clip(to: bounds)`.
- Safety gotcha (live bug — "lost mouse control after revoking access"): the real root cause is that
  the `.defaultTap` callback calls `windowUnder()` → `AXUIElementCopyElementAtPosition`, a **synchronous
  AX IPC call that can block**. When access is revoked it can hang inside the tap callback, freezing the
  whole input stream (and stalling the reconciler timer meant to remove the tap). Fixes, layered:
  (1) `AXUIElementSetMessagingTimeout` — 0.1s global + 0.05s on the tap-path system-wide element — so no
  AX call can ever hang the callback; (2) a 0.5s reconciler that installs the tap on grant and tears it
  down (disable + invalidate port + remove source) on revoke; (3) the callback re-checks
  `AXIsProcessTrusted()` before swallowing and won't re-arm a disabled tap while untrusted. The first
  is the load-bearing fix — without it a blocked callback prevents its own cleanup.
- Recorder gotcha (found from a live bug report): the `flagsChanged` monitor's closure didn't check
  `recording` and wasn't always torn down, so a stale monitor kept capturing later modifier presses and
  silently overwrote the saved shortcut ("resets after a few seconds"). Fix: guard the closure on
  `recording` (self-heals), tear the monitor down on start/rebuild/commit, and `NSApp.activate()` on
  open so key capture + clicks are reliable. Preview launch velocity is now `travel/tau` (crosses and
  bounces) instead of a fixed small value that barely moved.

Verified: builds clean, `--selftest` physics passes, bundle + signature + plist valid.

**First-run flow, walked end to end (2026-07-29).** Closes the human smoke test this section used to
list as outstanding. Method: install the pkg, then `packaging/reset-first-run.sh --permission` to
revoke Accessibility and clear `hasThrown`, putting the app in the state a brand-new user meets.
Results, all as designed:
- The system prompt appears, and the panel's deep-linked CTA opens Privacy & Security > Accessibility.
- After a revoke, Inertia is listed there **already present but unticked** — a plain toggle re-grants
  it, no `-`/`+` remove-and-re-add needed. So the CTA alone is sufficient; no extra instructions.
- The 0.5s reconciler picked up the new grant **live, with no relaunch** (same PID throughout). First
  proof of that timer against a real TCC change rather than a simulated one.
- `hasThrown` flipped to 1 on the first throw, which exercises the whole chain at once: grant -> tap
  armed -> gesture recognized -> grab engaged -> flick over threshold -> coast. Both onboarding states
  then retired themselves in order (CTA, then gesture hint).

Still unverified: a genuinely clean machine (fresh user account or VM) — this test reused a Mac that
had granted Accessibility before, so it proves the revoke/re-grant path, not the never-granted one.

### Run / test
    ./build.sh && open Inertia.app          # grant Accessibility when prompted, then ⌃⌘-drag a window
    ./Inertia.app/Contents/MacOS/Inertia --selftest    # physics check, no GUI

## 5. Installer + auto-start: BUILT

`packaging/make-pkg.sh` -> `Inertia-Installer.pkg` (interactive: welcome + conclusion panes via
`productbuild`/`distribution.xml`). Payload installs `/Applications/Inertia.app` (pinned,
non-relocatable) + `/Library/LaunchAgents/com.inertia.Inertia.plist` (RunAtLoad, Aqua-only, no
KeepAlive). `postinstall` bootstraps the agent into the active GUI session so it starts immediately;
it also auto-loads at every login. Verified by expanding the pkg (payload, script, panes all present).

Install / test locally (unsigned -> Gatekeeper needs right-click Open, or run from terminal):
    ./packaging/make-pkg.sh
    sudo installer -pkg Inertia-Installer.pkg -target /     # or right-click the .pkg > Open

### Left for public distribution (only signing remains — no unknowns)
Sign the app with a Developer-ID Application cert + the pkg with a Developer-ID Installer cert
(`INSTALLER_ID=... ./packaging/make-pkg.sh`), then notarize + staple. Needs an Apple Developer
account ($99/yr). Optional polish: multi-monitor y-flip (§3).

## 6. Polish pass

- Over-engineering audit (ponytail ultra): app code was already lean; cut only regenerable build
  artifacts (compiled spike binaries, stray `.app`/`.pkg`) and added `.gitignore`. Spike sources kept
  as the reproducible evidence behind §1–3.
- License: proprietary, © 2026 7th Frontier, Inc. `LICENSE` file + `NSHumanReadableCopyright` + source
  header. All rights reserved.
- User-facing text (avoid-ai-writing): removed em-dash-as-separator from the installer panes and the
  menu title; fixed the stale icon reference; corrected this log's stale "left to build" section.
- Icons: `art/makeicons.swift` renders `Inertia.icns` — a window thrown right with motion-blur speed
  trails on an indigo→azure gradient. Menu-bar glyph drawn in-code as a template image (light/dark tint).
  Welcome pane shows the app icon.
- macOS 27 forward-compat: only long-stable AppKit/CG/AX APIs, no deprecation warnings, deployment
  target pinned to 15.0 (see the Compatibility note up top). Dropping <15 let the coast switch from a
  fixed 120Hz Timer to a vsync-paced CADisplayLink: ~half the AX writes on 60Hz displays, correct
  120Hz pacing on ProMotion.

## Files
- `main.swift` — the app: menu-bar controller, physics, CGEventTap, in-code menu-bar icon.
- `build.sh` — assemble + ad-hoc sign `Inertia.app` (deployment target macOS 15.0, arm64).
- `Info.plist` / `Inertia.icns` — bundle metadata + app icon.
- `packaging/` — `make-pkg.sh`, `distribution.xml`, LaunchAgent plist, `postinstall`, welcome/conclusion
  panes, `uninstall.sh` (also shipped inside the bundle), `reset-first-run.sh` (dev-only, not shipped).
- `art/makeicons.swift` — regenerates `Inertia.icns`.
- `LICENSE` — proprietary, © 7th Frontier, Inc.
- `spike{,2,3}.swift` — feasibility benchmarks (evidence for §1–3);
  build: `swiftc spikeN.swift -o spikeN -framework Cocoa -framework ApplicationServices`
