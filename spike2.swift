// spike2.swift — per-app AX repositioning throughput across ALL running windowed apps.
// Tells us which app types are cooperative and which are janky.
// Build: swiftc spike2.swift -o spike2 -framework Cocoa -framework ApplicationServices
import Cocoa
import ApplicationServices

func getPos(_ w: AXUIElement) -> CGPoint? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &v) == .success else { return nil }
    var p = CGPoint.zero; AXValueGetValue(v as! AXValue, .cgPoint, &p); return p
}
func setPos(_ w: AXUIElement, _ p: CGPoint) -> Bool {
    var pt = p; let v = AXValueCreate(.cgPoint, &pt)!
    return AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) == .success
}
func firstWindow(_ pid: pid_t) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    var wins: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &wins) == .success,
          let arr = wins as? [AXUIElement] else { return nil }
    return arr.first
}

guard AXIsProcessTrusted() else { print("NOT TRUSTED"); exit(1) }

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count) }
func f2(_ x: Double) -> String { String(format: "%.2f", x) }
func f0(_ x: Double) -> String { String(format: "%.0f", x) }

let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
print("\(pad("app",24)) \(pad("ms/set",10)) \(pad("maxfps",10))")
print(String(repeating: "-", count: 46))
let N = 120
for a in apps {
    guard let w = firstWindow(a.processIdentifier), let origin = getPos(w) else { continue }
    let start = Date()
    for i in 0..<N { _ = setPos(w, CGPoint(x: origin.x + CGFloat(i % 30), y: origin.y)) }
    let dt = Date().timeIntervalSince(start)
    _ = setPos(w, origin)
    let ms = dt/Double(N)*1000, fps = Double(N)/dt
    let flag = fps < 60 ? "  <-- JANK" : (fps < 120 ? "  <- tight" : "")
    print("\(pad(a.localizedName ?? "?",24)) \(pad(f2(ms),10)) \(pad(f0(fps),10))\(flag)")
}
