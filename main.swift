// Inertia — throw macOS windows; they keep their size and coast with momentum.
// Menu-bar accessory app. ⌃⌘ + drag any window, flick, release -> it coasts and bounces off edges.
// Build: ./build.sh   Self-test physics: ./build.sh && Inertia.app/Contents/MacOS/Inertia --selftest
// © 2026 7th Frontier, Inc. MIT License, see LICENSE.
import Cocoa
import ApplicationServices
import QuartzCore
import ServiceManagement

// ---- fixed tunables ----
let COAST_HZ    = 120.0   // self-test simulation rate only; the live coast is vsync-paced (see coastTick)

// ---- user-adjustable knobs (persisted in UserDefaults). No numbers: tune by feel. ----
// Label and storage key both name the quantity itself; the hover hint carries the plain-language gloss.
// PRIMARY = the feel; ADVANCED = the two thresholds, tucked behind a disclosure.
// `sym` is the physics notation shown when Labels is set to Notation. Restricted to glyphs SF Pro
// actually has: letter subscripts (vₘᵢₙ) and ∝ are absent from it and would silently fall back to a
// different face mid-label, which looks like a rendering bug.
struct Knob {
    let key: String; let name: String; let sym: String
    let min: Double; let max: Double; let def: Double; let tip: String
}
let KNOBS = [
    Knob(key: "glideTime",       name: "Glide Time",   sym: "τ",         // decay time constant
         min: 0.05, max: 1.20,  def: 0.22,
         tip: "How long a window keeps gliding before friction brings it to rest."),   // 0
    Knob(key: "restitution",     name: "Restitution",  sym: "e",         // coefficient of restitution
         min: 0.00, max: 0.95,  def: 0.35,
         tip: "How much a window rebounds when it hits a screen edge."),                // 1
    Knob(key: "launchGain",      name: "Launch Gain",  sym: "G",         // gain: v₀ = G · v_flick
         min: 0.25, max: 4.00,  def: 1.00,
         tip: "How hard your flick launches a window. Higher throws it faster and farther."),  // 2
    Knob(key: "minReleaseSpeed", name: "Minimum Release Speed", sym: "|v|_min",
         min: 10.0, max: 500.0, def: 80.0,
         tip: "How firm a flick must be to count as a throw. A gentle release just moves the window."),  // 3
    Knob(key: "restSpeed",       name: "Rest Speed",   sym: "|v|_rest",  // coast ends below this speed
         min: 5.0,  max: 300.0, def: 40.0,
         tip: "How slow a coasting window must get before it settles to a stop."),      // 4
]
let PRIMARY = [2, 0, 1]      // Launch Gain, Glide Time, Restitution
let ADVANCED = [3, 4]        // Minimum Release Speed, Rest Speed

func knob(_ key: String) -> Double {
    let v = UserDefaults.standard.double(forKey: key)
    guard let k = KNOBS.first(where: { $0.key == key }) else { return v }
    return min(max(v, k.min), k.max)   // corrupt defaults must never reach the physics (tau<=0 → exponential blowup)
}
func useMass() -> Bool { UserDefaults.standard.bool(forKey: "massByArea") }   // window inertia scales with area
func useNotation() -> Bool { UserDefaults.standard.bool(forKey: "notationLabels") }  // physics notation, not plain names

// Notation with a real typographic subscript: "|v|_min" draws |v| followed by a smaller, lowered "min".
// Composed rather than spelled with precomposed glyphs on purpose: Unicode puts subscript i and r in
// Phonetic Extensions (U+1D62/U+1D63), not the Subscripts block, and SF Pro covers only the latter — so
// "vₘᵢₙ" silently renders ₘₙ in SF Pro and ᵢ in Helvetica Neue. Composing keeps one typeface throughout.
func notation(_ s: String, _ size: CGFloat = 12) -> NSAttributedString {
    let part = s.split(separator: "_", maxSplits: 1).map(String.init)
    let out = NSMutableAttributedString(string: part[0],
        attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.labelColor])
    if part.count > 1 {
        out.append(NSAttributedString(string: part[1], attributes: [
            .font: NSFont.systemFont(ofSize: size * 0.68),   // ~8pt at 12pt base
            .baselineOffset: -size * 0.17,                   // sits below the baseline, not on it
            .foregroundColor: NSColor.labelColor]))
    }
    return out
}
// Display text for a control: notation when Labels is Notation, plain English otherwise. VoiceOver gets the
// plain name — reading out "tau" tells a screen-reader user nothing about what the slider does.
func labelText(_ name: String, _ sym: String) -> NSAttributedString {
    useNotation() ? notation(sym)
               : NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 12),
                                                               .foregroundColor: NSColor.labelColor])
}
func hasThrown() -> Bool { UserDefaults.standard.bool(forKey: "hasThrown") }  // false until the first successful throw

// ---- activation shortcut: any combination of modifier keys (raw flags persisted under "modifierFlags") ----
let MODMASK: CGEventFlags = [.maskSecondaryFn, .maskControl, .maskAlternate, .maskShift, .maskCommand]
let DEFAULT_FLAGS: CGEventFlags = [.maskControl, .maskCommand]   // ⌃⌘
func activeFlags() -> CGEventFlags {
    let raw = UInt64(bitPattern: Int64(UserDefaults.standard.integer(forKey: "modifierFlags")))   // bitPattern: a corrupt negative default must not trap
    let f = CGEventFlags(rawValue: raw).intersection(MODMASK)
    return f.isEmpty ? DEFAULT_FLAGS : f
}
func setFlags(_ f: CGEventFlags) {
    UserDefaults.standard.set(Int(f.intersection(MODMASK).rawValue), forKey: "modifierFlags")
}
// Exact match, not a subset: with ⌃⌘ set, a ⌃⇧⌘-drag belongs to whatever app owns that combo, not to us.
// (Intersecting with MODMASK drops the noise CG sets on every mouse event: nonCoalesced, caps lock, numpad.)
func flagsMatch(_ eventFlags: CGEventFlags) -> Bool { eventFlags.intersection(MODMASK) == activeFlags() }
func flagsSymbol(_ f: CGEventFlags) -> String {             // canonical order fn⌃⌥⇧⌘
    var s = ""
    if f.contains(.maskSecondaryFn) { s += "fn" }
    if f.contains(.maskControl)     { s += "⌃" }
    if f.contains(.maskAlternate)   { s += "⌥" }
    if f.contains(.maskShift)       { s += "⇧" }
    if f.contains(.maskCommand)     { s += "⌘" }
    return s.isEmpty ? "—" : s
}
// The dropdown lists the common two-key combos; "Custom…" records anything else (3-key, fn, etc.).
let SHORTCUTS: [CGEventFlags] = [
    [.maskControl, .maskCommand], [.maskAlternate, .maskCommand], [.maskControl, .maskAlternate],
    [.maskShift, .maskCommand], [.maskControl, .maskShift], [.maskAlternate, .maskShift],
]
func cgFlags(from ns: NSEvent.ModifierFlags) -> CGEventFlags {   // for the Custom recorder
    var f = CGEventFlags()
    if ns.contains(.function) { f.insert(.maskSecondaryFn) }
    if ns.contains(.control)  { f.insert(.maskControl) }
    if ns.contains(.option)   { f.insert(.maskAlternate) }
    if ns.contains(.shift)    { f.insert(.maskShift) }
    if ns.contains(.command)  { f.insert(.maskCommand) }
    return f
}

// ---- pure physics (the only non-trivial logic; self-tested below) ----
func coastStep(pos: CGPoint, vel: CGVector, size: CGSize, bounds: CGRect, dt: Double,
               tau: Double, restitution: Double) -> (CGPoint, CGVector) {
    var p = pos, v = vel
    p.x += v.dx * dt; p.y += v.dy * dt
    let decay = exp(-dt / tau)
    v.dx *= decay; v.dy *= decay
    // A window larger than the bounds makes max < min; pin such an axis at min instead of letting the
    // two clamps below fight each other (visible jitter between the two edges every frame).
    let maxX = max(bounds.maxX - size.width, bounds.minX), maxY = max(bounds.maxY - size.height, bounds.minY)
    if p.x < bounds.minX { p.x = bounds.minX; v.dx = -v.dx * restitution }
    if p.x > maxX        { p.x = maxX;        v.dx = -v.dx * restitution }
    if p.y < bounds.minY { p.y = bounds.minY; v.dy = -v.dy * restitution }
    if p.y > maxY        { p.y = maxY;        v.dy = -v.dy * restitution }
    return (p, v)
}

