// Draws the app icon: a padlock whose shackle is a looping arrow, on a soft dusk tile.
// Usage: swift scripts/make-icon.swift <out.png>   (1024 x 1024)
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Tile on Apple's icon grid: 824 x 824, inset 100, continuous-ish corners.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: c(0x000000, 0.25))
ctx.addPath(tilePath); ctx.setFillColor(c(0xF6F3ED)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState(); ctx.addPath(tilePath); ctx.clip()
let sky = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [c(0xF4B98A), c(0xE9A0A6), c(0x7D8FC9)] as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
ctx.restoreGState()

let ink = c(0x24283A)
// Shackle: a loop (about 300 degrees) ending in an arrowhead, so it reads as "lock" and "loop".
let centre = CGPoint(x: 512, y: 560)
let r: CGFloat = 165
let line: CGFloat = 62
let start = CGFloat.pi * 0.0, end = CGFloat.pi * 1.0   // upper half, drawn left to right over the top
ctx.setStrokeColor(ink); ctx.setLineWidth(line); ctx.setLineCap(.round)
ctx.addArc(center: centre, radius: r, startAngle: end, endAngle: start + 0.38, clockwise: true)
ctx.strokePath()
// Arrowhead at the right end, pointing down into the lock body.
let tipAngle = start + 0.38
let tip = CGPoint(x: centre.x + r * cos(tipAngle), y: centre.y + r * sin(tipAngle))
let head: CGFloat = 70
ctx.setFillColor(ink)
ctx.move(to: CGPoint(x: tip.x - head, y: tip.y + 6))
ctx.addLine(to: CGPoint(x: tip.x + head, y: tip.y + 6))
ctx.addLine(to: CGPoint(x: tip.x, y: tip.y - head * 1.05))
ctx.closePath(); ctx.fillPath()

// Body.
let body = CGRect(x: 292, y: 210, width: 440, height: 340)
ctx.addPath(CGPath(roundedRect: body, cornerWidth: 70, cornerHeight: 70, transform: nil))
ctx.setFillColor(ink); ctx.fillPath()
// A little "play" triangle as the keyhole: it plays a video.
ctx.setFillColor(c(0xF6F3ED))
ctx.move(to: CGPoint(x: 478, y: 318)); ctx.addLine(to: CGPoint(x: 478, y: 442)); ctx.addLine(to: CGPoint(x: 580, y: 380))
ctx.closePath(); ctx.fillPath()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
