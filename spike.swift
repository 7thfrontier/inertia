// spike.swift — measure the one number the feasibility hinges on:
// how many times/sec can we reposition ANOTHER app's window via the Accessibility API?
// Build: swiftc spike.swift -o spike -framework Cocoa -framework ApplicationServices
// Run:   ./spike            (benchmark: throughput + visible sweep on frontmost window)
// Grant Accessibility to whatever runs it (Terminal/iTerm) or it'll tell you to.

import Cocoa
import ApplicationServices

func trusted() -> Bool { AXIsProcessTrusted() }

// Frontmost window of the frontmost *other* app (not us).
func targetWindow() -> (AXUIElement, pid_t)? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let pid = app.processIdentifier
    let axApp = AXUIElementCreateApplication(pid)
    var win: CFTypeRef?
    if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &win) == .success,
       let w = win {
        return ((w as! AXUIElement), pid)
    }
    // fallback: first window
    var wins: CFTypeRef?
    if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &wins) == .success,
       let arr = wins as? [AXUIElement], let first = arr.first {
        return (first, pid)
    }
    return nil
}

func getPos(_ w: AXUIElement) -> CGPoint? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &v) == .success else { return nil }
    var p = CGPoint.zero
    AXValueGetValue(v as! AXValue, .cgPoint, &p)
    return p
}

func setPos(_ w: AXUIElement, _ p: CGPoint) -> Bool {
    var pt = p
    let v = AXValueCreate(.cgPoint, &pt)!
    return AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) == .success
}

guard trusted() else {
    print("NOT TRUSTED. Grant Accessibility to the terminal running this, then rerun.")
    print("System Settings > Privacy & Security > Accessibility.")
    exit(1)
}

guard let (win, pid) = targetWindow(), let origin = getPos(win) else {
    print("No target window found. Click a normal app window (Finder/TextEdit) first.")
    exit(1)
}

let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
print("Target: \(appName)  origin=\(origin)")

// --- Throughput: how many setPos round-trips/sec can we sustain? ---
let N = 300
let start = Date()
var ok = 0
for i in 0..<N {
    let p = CGPoint(x: origin.x + CGFloat(i % 40), y: origin.y) // tiny jiggle, stays on screen
    if setPos(win, p) { ok += 1 }
}
let dt = Date().timeIntervalSince(start)
let rate = Double(N) / dt
print(String(format: "Throughput: %d sets in %.3fs = %.0f sets/sec (%.2f ms/set), %d ok",
             N, dt, rate, dt/Double(N)*1000, ok))
print(String(format: "=> ceiling ~%.0f fps for continuous repositioning of THIS app", rate))

// --- Visible sweep so you can eyeball jank: coast right with decaying velocity ---
print("Sweeping (watch the window)...")
var pos = origin
var vel = CGVector(dx: 26, dy: 0)   // px/frame
let friction = 0.96
let frameTime = 1.0/60.0
while abs(vel.dx) > 0.5 {
    let f0 = Date()
    pos.x += vel.dx
    vel.dx *= friction
    _ = setPos(win, pos)
    let spent = Date().timeIntervalSince(f0)
    if spent < frameTime { usleep(useconds_t((frameTime - spent) * 1_000_000)) }
}
_ = setPos(win, origin) // put it back
print("Done. Restored to origin.")