// Velocity a release launches with. No drag events arrive while the mouse is still, so the EMA would keep
// the last flick's speed: flick, hold motionless, let go must NOT throw. Pure so the self-test can pin it.
func releaseVelocity(_ ema: CGVector, idleFor idle: CFTimeInterval) -> CGVector { idle > 0.1 ? .zero : ema }

// Inertia ∝ mass ∝ window area. Bigger windows carry more momentum (coast longer) and resist starting.
// Sub-linear + clamped so it's felt but never sends a window into orbit.
func massFactor(_ size: CGSize) -> Double {
    let area = Double(size.width * size.height)
    return min(max(pow(area / 800_000, 0.4), 0.7), 1.6)   // ~1.0 for a typical window; small→0.7, huge→1.6
}

// precondition() drops its message under -O, so a failed check would exit 133 with no text. Print, then fail.
func check(_ ok: Bool, _ msg: @autoclosure () -> String) { if !ok { print("selftest FAILED: \(msg())"); exit(1) } }
func runSelfTest() {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    let size = CGSize(width: 200, height: 150)
    // 1) converges and stays in bounds
    var p = CGPoint(x: 400, y: 400); var v = CGVector(dx: 3000, dy: -1500)
    let dt = 1.0 / COAST_HZ
    var stopped = false
    for _ in 0..<Int(COAST_HZ * 5) {
        (p, v) = coastStep(pos: p, vel: v, size: size, bounds: bounds, dt: dt, tau: 0.22, restitution: 0.35)
        check(p.x >= bounds.minX && p.x <= bounds.maxX - size.width, "x escaped: \(p.x)")
        check(p.y >= bounds.minY && p.y <= bounds.maxY - size.height, "y escaped: \(p.y)")
        if hypot(v.dx, v.dy) < 40.0 { stopped = true; break }
    }
    check(stopped, "did not converge")
    // 2) bounce flips velocity at the right edge
    let atEdge = CGPoint(x: bounds.maxX - size.width - 1, y: 500)
    let (_, vb) = coastStep(pos: atEdge, vel: CGVector(dx: 5000, dy: 0), size: size, bounds: bounds, dt: dt, tau: 0.22, restitution: 0.35)
    check(vb.dx < 0, "right-edge bounce did not reverse dx: \(vb.dx)")
    // 3) mass: monotonic in area, clamped, ~1.0 at the reference size
    check(massFactor(CGSize(width: 400, height: 300)) == 0.7, "small window should floor at 0.7")
    check(massFactor(CGSize(width: 3000, height: 2000)) == 1.6, "huge window should cap at 1.6")
    let m = massFactor(CGSize(width: 1100, height: 730)); check(m > 0.95 && m < 1.05, "ref ≈ 1.0, got \(m)")
    // 4) window taller than the bounds: pinned at minY (no min/max clamp fight), x still in range
    let tall = CGSize(width: 800, height: 1200)
    p = CGPoint(x: 100, y: 0); v = CGVector(dx: 800, dy: 900)
    for _ in 0..<Int(COAST_HZ * 3) {
        (p, v) = coastStep(pos: p, vel: v, size: tall, bounds: bounds, dt: dt, tau: 0.22, restitution: 0.35)
        check(p.y == bounds.minY, "oversized window should pin at minY, got \(p.y)")
        check(p.x >= bounds.minX && p.x <= bounds.maxX - tall.width, "x escaped: \(p.x)")
    }
    // 5) knob() clamps corrupt defaults to the knob's range (restores the user's value after)
    let saved = UserDefaults.standard.object(forKey: "glideTime")
    UserDefaults.standard.set(-5.0, forKey: "glideTime")
    check(knob("glideTime") == KNOBS[0].min, "knob() must clamp corrupt values, got \(knob("glideTime"))")
    UserDefaults.standard.set(saved, forKey: "glideTime")
    // 6) activation matches exactly: CG's per-event noise flags are ignored, but an extra modifier is not
    let savedFlags = UserDefaults.standard.object(forKey: "modifierFlags")
    setFlags(DEFAULT_FLAGS)
    check(flagsMatch([.maskControl, .maskCommand]), "⌃⌘ must match ⌃⌘")
    check(flagsMatch([.maskControl, .maskCommand, .maskNonCoalesced, .maskAlphaShift]), "noise flags must not block a match")
    check(!flagsMatch([.maskControl, .maskCommand, .maskShift]), "⌃⇧⌘ belongs to another app, not us")
    check(!flagsMatch([.maskControl]), "⌃ alone must not match")
    UserDefaults.standard.set(savedFlags, forKey: "modifierFlags")
    // 7) the menu bar fences the top, per display, so a thrown window's title bar stays reachable
    let solo = [(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), menuBar: CGFloat(38))]
    let soloUnion = CGRect(x: 0, y: 0, width: 1440, height: 900)
    check(coastRect(soloUnion, titleBar: CGPoint(x: 700, y: 400), solo) == CGRect(x: 0, y: 38, width: 1440, height: 862),
                 "single display should fence its menu bar")
    // a laptop + an external with no menu bar of its own: each display keeps its own ceiling
    let mixed = [(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), menuBar: CGFloat(30)),
                 (frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), menuBar: CGFloat(0))]
    let mixedUnion = CGRect(x: -1920, y: 0, width: 3840, height: 1080)
    check(coastRect(mixedUnion, titleBar: CGPoint(x: 900, y: 10), mixed).minY == 30, "menu-bar display must be fenced")
    check(coastRect(mixedUnion, titleBar: CGPoint(x: -1000, y: 10), mixed).minY == 0,
                 "a display with no menu bar must keep its full height")
    // stacked: the title bar's own display decides, not whichever menu bar is tallest
    let stacked = [(frame: CGRect(x: 0, y: -1080, width: 1920, height: 1080), menuBar: CGFloat(24)),
                   (frame: CGRect(x: 0, y: 0, width: 1440, height: 900), menuBar: CGFloat(38))]
    let stackedUnion = CGRect(x: 0, y: -1080, width: 1920, height: 1980)
    check(coastRect(stackedUnion, titleBar: CGPoint(x: 700, y: -500), stacked).minY == -1056, "upper display's own menu bar")
    check(coastRect(stackedUnion, titleBar: CGPoint(x: 700, y: 500), stacked).minY == 38, "lower display's own menu bar")
    // degenerate inputs fall back to the unfenced desktop rather than trapping
    check(coastRect(soloUnion, titleBar: CGPoint(x: 700, y: 400), []) == soloUnion, "no displays → leave bounds alone")
    check(coastRect(soloUnion, titleBar: CGPoint(x: 9_999, y: 400), solo) == soloUnion, "off-desktop title bar → no fence")
    // and the fence holds in the physics: thrown hard upward, the window never enters the menu bar
    p = CGPoint(x: 700, y: 500); v = CGVector(dx: 0, dy: -6000)
    for _ in 0..<Int(COAST_HZ * 5) {
        let b = coastRect(soloUnion, titleBar: CGPoint(x: p.x + size.width / 2, y: p.y), solo)
        (p, v) = coastStep(pos: p, vel: v, size: size, bounds: b, dt: dt, tau: 0.22, restitution: 0.35)
        check(p.y >= 38, "window slid under the menu bar: \(p.y)")
    }
    let d = UserDefaults.standard
    // 9) the Labels choice swaps between plain names and notation; every knob carries both, unambiguously
    let savedLabels = d.object(forKey: "notationLabels")
    d.set(false, forKey: "notationLabels")
    check(labelText(KNOBS[0].name, KNOBS[0].sym).string == "Glide Time", "Plain should give the plain name")
    d.set(true, forKey: "notationLabels")
    check(labelText(KNOBS[0].name, KNOBS[0].sym).string == "τ", "Notation should give the symbol")
    d.set(savedLabels, forKey: "notationLabels")
    check(KNOBS.allSatisfy { !$0.sym.isEmpty && !$0.name.isEmpty }, "every knob needs a name and notation")
    check(Set(KNOBS.map { $0.sym }).count == KNOBS.count, "notation must be unique per knob")
    // the subscript must be a real lowered, smaller run — not "min" concatenated at full size
    let sub = notation("|v|_min")
    check(sub.string == "|v|min", "subscript should join its base, got \(sub.string)")
    var lowered = false
    sub.enumerateAttribute(.baselineOffset, in: NSRange(location: 0, length: sub.length)) { v, _, _ in
        if let off = v as? CGFloat, off < 0 { lowered = true }
    }
    check(lowered, "the subscript run needs a negative baseline offset")
    // Every symbol must exist in the system font. A character SF Pro lacks (∝, or subscript i/r from
    // Phonetic Extensions) silently falls back to Apple Symbols or Helvetica Neue, putting two typefaces
    // in one label. This fails the build's self-test rather than shipping that.
    let sysFont = NSFont.systemFont(ofSize: 12) as CTFont
    for k in KNOBS {
        for ch in k.sym.unicodeScalars where ch.value > 127 {
            var chars = Array(String(ch).utf16), glyphs = [CGGlyph](repeating: 0, count: chars.count)
            check(CTFontGetGlyphsForCharacters(sysFont, &chars, &glyphs, chars.count),
                         "\(k.sym): U+\(String(ch.value, radix: 16, uppercase: true)) is not in SF Pro and would fall back")
        }
    }
    // 10) the footer version is read from the bundle, so it can't disagree with Info.plist — and the
    // marketing version must be MAJOR.MINOR.PATCH, so a two-component "0.9" fails the build instead of
    // shipping and making two different builds indistinguishable.
    let appV = appVersion()
    check(appV.short != "?" && appV.build != "?", "version must be readable from the bundle, got \(appV)")
    check(appV.short.split(separator: ".").count == 3,
                 "CFBundleShortVersionString must be MAJOR.MINOR.PATCH, got \(appV.short)")
    check(Int(appV.build) != nil, "CFBundleVersion must be a plain build number, got \(appV.build)")
    // 11) a release after holding still must not throw; a prompt release keeps the flick
    let flick = CGVector(dx: 900, dy: -300)
    check(releaseVelocity(flick, idleFor: 0.5) == .zero, "held still 0.5s: must release with zero velocity")
    check(releaseVelocity(flick, idleFor: 0.02) == flick, "released 20ms after the last drag: must keep the flick")
    // 12) shortcut flags: canonical symbol order, NSEvent→CG mapping, and storage that survives corruption
    check(flagsSymbol(MODMASK) == "fn⌃⌥⇧⌘", "symbols must come out in fn⌃⌥⇧⌘ order, got \(flagsSymbol(MODMASK))")
    check(flagsSymbol([]) == "—", "no modifiers must show a dash")
    check(cgFlags(from: [.control, .command]) == [.maskControl, .maskCommand], "⌃⌘ must map to CG control+command")
    check(cgFlags(from: [.function, .option, .shift]) == [.maskSecondaryFn, .maskAlternate, .maskShift], "fn⌥⇧ must map bit for bit")
    check(cgFlags(from: [.capsLock, .numericPad]) == [], "caps lock and numpad are not activation modifiers")
    check(Set(SHORTCUTS.map { $0.rawValue }).count == SHORTCUTS.count, "shortcut menu must not list a combo twice")
    check(SHORTCUTS.contains(DEFAULT_FLAGS), "the default shortcut must be pickable from the menu")
    let savedRaw = d.object(forKey: "modifierFlags")
    d.set(-1, forKey: "modifierFlags")                          // corrupt: every bit set, negative
    check(activeFlags() == MODMASK, "a corrupt all-bits default must not trap and must keep only real modifiers")
    d.set(0, forKey: "modifierFlags")
    check(activeFlags() == DEFAULT_FLAGS, "no stored shortcut must fall back to ⌃⌘")
    setFlags([.maskShift, .maskCommand, .maskNonCoalesced])       // noise bit must not be persisted
    check(activeFlags() == [.maskShift, .maskCommand], "setFlags must store only activation modifiers")
    d.set(savedRaw, forKey: "modifierFlags")
    // 13) coastStep edges: zero restitution stops dead at a wall; a stalled frame (dt == tau) decays, never grows
    let (_, dead) = coastStep(pos: CGPoint(x: bounds.maxX - size.width - 1, y: 500), vel: CGVector(dx: 5000, dy: 0),
                              size: size, bounds: bounds, dt: dt, tau: 0.22, restitution: 0)
    check(dead.dx == 0, "restitution 0 must absorb the whole impact, got dx \(dead.dx)")
    let (_, slow) = coastStep(pos: CGPoint(x: 500, y: 500), vel: CGVector(dx: 100, dy: 100), size: size, bounds: bounds,
                              dt: 0.05, tau: 0.05, restitution: 0.35)
    check(hypot(slow.dx, slow.dy) < hypot(100, 100), "a long frame must still decay velocity")
    check(massFactor(CGSize(width: 800, height: 600)) < massFactor(CGSize(width: 1600, height: 1200)), "mass must grow with area")
    // 14) the mark actually draws: the menu-bar icon must have ink, not be an empty template
    _ = NSApplication.shared                                     // views and images below need an app context
    let icon = Controller.menuBarIcon()
    var inked = 0
    if let tiff = icon.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
        for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { inked += 1 } }
    }
    check(inked > 40, "menu-bar icon rendered \(inked) opaque pixels; the mark is missing")
    check(icon.isTemplate, "menu-bar icon must be a template so it tints for light and dark")
    // 15) the panel builds in every state and reflects its toggles; a crash here is a crash on every click
    let savedPreview = d.object(forKey: "previewOpen"), savedNotation = d.object(forKey: "notationLabels")
    d.set(true, forKey: "previewOpen"); d.set(false, forKey: "notationLabels")
    let c = Controller(); c.previewOpen = true
    let vc = c.buildPanel()
    func sliders() -> Int { vc.view.subviews.filter { $0 is HoverSlider }.count }
    func previews() -> Int { vc.view.subviews.filter { $0 is PreviewStrip }.count }
    check(sliders() == PRIMARY.count, "closed panel must show the \(PRIMARY.count) primary sliders, got \(sliders())")
    check(previews() == 1, "preview must be shown when previewOpen is on")
    let closedH = vc.view.frame.height
    c.toggleAdvanced()
    check(sliders() == KNOBS.count, "Advanced must reveal every knob, got \(sliders())")
    check(vc.view.frame.height > closedH, "opening Advanced must grow the panel")
    c.togglePreview()
    check(previews() == 0, "collapsing the preview must remove the strip")
    check(!d.bool(forKey: "previewOpen"), "collapsing the preview must be remembered")
    check(vc.view.subviews.contains { $0 is NSSegmentedControl }, "Labels control must be inside Advanced")
    check(c.retitledLabels.count == KNOBS.count + 2, "every knob label plus both switch labels must be retitlable, got \(c.retitledLabels.count)")
    check(vc.view.subviews.filter { $0 is NSSwitch }.count == 2, "Mass by Area and Open at Login switches must both show")
    d.set(true, forKey: "notationLabels")
    let seg = NSSegmentedControl(labels: ["Standard", "Scientific"], trackingMode: .selectOne, target: nil, action: nil)
    seg.selectedSegment = 1; c.labelsChanged(seg)
    check(c.retitledLabels.allSatisfy { $0.field.stringValue == notation($0.sym).string }, "Scientific must retitle every label to its symbol in place")
    check(c.hintLabel.stringValue == IDLE_HINT, "help line must start on the idle hint")
    c.endRecordMonitor()
    d.set(savedPreview, forKey: "previewOpen"); d.set(savedNotation, forKey: "notationLabels")
    print("selftest OK")
}

