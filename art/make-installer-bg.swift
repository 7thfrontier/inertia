import Cocoa
import ImageIO
import UniformTypeIdentifiers
// Installer sidebar signature: brand mark + "Inertia" wordmark, azure (reads on light + dark chrome).
// Rendered 1x so `scaling="none"` places it at point-size and it fits the sidebar without the
// wordmark sliding under the content pane. Regenerate: swiftc + run, outputs packaging/resources/installer_bg.png
func drawBrandMark(_ ctx: CGContext, in rect: CGRect, color: NSColor) {
    ctx.saveGState(); ctx.translateBy(x: rect.minX, y: rect.minY); ctx.scaleBy(x: rect.width/26, y: rect.height/18)
    ctx.setFillColor(color.cgColor); ctx.setStrokeColor(color.cgColor); ctx.setLineJoin(.round); ctx.setLineCap(.round)
    func s(_ y:CGFloat,_ x0:CGFloat,_ th:CGFloat){ ctx.move(to:CGPoint(x:10.5,y:y-th/2)); ctx.addLine(to:CGPoint(x:10.5,y:y+th/2)); ctx.addLine(to:CGPoint(x:x0,y:y)); ctx.closePath(); ctx.fillPath() }
    s(5.5,3.5,2.4); s(9,0.5,2.8); s(12.5,4.5,2.4)
    ctx.saveGState(); ctx.translateBy(x:18,y:9); ctx.rotate(by: -0.16); ctx.translateBy(x:-18,y:-9)
    ctx.setLineWidth(1.7); ctx.addPath(CGPath(roundedRect: CGRect(x:12.5,y:3.5,width:11.5,height:11), cornerWidth:2.6, cornerHeight:2.6, transform:nil)); ctx.strokePath()
    ctx.setLineWidth(1.5); ctx.move(to:CGPoint(x:13.4,y:11)); ctx.addLine(to:CGPoint(x:23.1,y:11)); ctx.strokePath()
    ctx.restoreGState(); ctx.restoreGState()
}
let ptW = 210.0, ptH = 84.0, scale = 2.0        // 210x84 points, drawn at 2x for retina crispness
let W = Int(ptW * scale), H = Int(ptH * scale)
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data:nil,width:W,height:H,bitsPerComponent:8,bytesPerRow:0,space:cs,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: scale, y: scale)                 // draw in point coords, 2x pixels
let brand = NSColor(srgbRed: 0.16, green: 0.56, blue: 0.94, alpha: 1)
drawBrandMark(ctx, in: CGRect(x: 22, y: 30, width: 40, height: 40*18/26), color: brand)
let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
("Inertia" as NSString).draw(at: NSPoint(x: 72, y: 31), withAttributes: [.font: NSFont.systemFont(ofSize: 19, weight: .bold), .foregroundColor: brand])
NSGraphicsContext.restoreGraphicsState()
let props: [CFString: Any] = [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144]   // 2x → point size = px/2
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "packaging/resources/installer_bg.png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary); CGImageDestinationFinalize(dest)
print("wrote installer_bg.png (\(W)x\(H) px @144dpi → \(Int(ptW))x\(Int(ptH)) pt)")
