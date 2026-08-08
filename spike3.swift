// spike3.swift — last unproven primitive: screen point -> the AXUIElement WINDOW under it.
// At throw grab-time we have a mouse point; we must resolve it to a movable window handle,
// cache that handle, then coast it. Read-only here (identify only, no move) to stay non-disruptive.
// Build: swiftc spike3.swift -o spike3 -framework Cocoa -framework ApplicationServices
import Cocoa
import ApplicationServices

func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
func role(_ e: AXUIElement) -> String { (attr(e, kAXRoleAttribute as String) as? String) ?? "?" }

// Walk up the AX parent chain until we hit the window element.
func windowFor(_ e: AXUIElement) -> AXUIElement? {
    var cur: AXUIElement? = e
    for _ in 0..<12 {
        guard let c = cur else { return nil }
        if role(c) == (kAXWindowRole as String) { return c }
        cur = attr(c, kAXParentAttribute as String).map { $0 as! AXUIElement }
    }
    return nil
}

guard AXIsProcessTrusted() else { print("NOT TRUSTED"); exit(1) }

// Cocoa mouse loc is bottom-left origin; AXUIElementCopyElementAtPosition wants top-left (CG) coords.
let m = NSEvent.mouseLocation
let screenH = NSScreen.screens.first(where: { $0.frame.contains(m) })?.frame.maxY ?? NSScreen.main!.frame.maxY
let pt = CGPoint(x: m.x, y: screenH - m.y)

let sys = AXUIElementCreateSystemWide()
var hit: AXUIElement?
let err = AXUIElementCopyElementAtPosition(sys, Float(pt.x), Float(pt.y), &hit)
guard err == .success, let el = hit else { print("no element at \(pt) (err \(err.rawValue))"); exit(1) }

print("Element under cursor: role=\(role(el))")
guard let win = windowFor(el) else { print("could not walk to a window element"); exit(1) }

let title = (attr(win, kAXTitleAttribute as String) as? String) ?? "(untitled)"
var pidv: pid_t = 0; AXUIElementGetPid(win, &pidv)
let app = NSRunningApplication(processIdentifier: pidv)?.localizedName ?? "pid \(pidv)"
var posv: CFTypeRef? = attr(win, kAXPositionAttribute as String)
var pos = CGPoint.zero; if let pv = posv { AXValueGetValue(pv as! AXValue, .cgPoint, &pos) }
print("=> WINDOW: app=\(app)  title=\"\(title)\"  pos=\(pos)")
print("Resolved a movable window handle from a raw screen point. Grab-time targeting works.")