// ---- AX helpers ----
func axGetPoint(_ e: AXUIElement) -> CGPoint? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &v) == .success else { return nil }
    guard let av = v, CFGetTypeID(av) == AXValueGetTypeID() else { return nil }   // buggy AX in another app must not crash us
    var p = CGPoint.zero; AXValueGetValue(av as! AXValue, .cgPoint, &p); return p
}
func axGetSize(_ e: AXUIElement) -> CGSize? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &v) == .success else { return nil }
    guard let av = v, CFGetTypeID(av) == AXValueGetTypeID() else { return nil }
    var s = CGSize.zero; AXValueGetValue(av as! AXValue, .cgSize, &s); return s
}
func axSetPoint(_ e: AXUIElement, _ p: CGPoint) {
    var pt = p; guard let v = AXValueCreate(.cgPoint, &pt) else { return }
    AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, v)
}
func axRole(_ e: AXUIElement) -> String {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &v) == .success else { return "" }
    return (v as? String) ?? ""
}
func windowUnder(_ p: CGPoint) -> AXUIElement? {
    let sys = AXUIElementCreateSystemWide()
    var el: AXUIElement?
    guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &el) == .success,
          var cur = el else { return nil }
    var pid: pid_t = 0
    if AXUIElementGetPid(cur, &pid) == .success, pid == getpid() { return nil }   // never grab our own popover
    for _ in 0..<12 {                                   // walk up to the window element
        if axRole(cur) == (kAXWindowRole as String) { return cur }
        var parent: CFTypeRef?
        guard AXUIElementCopyAttributeValue(cur, kAXParentAttribute as CFString, &parent) == .success,
              let pr = parent, CFGetTypeID(pr) == AXUIElementGetTypeID() else { return nil }
        cur = pr as! AXUIElement                        // safe: type checked on the line above
    }
    return nil
}
// Each active display's CG frame plus the height of its menu bar. Only the TOP of visibleFrame moves
// with the menu bar — the Dock insets the other edges — so this difference is the menu bar alone, and
// it reads 0 when the user auto-hides it (no menu bar, nothing to hide a title bar under).
func activeDisplays() -> [(frame: CGRect, menuBar: CGFloat)] {
    NSScreen.screens.compactMap {
        guard let n = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return (CGDisplayBounds(CGDirectDisplayID(n.uint32Value)), $0.frame.maxY - $0.visibleFrame.maxY)
    }
}
func desktopBounds() -> CGRect {                                       // main thread only (reads NSScreen)
    activeDisplays().map { $0.frame }.reduce(.null) { $0.union($1) }
}

