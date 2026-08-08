# Design

Visual system for Inertia — a macOS menu-bar utility. Adapted from the DESIGN.md spec for an AppKit
(Swift) app: there are no CSS tokens; the values below are the literal colors, fonts, and component
specs used in `main.swift` and `art/makeicons.swift`.

## Theme

The whole popover is one **Liquid Glass** surface (a full-panel `NSVisualEffectView`, `.popover`
material, `.behindWindow`; auto-opaque under Reduce Transparency). The header lays the **OS accent**
over that glass and fades it out, so it reads accent→glass. Everything else defers to macOS
light/dark via system colors. Color strategy: **Restrained + one Committed accent** carried by the
header/accent over glass; the body is the glass itself.

## Color

Brand (fixed, sRGB):

| Role | Value | Where |
|---|---|---|
| Accent | `NSColor.controlAccentColor` (the user's OS accent) | slider fill (`trackFillColor`), preview glyph |
| Header gradient start (indigo) | `rgb(0.30, 0.20, 0.82)` ≈ `#4C33D1` | popover header, top-left |
| Header gradient end (azure) | `rgb(0.13, 0.44, 0.90) `≈ `#2170E6` | popover header, bottom-right |
| Icon gradient | `#4D36DB` → `#1799F5` | app `.icns` background |
| Traffic-light dots | `#FF5E57` `#FFBD2E` `#33CC59` | app icon window chrome |

System (adaptive — resolve per light/dark, guaranteeing WCAG AA):

- `windowBackgroundColor` — panel body. `textBackgroundColor` — the preview "stage".
- `labelColor` — primary text. `secondaryLabelColor` — captions, value readouts.
- `separatorColor` — hairlines. `systemOrange` — permission CTA (tint `.22`, border `.55`).

Rule: gradient and accent are the only saturated color; never tint body text or add decorative color.
The permission state never signals by hue alone (amber tint + ⚠ icon + text).

## Typography

System font only (SF Pro / `NSFont.systemFont`). Fixed point sizes, not fluid.

| Element | Size / weight | Color |
|---|---|---|
| Title "Inertia" | 16 semibold | white (on gradient) |
| Activation hint (subtitle) | 11 regular | white 85% |
| Section captions (Preview / Activation) | 11 semibold | secondaryLabel |
| Slider name | 12 regular | label |
| Disclosure ("▸ Advanced") | 12 regular | secondaryLabel |
| CTA banner | 12 semibold | label |

Sliders carry **no numeric value labels** — tuning is by feel, the knob position is the value.

## Iconography

One metaphor everywhere: **a window thrown right, tilted in flight, trailing tapering speed lines**
(the inertia). Shared `drawBrandMark()` draws it for the menu bar + header; the app icon tilts its
detailed window to match.

- **App icon** — color: gradient tile, white window with traffic-light dots, trails that fade tail→head.
- **Menu bar** — monochrome template image (auto light/dark tint), same silhouette, no chrome.
- **Preview glyph** — accent fill + a white title-bar hint; the trail is drawn as fading ghosts.

## Components

- **Popover panel** — 300pt fixed width, `FlippedView` (top-down layout), opaque `windowBackgroundColor`.
- **Glass header** — slim 52pt, just the white glyph + "Inertia" wordmark (no subtitle). An
  `NSVisualEffectView` (`.headerView`, `.behindWindow`) provides the Liquid-Glass material; over it
  `HeaderView` draws the **OS accent** (`accentHeaderStops()`, brightness-clamped dark for legible
  white text) fading left→right from opaque accent to transparent, so the accent melts into the glass.
  Auto-opaque under Reduce Transparency. Faint white **speed-streak texture** on the accent side.
- **Live preview strip** — labeled "Preview"; a 46pt rounded "stage" (`textBackgroundColor` +
  `separatorColor` border) running the real `coastStep` physics; static under Reduce Motion.
- **Activation** — one `NSPopUpButton` shortcut menu showing the current combo (e.g. "⌃⌘
  Control-Command"); six common two-key combos, then **Custom…** which records any combo you press
  (fn included) via a guarded local `flagsChanged` monitor. Only multi-modifier combos (singles clash
  with ordinary ⌘-clicks/drags).
- **Sliders** — native `NSSlider`, `trackFillColor = ACCENT`, no numeric labels. Three feel knobs up
  front (Throw / Glide / Bounce); two thresholds (Flick to start / Settle) behind a ▸ Advanced
  disclosure that rebuilds the panel on toggle.
- **Permission CTA banner** — full-width amber button, shown only when Accessibility is missing.
- **Footer** — two borderless SF Symbol glyphs (no button chrome), `secondaryLabelColor`:
  `arrow.counterclockwise` (reset, left) and `power` (quit, right), each with a tooltip + accessibility
  label since they're icon-only.

## Layout

300pt column, 16pt side padding (12pt for full-width banner/footer buttons). Vertical rhythm: 78pt
header → 14pt → [banner 40 + 14] → preview 46 → 16 → section (caption 20 + control) → grouped slider
rows (48pt each) → footer. Panel height is dynamic (banner present or not) and rebuilt on each open.

## Motion

- **Window coast** (the product) — `CADisplayLink`, vsync-paced; exponential-decay friction, edge
  bounce, stall-clamped `dt`. Carries **mass** (`massFactor` ∝ window area, 0.7–1.6×): bigger windows
  glide farther and resist starting, so the app literally demonstrates inertia. User-initiated; runs
  regardless of Reduce Motion.
- **Live preview** — same engine, looping; **freezes to a static thrown pose under Reduce Motion**,
  switching live via `accessibilityDisplayOptionsDidChangeNotification`.
- No decorative/ambient UI motion beyond these; the popover uses the system's own show animation.

## Accessibility

WCAG AA via system colors (light + dark); Reduce Motion honored for the decorative preview; no
color-only signals; standard focusable AppKit controls with meaningful labels.
