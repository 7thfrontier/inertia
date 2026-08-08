# Product

## Register

product

## Users

People who want to move windows by *throwing* them — flick a window and let it coast. They're
comfortable on macOS and may already run a window manager (Rectangle, yabai, Loop); Inertia isn't a
replacement, it sits alongside those as the fun, physical way to fling a window across the screen.
They reach for it because it feels good, and they keep it because it's genuinely handy.

## Product Purpose

Inertia lets you grab any window with a modifier + drag and throw it with real momentum: it keeps its
size, coasts with friction, and bounces off screen edges. Success is when the throw feels physical
and precise enough that people use it for actual window management, not just once for the novelty.

## Brand Personality

Silly, delightful, and useful — in that order of surprise, but with "useful" load-bearing. The
physics is the soul: tactile, a little joyful, the kind of thing you show a friend. But it's a real
tool, not a gag — it has to work every time or the silliness curdles into "broken toy." Three words:
playful, physical, dependable.

## Anti-references

- **Sterile / corporate settings UI** — cold enterprise-admin chrome, generic SaaS dashboard panels.
- **Bloated multi-tab preference windows** — dozens of options behind tabs; Inertia's whole surface
  is one small panel.
- **An unreliable gimmick** — flashy but janky. Silly is fine; flaky is not. If a throw misfires or
  a setting drifts, the delight is gone.
- **Generic AI-gradient slop** — purple-blue-gradient-everything with no intent. The gradient here
  earns its place (velocity, the app's one committed brand moment); it isn't decoration by default.

## Design Principles

- **The physics is the product.** Momentum, friction, and bounce aren't decoration — they're the
  feature. Invest in making the throw feel real; everything else serves that.
- **Silly, but never flaky.** Delight is only delightful if the tool is dependable. A playful toy
  that drops a window or forgets a setting reads as broken, not fun.
- **Show the feel, don't spec it.** Let people see and feel behavior (the live preview reacts to the
  sliders) instead of reading numbers. Tuning is by feel.
- **One-tap depth.** Great defaults; every knob is optional. A first-timer never has to configure
  anything; a tinkerer can dial in the exact feel.
- **Complements, doesn't compete.** Plays nice next to other window managers — additive, not a land
  grab. Its activation shortcut and behavior stay out of their way.

## Accessibility & Inclusion

- WCAG AA contrast, met by using system label/background colors so light and dark both pass.
- Honor **Reduce Motion**: the always-looping live-preview animation freezes to a static "thrown"
  pose when Reduce Motion is on (and switches live if the setting changes). The window throw itself is
  the user-initiated core feature — brief, not ambient — and is left intact; reducing it would remove
  the product.
- VoiceOver: menu-bar item and every panel control carry meaningful labels.
- No color-only signals: the permission state pairs its amber tint with an icon and text, not hue
  alone.