// The rect a coasting window may occupy THIS frame: the whole desktop, but with the top pulled below the
// menu bar of the display its title bar is currently over. Without this a window thrown upward slides
// entirely under the menu bar and parks with its title bar out of reach of ordinary dragging.
// Per-display rather than one inset for the whole desktop, because a second display often has no menu bar
// of its own and must keep its full height. The bottom edge is deliberately untouched: the Dock covers a
// window's footer, not its title bar, so coasting under it leaves the window grabbable.
func coastRect(_ union: CGRect, titleBar t: CGPoint, _ displays: [(frame: CGRect, menuBar: CGFloat)]) -> CGRect {
    // the display holding the title bar; if it's in dead space between displays, the one sharing its column
    guard let d = displays.first(where: { $0.frame.contains(t) })
              ?? displays.first(where: { t.x >= $0.frame.minX && t.x < $0.frame.maxX }) else { return union }
    let limit = d.frame.minY + d.menuBar
    guard limit > union.minY else { return union }
    return CGRect(x: union.minX, y: limit, width: union.width, height: max(union.maxY - limit, 0))
}

// Version read from the bundle at runtime, never a literal in code, so the footer can't drift from Info.plist.
func appVersion() -> (short: String, build: String) {
    let d = Bundle.main.infoDictionary
    return (d?["CFBundleShortVersionString"] as? String ?? "?", d?["CFBundleVersion"] as? String ?? "?")
}

// ---- panel chrome ----
var ACCENT: NSColor { NSColor.controlAccentColor }   // follows the user's macOS accent color
func reduceMotion() -> Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

// The brand mark: a window thrown to the right, tilted in flight, trailing tapering speed lines.
// Drawn in a 26×18 y-up design space scaled into `rect`; pass flipped:true inside a flipped NSView.
func drawBrandMark(_ ctx: CGContext, in rect: CGRect, color: NSColor, flipped: Bool = false,
                   lineScale: CGFloat = 1) {   // >1 thickens strokes; the header needs it, the menu bar does not
    ctx.saveGState()
    ctx.translateBy(x: rect.minX, y: rect.minY)
    if flipped { ctx.translateBy(x: 0, y: rect.height); ctx.scaleBy(x: rect.width / 26, y: -rect.height / 18) }
    else { ctx.scaleBy(x: rect.width / 26, y: rect.height / 18) }
    ctx.setFillColor(color.cgColor); ctx.setStrokeColor(color.cgColor); ctx.setLineJoin(.round); ctx.setLineCap(.round)
    func streak(_ y: CGFloat, _ x0: CGFloat, _ th: CGFloat) {   // tapering triangle, point trailing left
        ctx.move(to: CGPoint(x: 10.5, y: y - th / 2)); ctx.addLine(to: CGPoint(x: 10.5, y: y + th / 2))
        ctx.addLine(to: CGPoint(x: x0, y: y)); ctx.closePath(); ctx.fillPath()
    }
    streak(5.5, 3.5, 2.4 * lineScale); streak(9, 0.5, 2.8 * lineScale); streak(12.5, 4.5, 2.4 * lineScale)
    ctx.saveGState()
    ctx.translateBy(x: 18, y: 9); ctx.rotate(by: -0.16); ctx.translateBy(x: -18, y: -9)   // tilt
    ctx.setLineWidth(1.7 * lineScale)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 12.5, y: 3.5, width: 11.5, height: 11),
                       cornerWidth: 2.6, cornerHeight: 2.6, transform: nil)); ctx.strokePath()
    ctx.setLineWidth(1.5 * lineScale); ctx.move(to: CGPoint(x: 13.4, y: 11)); ctx.addLine(to: CGPoint(x: 23.1, y: 11)); ctx.strokePath()
    ctx.restoreGState()
    ctx.restoreGState()
}

// Top-down layout; transparent so the popover-wide Liquid Glass material shows through.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// Borderless icon/text button that brightens on hover — the tactile feedback plain NSButtons lack.
final class HoverButton: NSButton {
    var restTint: NSColor = .secondaryLabelColor
    private var area: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        area.map { removeTrackingArea($0) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(a); area = a
    }
    override func mouseEntered(with e: NSEvent) { contentTintColor = .labelColor }
    override func mouseExited(with e: NSEvent) { contentTintColor = restTint }
}

// Slider that reports hover in/out — tooltips are unreliable in a transient popover, so we drive an
// inline help line instead.
final class HoverSlider: NSSlider {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        area.map { removeTrackingArea($0) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a); area = a
    }
    override func mouseEntered(with e: NSEvent) { onHover?(true) }
    override func mouseExited(with e: NSEvent) { onHover?(false) }
}

// Label that reports hover in/out, so slider names drive the help line too.
final class HoverText: NSTextField {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?
    // AppKit auto-installs tracking areas for interactive controls but not for a static label,
    // so force it once the field is in a window — otherwise mouseEntered never fires.
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateTrackingAreas() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        area.map { removeTrackingArea($0) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a); area = a
    }
    override func mouseEntered(with e: NSEvent) { onHover?(true) }
    override func mouseExited(with e: NSEvent) { onHover?(false) }
}

let IDLE_HINT = "Hover a slider to see what it does."

let wordmarkFont: NSFont = {
    let heavy = NSFont.systemFont(ofSize: 18, weight: .heavy)
    return NSFontManager.shared.convert(heavy, toHaveTrait: .italicFontMask)
}()

// Popover title area: the Liquid Glass shows through (native, like Control Center) — no colored band.
// Mark + wordmark are a centered lockup sharing a baseline: the glyph's bottom edge lines up with the
// text baseline. The mark carries the accent so the header still reflects the OS accent; a hairline
// defines the title area against the controls below.
final class HeaderView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clip(to: bounds)                 // views don't clip to bounds by default on macOS 14+

        let str = NSAttributedString(string: "Inertia",
            attributes: [.font: wordmarkFont, .foregroundColor: NSColor.labelColor, .kern: -0.4])
        let tw = ceil(str.size().width)
        let gW: CGFloat = 27, gH: CGFloat = 18, gap: CGFloat = 8   // 8, not 10: the mark box carries ~2pt of
        // trailing whitespace, so 8 reads as an even 10 against the wordmark
        let inkPad: CGFloat = 2.1, inkH: CGFloat = 13.7       // measured: empty pad below the mark's ink; its ink height
        let startX = ((bounds.width - (gW + gap + tw)) / 2).rounded()
        let baseY = ((bounds.height + inkH) / 2).rounded()    // mark ink-bottom == text baseline, lockup centered

        // labelColor, not ACCENT: with a graphite system accent the mark just read as a dimmer, thinner
        // object beside near-white heavy text. One color makes the lockup a single unit. The accent
        // still carries the panel elsewhere (slider fills, the preview glyph, the first-run link).
        drawBrandMark(ctx, in: CGRect(x: startX, y: baseY + inkPad - gH, width: gW, height: gH),
                      color: .labelColor, flipped: true, lineScale: 1.25)
        str.draw(at: CGPoint(x: startX + gW + gap, y: baseY - wordmarkFont.ascender))

        ctx.setStrokeColor(NSColor.separatorColor.cgColor); ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: 0, y: bounds.maxY - 0.5)); ctx.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY - 0.5)); ctx.strokePath()
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityLabel() -> String? { "Inertia" }
}

