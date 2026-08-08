// Generates the Inertia app icon (Inertia.icns) — reproducible, no design tool needed.
// Metaphor: a macOS window thrown to the right, trailing motion-blur speed lines (inertia).
// Run: cd art && swiftc makeicons.swift -o makeicons -framework Cocoa -framework ImageIO && ./makeicons
//      iconutil -c icns icon.iconset -o ../Inertia.icns
import Cocoa
import ImageIO
import UniformTypeIdentifiers

let CS = CGColorSpaceCreateDeviceRGB()
func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: CS, components: [r, g, b, a])!
}

// Draw the icon in a fixed 1024 coordinate space, scaled to the target pixel size.
func drawAppIcon(_ ctx: CGContext, _ px: CGFloat) {
    ctx.saveGState()
    ctx.scaleBy(x: px / 1024, y: px / 1024)

    // --- rounded-square tile (macOS art area: 824 inset 100) ---
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.clip()

    // diagonal indigo -> azure gradient (velocity)
    let bg = CGGradient(colorsSpace: CS, colors: [rgb(0.30, 0.21, 0.86), rgb(0.09, 0.62, 0.96)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 170, y: 854), end: CGPoint(x: 854, y: 170), options: [])
    // soft top sheen for depth
    let sheen = CGGradient(colorsSpace: CS, colors: [rgb(1, 1, 1, 0.18), rgb(1, 1, 1, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 500), options: [])

    let win = CGRect(x: 452, y: 372, width: 372, height: 300)

    // --- motion trails behind the window: fade from clear (tail) to white (head) ---
    func trail(y: CGFloat, tail: CGFloat, thick: CGFloat) {
        let head: CGFloat = 500                       // runs under the window so it reads as attached
        let r = CGRect(x: tail, y: y - thick / 2, width: head - tail, height: thick)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: thick / 2, cornerHeight: thick / 2, transform: nil))
        ctx.clip()
        let g = CGGradient(colorsSpace: CS, colors: [rgb(1, 1, 1, 0), rgb(1, 1, 1, 0.95)] as CFArray,
                           locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: tail, y: y), end: CGPoint(x: head, y: y), options: [])
        ctx.restoreGState()
    }
    trail(y: 606, tail: 300, thick: 30)
    trail(y: 512, tail: 168, thick: 34)               // longest = fastest
    trail(y: 430, tail: 250, thick: 30)

    // --- window (white, soft drop shadow), tilted in flight ---
    ctx.saveGState()
    ctx.translateBy(x: win.midX, y: win.midY); ctx.rotate(by: -0.13); ctx.translateBy(x: -win.midX, y: -win.midY)
    let winPath = CGPath(roundedRect: win, cornerWidth: 46, cornerHeight: 46, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 44, color: rgb(0, 0, 0, 0.30))
    ctx.addPath(winPath); ctx.setFillColor(rgb(1, 1, 1)); ctx.fillPath()
    ctx.restoreGState()

    // title bar + traffic-light dots + two content lines
    ctx.saveGState(); ctx.addPath(winPath); ctx.clip()
    let barH: CGFloat = 72
    ctx.setFillColor(rgb(0.93, 0.94, 0.96)); ctx.fill(CGRect(x: win.minX, y: win.maxY - barH, width: win.width, height: barH))
    ctx.setFillColor(rgb(0.84, 0.86, 0.90)); ctx.fill(CGRect(x: win.minX, y: win.maxY - barH, width: win.width, height: 3))
    let dotY = win.maxY - barH / 2
    let dots = [rgb(1, 0.37, 0.34), rgb(1, 0.74, 0.18), rgb(0.20, 0.80, 0.35)]
    for (i, c) in dots.enumerated() {
        ctx.setFillColor(c)
        ctx.fillEllipse(in: CGRect(x: win.minX + 36 + CGFloat(i) * 48 - 14, y: dotY - 14, width: 28, height: 28))
    }
    ctx.setFillColor(rgb(0.86, 0.88, 0.91))
    for (i, w) in [win.width - 150, win.width - 80].enumerated() {
        let y = win.minY + 96 - CGFloat(i) * 46
        ctx.addPath(CGPath(roundedRect: CGRect(x: win.minX + 42, y: y, width: w, height: 20),
                           cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.fillPath()
    }
    ctx.restoreGState()   // content clip
    ctx.restoreGState()   // tilt
    ctx.restoreGState()   // icon tile
}

func render(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CS, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    drawAppIcon(ctx, CGFloat(px))
    return ctx.makeImage()!
}
func writePNG(_ img: CGImage, _ path: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                               UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    _ = CGImageDestinationFinalize(dest)
}

let dir = "icon.iconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        writePNG(render(px), "\(dir)/\(name)")
    }
}
print("wrote \(dir) — now: iconutil -c icns \(dir) -o ../Inertia.icns")
