// Renders the app icon (1024×1024 PNG) — run: swift scripts/make-icon.swift out.png
// Design: macOS squircle, dusk gradient, a speaker cone with stereo sound waves.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Squircle with Apple's icon grid inset (824 px body on a 1024 canvas) + soft drop shadow.
let inset: CGFloat = 100
let body = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(squircle); ctx.setFillColor(color(0x1B1640)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                    colors: [color(0x14123A), color(0x4C1D95), color(0xDB2777), color(0xFB923C)] as CFArray,
                    locations: [0, 0.42, 0.78, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
// Glow behind the speaker.
let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                      colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
let c = CGPoint(x: size / 2, y: size / 2 - 6)
ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: 330, options: [])
// Subtle top highlight.
let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                       colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY + 60), options: [])
ctx.restoreGState()

// Speaker cone: outer ring, inner disc, dust cap.
ctx.setFillColor(color(0xFFFFFF, 0.96))
ctx.fillEllipse(in: CGRect(x: c.x - 150, y: c.y - 150, width: 300, height: 300))
let cone = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                      colors: [color(0x2A2160), color(0x5B21B6)] as CFArray, locations: [0, 1])!
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: c.x - 118, y: c.y - 118, width: 236, height: 236)); ctx.clip()
ctx.drawRadialGradient(cone, startCenter: CGPoint(x: c.x - 30, y: c.y + 30), startRadius: 0, endCenter: c, endRadius: 130, options: [])
ctx.restoreGState()
ctx.setFillColor(color(0xFFFFFF, 0.96))
ctx.fillEllipse(in: CGRect(x: c.x - 46, y: c.y - 46, width: 92, height: 92))

// Stereo sound waves left and right.
ctx.setLineCap(.round)
for (i, r) in [CGFloat(215), 290].enumerated() {
    ctx.setStrokeColor(color(0xFFFFFF, i == 0 ? 0.9 : 0.55))
    ctx.setLineWidth(i == 0 ? 34 : 28)
    for start in [-CGFloat.pi / 4.2, .pi - .pi / 4.2] {
        ctx.addArc(center: c, radius: r, startAngle: start, endAngle: start + .pi / 2.1, clockwise: false)
        ctx.strokePath()
    }
}

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