// Live physics preview: a little window glyph thrown with the REAL coastStep engine and the user's
// current settings, so tuning a slider visibly changes the feel. Runs only while the popover is open.
final class PreviewStrip: NSView {
    override var isFlipped: Bool { true }
    private var link: CADisplayLink?
    private var pos = CGPoint.zero
    private var vel = CGVector.zero
    private var trail: [CGPoint] = []
    private var restUntil: CFTimeInterval = 0
    private var launchUp = false                          // alternates the throw angle so the demo varies
    private let glyph = CGSize(width: 24, height: 16)

    override func viewDidMoveToWindow() {
        if window != nil {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(configure),
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            configure()
        } else {
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            stopLink()
        }
    }
    deinit { stopLink(); NSWorkspace.shared.notificationCenter.removeObserver(self) }

    // Reduce Motion: freeze the looping demo to a static "thrown" pose; otherwise animate.
    @objc private func configure() {
        if reduceMotion() { stopLink(); staticPose() } else { startLink() }
        needsDisplay = true
    }
    private func staticPose() {
        let s = stage()
        pos = CGPoint(x: s.minX + s.width * 0.5, y: s.minY + s.height * 0.3)
        let d = CGVector(dx: -glyph.width * 0.7, dy: glyph.height * 0.5)      // trail down-and-left: a diagonal throw
        trail = (1...5).map { CGPoint(x: pos.x + d.dx * CGFloat($0), y: pos.y + d.dy * CGFloat($0)) }
    }

    private func startLink() {
        guard link == nil, let l = NSScreen.main?.displayLink(target: self, selector: #selector(tick(_:))) else { return }
        l.add(to: .main, forMode: .common); link = l; relaunch()
    }
    private func stopLink() { link?.invalidate(); link = nil }

    private func stage() -> CGRect { bounds.insetBy(dx: 8, dy: 6) }
    private func relaunch() {
        let s = stage()
        pos = CGPoint(x: s.minX, y: s.midY - glyph.height / 2)
        let tau = max(knob("glideTime"), 0.14)              // floor so short-coast reads as "quick", not a strobe
        let speed = s.width * (0.8 + knob("launchGain")) / tau   // v·tau ≈ travel, so it crosses and bounces
        launchUp.toggle()                                  // alternate up/down so it isn't the same throw each time
        let angle = launchUp ? -0.42 : 0.42                // ~±24°: mostly sideways, but real vertical travel too
        vel = CGVector(dx: speed * cos(angle), dy: speed * sin(angle))
        trail.removeAll()
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        if now < restUntil { return }
        if hypot(vel.dx, vel.dy) < knob("restSpeed") { restUntil = now + 0.7; relaunch(); needsDisplay = true; return }
        let dt = min(max(l.targetTimestamp - l.timestamp, 1e-4), 0.05)
        (pos, vel) = coastStep(pos: pos, vel: vel, size: glyph, bounds: stage(), dt: dt,   // full 2-D stage: bounces off every edge
                               tau: knob("glideTime"), restitution: knob("restitution"))
        trail.insert(pos, at: 0); if trail.count > 7 { trail.removeLast() }
        needsDisplay = true
    }

    override func draw(_ r: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clip(to: bounds)
        let bg = CGPath(roundedRect: bounds, cornerWidth: 9, cornerHeight: 9, transform: nil)
        // a translucent recessed well, not an opaque box — lets the glass read through
        ctx.addPath(bg); ctx.setFillColor(NSColor.black.withAlphaComponent(0.25).cgColor); ctx.fillPath()
        ctx.addPath(bg); ctx.setStrokeColor(NSColor.separatorColor.cgColor); ctx.setLineWidth(1); ctx.strokePath()
        ctx.addPath(bg); ctx.clip()
        for (i, p) in trail.enumerated() { drawGlyph(ctx, p, 0.16 * (1 - Double(i) / Double(max(trail.count, 1)))) }
        drawGlyph(ctx, pos, 1)
    }
    private func drawGlyph(_ ctx: CGContext, _ p: CGPoint, _ a: Double) {
        ctx.setFillColor(ACCENT.withAlphaComponent(a).cgColor)
        ctx.addPath(CGPath(roundedRect: CGRect(x: p.x, y: p.y, width: glyph.width, height: glyph.height),
                           cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)); ctx.fillPath()
        ctx.setFillColor(NSColor.white.withAlphaComponent(a * 0.55).cgColor)          // title-bar hint
        ctx.fill(CGRect(x: p.x + 3, y: p.y + 3, width: glyph.width - 6, height: 2))
    }
}

// ---- controller ----
final class Controller: NSObject, NSPopoverDelegate {
    var tap: CFMachPort?
    var tapSource: CFRunLoopSource?
    var statusItem: NSStatusItem!
    let popover = NSPopover()

    // grab/coast state
    var grabbing = false
    var win: AXUIElement?
    var winSize = CGSize.zero
    var grabOffset = CGVector.zero
    var lastLoc = CGPoint.zero
    var lastTime: CFTimeInterval = 0
    var emaVel = CGVector.zero
    var coastLink: CADisplayLink?
    var coastPos = CGPoint.zero
    var coastVel = CGVector.zero
    var coastBounds = CGRect.zero
    var coastDisplays: [(frame: CGRect, menuBar: CGFloat)] = []   // snapshot per throw: no NSScreen walk per frame
    var coastMass = 1.0
    var coastTau = 0.22, coastRest = 0.35, coastStop = 40.0   // knobs snapshotted per throw, not read per frame
    var shortcutPopup: NSPopUpButton!
    var customItem: NSMenuItem?
    var hintLabel: NSTextField!
    var panelRoot: FlippedView?
    var panelGlass: NSVisualEffectView?
    var advancedOpen = false
    var previewOpen = true
    // Labels the Plain/Notation choice retitles, so it can rewrite text in place instead of rebuilding the
    // panel. Rebuilt every layout; stale entries would point at removed views.
    var retitledLabels: [(field: NSTextField, name: String, sym: String)] = []
    var recordMonitor: Any?                 // non-nil while recording a custom shortcut
    var recordPeak: CGEventFlags = []
    var recording: Bool { recordMonitor != nil }

    func start() {
        UserDefaults.standard.register(defaults: Dictionary(uniqueKeysWithValues: KNOBS.map { ($0.key, $0.def) }))
        UserDefaults.standard.register(defaults: ["previewOpen": true, "massByArea": true])
        previewOpen = UserDefaults.standard.bool(forKey: "previewOpen")
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.05)  // global cap: windowUnder runs inside the event tap, AX must never hang it
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.menuBarIcon()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        popover.behavior = .transient           // click outside to dismiss
        popover.animates = true
        popover.delegate = self
        checkPermissionAndInstall()
    }

    func popoverDidClose(_ n: Notification) {
        cancelRecord()                        // tear down an in-progress recorder
        popover.contentViewController = nil   // detach the views so PreviewStrip loses its window and stops its display link
    }

    @objc func togglePopover() {
        guard let b = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        popover.contentViewController = buildPanel()   // rebuilt each open: correct banner + current values
        if let root = panelRoot { popover.contentSize = root.frame.size }   // match freshly built content, not a stale size from a prior toggle
        NSApp.activate()                               // become active so clicks + key capture are reliable
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    @objc func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // Menu-bar glyph: a window mid-throw trailing speed lines. Template image = auto light/dark tint.
    static func menuBarIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 27, height: 19), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawBrandMark(ctx, in: CGRect(x: 0, y: 0, width: 27, height: 19), color: .black)
            return true
        }
        img.isTemplate = true
        return img
    }

    // Popover shell: root + one persistent glass material. Controls are (re)built by layoutContents,
    // so toggling Advanced re-lays-out in place (reusing the glass) instead of swapping the whole view
    // controller — which flickered.
    func buildPanel() -> NSViewController {
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 10))
        root.clipsToBounds = true
        root.wantsLayer = true              // composite rebuilds/resizes via Core Animation — no full-surface repaint flash
        let glass = NSVisualEffectView()
        glass.material = .popover; glass.blendingMode = .behindWindow; glass.state = .active
        glass.autoresizingMask = [.width, .height]   // always fills root, even mid-resize
        root.addSubview(glass)
        panelRoot = root; panelGlass = glass
        layoutContents()
        let vc = NSViewController(); vc.view = root
        return vc
    }

    func layoutContents() {
        guard let root = panelRoot, let glass = panelGlass else { return }
        root.subviews.filter { $0 !== glass }.forEach { $0.removeFromSuperview() }   // keep the glass, replace controls
        retitledLabels.removeAll()                       // the views they referenced just went away
        let W: CGFloat = 300

        // slim header: just the mark + app name over the glass. 40pt, down from 52: the lockup's ink is
        // only ~18pt tall, so the extra band was all slack and read as a gap above the first control.
        // At 40 the mark's box spans 11.1–29.1 of 40, so there's still clearance top and bottom.
        let hH: CGFloat = 40
        let header = HeaderView(frame: NSRect(x: 0, y: 0, width: W, height: hH))
        header.clipsToBounds = true                 // mark + wordmark drawn as one centered, baseline-aligned lockup
        root.addSubview(header)

        var y: CGFloat = hH + 10

        // First-run flow in the top slot: (1) grant access, then (2) learn the one gesture. Both retire
        // themselves — the CTA once access is granted, the hint after the first successful throw.
        if !AXIsProcessTrusted() {
            // No box: a borderless accent-colored link reads as the OS's own "do this" affordance.
            let banner = NSButton(title: "Grant Accessibility Access", target: self, action: #selector(openAccessibilitySettings))
            banner.isBordered = false
            banner.attributedTitle = NSAttributedString(string: "Grant Accessibility Access",
                attributes: [.foregroundColor: ACCENT, .font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
            let chev = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            banner.image = NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: nil)?.withSymbolConfiguration(chev)
            banner.imagePosition = .imageRight; banner.imageHugsTitle = true
            banner.contentTintColor = ACCENT                 // tints the template chevron to the accent
            (banner.cell as? NSButtonCell)?.alignment = .left
            banner.frame = NSRect(x: 14, y: y, width: W - 28, height: 22)
            root.addSubview(banner)
            y += 22 + 14
        } else if !hasThrown() {
            // Teach the gesture that delivers the aha moment, with the user's actual shortcut. Clears on first throw.
            let body: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 12)]
            let key: [NSAttributedString.Key: Any] = [.foregroundColor: ACCENT, .font: NSFont.systemFont(ofSize: 12, weight: .semibold)]
            let msg = NSMutableAttributedString(string: "Hold ", attributes: body)
            msg.append(NSAttributedString(string: flagsSymbol(activeFlags()), attributes: key))
            msg.append(NSAttributedString(string: " and drag any window, then let go to throw it.", attributes: body))
            let hint = NSTextField(labelWithAttributedString: msg)
            hint.frame = NSRect(x: 14, y: y, width: W - 28, height: 34)
            hint.lineBreakMode = .byWordWrapping; hint.maximumNumberOfLines = 2; hint.cell?.wraps = true
            root.addSubview(hint)
            y += 34 + 14
        }

        // live physics preview — collapsible; a labeled stage that reacts to the sliders in real time
        let pcap = NSButton(title: "Preview", target: self, action: #selector(togglePreview))
        pcap.isBordered = false
        pcap.attributedTitle = NSAttributedString(string: "Preview",
            attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11, weight: .semibold)])
        let pcfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        pcap.image = NSImage(systemSymbolName: previewOpen ? "chevron.down" : "chevron.right",
                             accessibilityDescription: nil)?.withSymbolConfiguration(pcfg)
        pcap.imagePosition = .imageLeft; pcap.imageHugsTitle = true
        pcap.contentTintColor = .secondaryLabelColor
        (pcap.cell as? NSButtonCell)?.alignment = .left
        pcap.frame = NSRect(x: 16, y: y, width: 120, height: 16); root.addSubview(pcap); y += 18
        if previewOpen {
            let ph: CGFloat = 92                       // taller stage so the window's vertical bounce reads
            let preview = PreviewStrip(frame: NSRect(x: 16, y: y, width: W - 32, height: ph))
            preview.toolTip = "Throw a window and inertia carries it. Heavier windows glide farther."
            root.addSubview(preview); y += ph + 16
        } else {
            y += 14                                    // same breathing room before the next section as when open
        }

        // activation: pick the throw shortcut from a menu
        let cap = mkLabel("Activation", 11, .semibold, .secondaryLabelColor)
        cap.frame = NSRect(x: 16, y: y, width: W - 32, height: 14); root.addSubview(cap); y += 18
        shortcutPopup = NSPopUpButton(frame: NSRect(x: 16, y: y, width: W - 32, height: 26), pullsDown: false)
        for (i, f) in SHORTCUTS.enumerated() {
            let item = NSMenuItem(title: flagsSymbol(f),
                                  action: #selector(shortcutPicked(_:)), keyEquivalent: "")
            item.target = self; item.tag = i + 1        // +1 so it never collides with a separator's tag 0
            shortcutPopup.menu?.addItem(item)
        }
        shortcutPopup.menu?.addItem(.separator())
        let ci = NSMenuItem(title: "Custom…", action: #selector(shortcutPicked(_:)), keyEquivalent: "")
        ci.target = self; ci.tag = 100
        shortcutPopup.menu?.addItem(ci); customItem = ci
        shortcutPopup.setAccessibilityLabel("Activation shortcut")   // its caption is a sibling label
        cancelRecord()                                       // clear any stale recorder from a prior open
        root.addSubview(shortcutPopup); y += 26 + 16

        // feel sliders — no numbers, drag to taste
        func sliderRow(_ i: Int) {
            let hit: (Bool) -> Void = { [weak self] over in self?.hintLabel?.stringValue = over ? KNOBS[i].tip : IDLE_HINT }
            let name = HoverText(labelWithString: "")
            name.frame = NSRect(x: 16, y: y, width: W - 32, height: 16)
            name.attributedStringValue = labelText(KNOBS[i].name, KNOBS[i].sym)
            retitledLabels.append((name, KNOBS[i].name, KNOBS[i].sym))
            name.onHover = hit; root.addSubview(name)
            let s = HoverSlider(value: knob(KNOBS[i].key), minValue: KNOBS[i].min, maxValue: KNOBS[i].max,
                                target: self, action: #selector(sliderChanged(_:)))
            s.frame = NSRect(x: 16, y: y + 18, width: W - 32, height: 18)
            s.isContinuous = true; s.tag = i; s.trackFillColor = ACCENT; s.onHover = hit
            s.setAccessibilityLabel(KNOBS[i].name)      // the name is a sibling label, so VoiceOver can't infer it
            s.setAccessibilityHelp(KNOBS[i].tip)
            root.addSubview(s)
            y += 42
        }
        PRIMARY.forEach(sliderRow)

        // toggle rows: hoverable label on the left, NSSwitch on the right. Two of them, one builder.
        func switchRow(_ title: String, _ sym: String, _ tip: String, _ on: Bool, _ action: Selector) {
            let l = HoverText(labelWithString: "")
            l.frame = NSRect(x: 16, y: y + 4, width: W - 80, height: 16)
            l.attributedStringValue = labelText(title, sym)
            retitledLabels.append((l, title, sym))
            l.onHover = { [weak self] over in self?.hintLabel?.stringValue = over ? tip : IDLE_HINT }
            root.addSubview(l)
            let sw = NSSwitch()
            sw.state = on ? .on : .off
            sw.target = self; sw.action = action
            sw.sizeToFit()
            sw.setFrameOrigin(NSPoint(x: W - 16 - sw.frame.width, y: y))
            sw.setAccessibilityLabel(title)          // always the plain name, never the notation
            root.addSubview(sw)
            y += max(sw.frame.height, 20) + 12
        }
        // when on, bigger windows carry more inertia (glide farther, resist starting)
        switchRow("Mass by Area", "m(A)",
                  "Bigger windows carry more inertia, so they glide farther and resist starting.",
                  useMass(), #selector(toggleMass(_:)))
        // Read from the system, not UserDefaults: the user can also remove it in System Settings > Login Items.
        // Words in both label styles; it has no physics symbol.
        switchRow("Open at Login", "Open at Login", "Start Inertia automatically when you log in.",
                  SMAppService.mainApp.status == .enabled, #selector(toggleLogin(_:)))

        // advanced thresholds behind a disclosure — native SF Symbol chevron, not a text triangle
        let disc = NSButton(title: "Advanced", target: self, action: #selector(toggleAdvanced))
        disc.isBordered = false
        disc.attributedTitle = NSAttributedString(string: "Advanced",
            attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 12)])
        let dcfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        disc.image = NSImage(systemSymbolName: advancedOpen ? "chevron.down" : "chevron.right",
                             accessibilityDescription: nil)?.withSymbolConfiguration(dcfg)
        disc.imagePosition = .imageLeft; disc.imageHugsTitle = true
        disc.contentTintColor = .secondaryLabelColor
        (disc.cell as? NSButtonCell)?.alignment = .left
        disc.frame = NSRect(x: 16, y: y, width: 140, height: 20)
        root.addSubview(disc); y += 26
        if advancedOpen {
            ADVANCED.forEach(sliderRow)
            // Segmented, not a switch: both states stay visible, so the control that turns symbols off is
            // never itself hidden behind a symbol. The tip avoids "scientific notation" (that means 1.23e4).
            let lcap = HoverText(labelWithString: "Labels")
            lcap.frame = NSRect(x: 16, y: y, width: W - 32, height: 14)
            lcap.font = .systemFont(ofSize: 11, weight: .semibold); lcap.textColor = .secondaryLabelColor
            let lTip = "Name the controls with words, or with their physics symbols."
            lcap.onHover = { [weak self] over in self?.hintLabel?.stringValue = over ? lTip : IDLE_HINT }
            root.addSubview(lcap); y += 18
            let seg = NSSegmentedControl(labels: ["Standard", "Scientific"], trackingMode: .selectOne,
                                        target: self, action: #selector(labelsChanged(_:)))
            seg.frame = NSRect(x: 16, y: y, width: W - 32, height: 24)   // full width, like the Activation popup
            seg.selectedSegment = useNotation() ? 1 : 0
            seg.setAccessibilityLabel("Labels")     // the segment titles carry the two choices themselves
            root.addSubview(seg); y += 24 + 12
        }

        // inline help line — updates as you hover a slider (reliable where popover tooltips aren't)
        let hint = mkLabel(IDLE_HINT, 11, .regular, .secondaryLabelColor)
        hint.frame = NSRect(x: 16, y: y, width: W - 32, height: 30)
        hint.lineBreakMode = .byWordWrapping; hint.maximumNumberOfLines = 2; hint.cell?.wraps = true
        hintLabel = hint; root.addSubview(hint); y += 34

        // footer — icon buttons (reset left, quit right)
        let sep = NSBox(frame: NSRect(x: 16, y: y, width: W - 32, height: 1)); sep.boxType = .separator
        root.addSubview(sep); y += 12
        let reset = iconButton("arrow.counterclockwise", "Reset to defaults", #selector(resetKnobs))
        reset.frame = NSRect(x: 14, y: y, width: 30, height: 26); root.addSubview(reset)
        let quit = iconButton("power", "Quit Inertia", #selector(quit))
        quit.frame = NSRect(x: W - 14 - 30, y: y, width: 30, height: 26); root.addSubview(quit)
        // version centered between the two icon buttons: tertiary label color and 10pt, so it reads as a
        // footnote rather than a control, but it answers "which build am I actually running?" at a glance.
        let v = appVersion()
        let ver = HoverText(labelWithString: "\(v.short) (\(v.build))")
        ver.frame = NSRect(x: 44, y: y + 6, width: W - 88, height: 14)   // +6 centers it on the 26pt buttons
        ver.alignment = .center
        ver.font = .systemFont(ofSize: 10); ver.textColor = .tertiaryLabelColor
        ver.setAccessibilityLabel("Version \(v.short), build \(v.build)")   // spoken, not read as punctuation
        ver.onHover = { [weak self] over in
            self?.hintLabel?.stringValue = over ? "Inertia \(v.short), build \(v.build). The copy running now." : IDLE_HINT }
        root.addSubview(ver)
        y += 26 + 12

        root.frame = NSRect(x: 0, y: 0, width: W, height: y)
        glass.frame = root.bounds                  // fill the whole panel with the glass material
    }

    private func mkLabel(_ s: String, _ size: CGFloat, _ w: NSFont.Weight, _ c: NSColor) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: size, weight: w); t.textColor = c
        return t
    }
    private func iconButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(cfg)
        let b = HoverButton(image: img ?? NSImage(), target: self, action: action)
        b.isBordered = false; b.imagePosition = .imageOnly       // just the glyph, no button chrome
        b.contentTintColor = .secondaryLabelColor; b.restTint = .secondaryLabelColor  // brightens on hover
        b.toolTip = label; b.setAccessibilityLabel(label)        // icon-only needs a text label
        return b
    }

    // --- activation: pick from the menu, or "Custom…" to record any combo ---
    @objc func shortcutPicked(_ sender: NSMenuItem) {
        if sender.tag == 100 { startRecording(); return }
        endRecordMonitor()
        let i = sender.tag - 1
        guard SHORTCUTS.indices.contains(i) else { return }
        setFlags(SHORTCUTS[i]); refreshShortcutSelection()
    }

    // Reflect activeFlags() in the popup: select the matching item, or show it on the Custom row.
    func refreshShortcutSelection() {
        guard let popup = shortcutPopup else { return }
        let f = activeFlags()
        if recording { customItem?.title = "Press keys…"; if let ci = customItem { popup.select(ci) }; return }
        if let idx = SHORTCUTS.firstIndex(of: f) {
            customItem?.title = "Custom…"; popup.selectItem(withTag: idx + 1)
        } else {
            customItem?.title = flagsSymbol(f); if let ci = customItem { popup.select(ci) }
        }
    }

    func startRecording() {
        endRecordMonitor()                       // never stack monitors
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] ev in
            guard let self, self.recording else { self?.endRecordMonitor(); return ev }  // stale monitor self-heals
            if ev.type == .keyDown { if ev.keyCode == 53 { self.cancelRecord() }; return ev }  // Esc cancels
            let cur = cgFlags(from: ev.modifierFlags)
            if !cur.isEmpty {
                self.recordPeak.formUnion(cur)
                self.customItem?.title = flagsSymbol(self.recordPeak)                 // live preview
            } else if !self.recordPeak.isEmpty {
                self.commitRecord()                                                   // released all → commit
            }
            return ev
        }
        refreshShortcutSelection()               // shows "Press keys…"
    }

    func commitRecord() {
        guard recording else { return }
        let f = recordPeak
        endRecordMonitor()
        guard !f.isEmpty else { refreshShortcutSelection(); return }
        setFlags(f); refreshShortcutSelection()
    }

    func cancelRecord() {
        endRecordMonitor()
        refreshShortcutSelection()               // restores from the (unchanged) stored flags
    }

    func endRecordMonitor() { if let m = recordMonitor { NSEvent.removeMonitor(m) }; recordMonitor = nil; recordPeak = [] }

    @objc func toggleAdvanced() {
        advancedOpen.toggle()
        layoutContents()                                   // reuse the glass + view controller — no flicker
        if let root = panelRoot { popover.contentSize = root.frame.size }   // grow/shrink smoothly
    }

    @objc func togglePreview() {
        previewOpen.toggle()
        UserDefaults.standard.set(previewOpen, forKey: "previewOpen")   // remember the choice
        layoutContents()
        if let root = panelRoot { popover.contentSize = root.frame.size }
    }

    @objc func toggleMass(_ s: NSSwitch) {
        UserDefaults.standard.set(s.state == .on, forKey: "massByArea")   // takes effect on the next throw
    }

    @objc func toggleLogin(_ s: NSSwitch) {
        do { try s.state == .on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
        catch { NSLog("Inertia: login item change failed: \(error)") }
        s.state = SMAppService.mainApp.status == .enabled ? .on : .off   // show what actually happened
    }

    @objc func labelsChanged(_ s: NSSegmentedControl) {
        UserDefaults.standard.set(s.selectedSegment == 1, forKey: "notationLabels")
        // Retitle in place. layoutContents() would tear down and rebuild every control for what is only a
        // text change — recreating the PreviewStrip (restarting its display link mid-flight) and making the
        // popover re-lay-out under the cursor. Row geometry doesn't depend on the label, so nothing moves
        // and contentSize is untouched.
        for l in retitledLabels { l.field.attributedStringValue = labelText(l.name, l.sym) }
    }

    @objc func sliderChanged(_ sender: NSSlider) {
        UserDefaults.standard.set(sender.doubleValue, forKey: KNOBS[sender.tag].key)
    }

    @objc func resetKnobs() {
        for k in KNOBS { UserDefaults.standard.set(k.def, forKey: k.key) }
        UserDefaults.standard.set(true, forKey: "massByArea")   // mass-by-area is on by default
        UserDefaults.standard.set(false, forKey: "notationLabels")
        setFlags(DEFAULT_FLAGS)
        endRecordMonitor()
        layoutContents()                                        // rebuild so sliders, switch, and shortcut reflect defaults
        if let root = panelRoot { popover.contentSize = root.frame.size }
    }

    @objc func quit() { NSApp.terminate(nil) }

    func checkPermissionAndInstall() {
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)  // system prompt; the panel banner deep-links the pane
        }
        reconcileTap()
        // Re-check when the Accessibility list changes (grant or revoke) instead of polling: the old 0.5s
        // timer created and destroyed a real event tap twice a second for the life of the process. A revoke
        // also disables the live tap, which handle() already routes to removeTap + reconcileTap.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.accessibility.api"),
                                                            object: nil, queue: .main) { [weak self] _ in
            // TCC posts before its own state settles; a short delay makes hasAccess() see the new answer
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.reconcileTap() }
        }
    }

    func installTap() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.leftMouseDown.rawValue) |
                   (1 << CGEventType.leftMouseDragged.rawValue) |
                   (1 << CGEventType.leftMouseUp.rawValue)
        let cb: CGEventTapCallBack = { _, type, event, refcon in
            let c = Unmanaged<Controller>.fromOpaque(refcon!).takeUnretainedValue()
            return c.handle(type, event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                        callback: cb, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            NSLog("Inertia: event tap creation failed"); return
        }
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t; tapSource = src
    }

    // Safety: an active tap that swallows mouse input must not outlive Accessibility trust, or a
    // revoked app could hijack the pointer. Tear it down the moment trust is lost.
    func removeTap() {
        if let s = tapSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), s, .commonModes); CFRunLoopSourceInvalidate(s) }
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        tap = nil; tapSource = nil
        grabbing = false; win = nil     // a grab can't outlive its tap: a reinstalled tap would swallow
                                        // the next unrelated drag and yank the stale window to the cursor
    }
    // AXIsProcessTrusted() caches a stale "true" after the user revokes access, which would leave a
    // dead-but-active tap stalling all input. Check for real by trying to create a throwaway tap —
    // that reflects the CURRENT permission and returns nil once access is gone.
    func hasAccess() -> Bool {
        guard let probe = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: CGEventMask(1) << CGEventType.null.rawValue,
                callback: { _, _, e, _ in Unmanaged.passUnretained(e) }, userInfo: nil) else { return false }
        CGEvent.tapEnable(tap: probe, enable: false); CFMachPortInvalidate(probe)
        return true
    }
    func reconcileTap() {
        if hasAccess() { if tap == nil { installTap() } }
        else if tap != nil { removeTap() }
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Never blindly re-arm: on revoke the system disables the tap, and re-enabling it just
            // re-stalls input. Tear it down; the reconciler reinstalls only if access is really present.
            DispatchQueue.main.async { [weak self] in self?.removeTap(); self?.reconcileTap() }
            return Unmanaged.passUnretained(event)
        case .leftMouseDown:
            if coastLink != nil { stopCoast() }                     // click cancels a coasting window
            // Only ever swallow input while trusted (fast local check, no IPC) — the guard that keeps
            // a revoked app from eating the user's clicks.
            if AXIsProcessTrusted(), flagsMatch(event.flags), let w = windowUnder(event.location) {
                beginGrab(w, at: event.location)
                if grabbing { return nil }              // swallow only once the grab engaged — if the AX
            }                                           // reads failed, let the click through untouched
            return Unmanaged.passUnretained(event)
        case .leftMouseDragged:
            if grabbing { updateDrag(event.location); return nil }
            return Unmanaged.passUnretained(event)
        case .leftMouseUp:
            if grabbing { endGrab(); return nil }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    func beginGrab(_ w: AXUIElement, at loc: CGPoint) {
        // A fullscreen (or otherwise pinned) window reports position as read-only. Without this we'd
        // swallow the whole click-drag-release and move nothing — the gesture would just eat the click.
        // Only bail on a definitive "no"; an app whose AX errors here still gets the benefit of the doubt.
        var settable = DarwinBoolean(true)
        if AXUIElementIsAttributeSettable(w, kAXPositionAttribute as CFString, &settable) == .success,
           !settable.boolValue { return }
        guard let pos = axGetPoint(w), let size = axGetSize(w) else { return }
        stopCoast()
        win = w; winSize = size
        grabOffset = CGVector(dx: loc.x - pos.x, dy: loc.y - pos.y)
        lastLoc = loc; lastTime = CACurrentMediaTime(); emaVel = .zero
        grabbing = true
    }

    func updateDrag(_ loc: CGPoint) {
        guard let w = win else { return }
        let now = CACurrentMediaTime(), dt = max(now - lastTime, 1e-4)
        let inst = CGVector(dx: (loc.x - lastLoc.x) / dt, dy: (loc.y - lastLoc.y) / dt)
        // ponytail: EMA velocity (alpha .4) instead of a timestamped ring buffer; upgrade if flicks feel laggy
        emaVel = CGVector(dx: emaVel.dx * 0.6 + inst.dx * 0.4, dy: emaVel.dy * 0.6 + inst.dy * 0.4)
        lastLoc = loc; lastTime = now
        axSetPoint(w, CGPoint(x: loc.x - grabOffset.dx, y: loc.y - grabOffset.dy))
    }

    func endGrab() {
        grabbing = false
        guard let w = win, let pos = axGetPoint(w) else { return }
        emaVel = releaseVelocity(emaVel, idleFor: CACurrentMediaTime() - lastTime)
        coastMass = useMass() ? massFactor(winSize) : 1.0          // window inertia (off → every window the same)
        if hypot(emaVel.dx, emaVel.dy) < knob("minReleaseSpeed") * coastMass { return }  // heavier resists starting
        if !hasThrown() { UserDefaults.standard.set(true, forKey: "hasThrown") }  // first throw retires the first-run hint
        let gain = knob("launchGain")
        coastTau = knob("glideTime") * coastMass; coastRest = knob("restitution"); coastStop = knob("restSpeed")
        coastPos = pos; coastVel = CGVector(dx: emaVel.dx * gain, dy: emaVel.dy * gain)
        coastDisplays = activeDisplays()
        coastBounds = coastDisplays.map { $0.frame }.reduce(.null) { $0.union($1) }
        if coastBounds.isNull || coastBounds.isEmpty { return }   // displays mid-reconfigure: no bounds, no coast
        // ponytail: union rect, so an L-shaped layout has dead space a window can park in; clamp to the nearest display if reported
        // Vsync-locked coast (macOS 14+): fires at the display's native rate, so it stays smooth on
        // ProMotion and does no wasted AX writes on 60Hz — unlike a fixed 120Hz Timer.
        let link = NSScreen.main?.displayLink(target: self, selector: #selector(coastTick(_:)))
        link?.add(to: .main, forMode: .common)
        coastLink = link
    }

    @objc func coastTick(_ link: CADisplayLink) {
        guard let w = win else { stopCoast(); return }
        let dt = min(max(link.targetTimestamp - link.timestamp, 1e-4), 0.05)  // vsync frame time, stall-clamped
        // coastPos is the window's top-left, so its title bar's midpoint decides which menu bar fences it
        let bounds = coastRect(coastBounds, titleBar: CGPoint(x: coastPos.x + winSize.width / 2, y: coastPos.y), coastDisplays)
        (coastPos, coastVel) = coastStep(pos: coastPos, vel: coastVel, size: winSize, bounds: bounds,
                                         dt: dt, tau: coastTau, restitution: coastRest)
        axSetPoint(w, coastPos)
        if hypot(coastVel.dx, coastVel.dy) < coastStop { stopCoast() }
    }

    func stopCoast() { coastLink?.invalidate(); coastLink = nil }
}

// ---- main ----
if CommandLine.arguments.contains("--selftest") { runSelfTest(); exit(0) }
// Single instance: a second copy (a dev build next to the installed one, or the binary run directly)
// would add a second menu-bar icon and a second event tap fighting over the same drags.
let myPID = ProcessInfo.processInfo.processIdentifier
if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
    .contains(where: { $0.processIdentifier != myPID }) {
    NSLog("Inertia: another instance is already running; exiting")
    exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
controller.start()
app.run()
