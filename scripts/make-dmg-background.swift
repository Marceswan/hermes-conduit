// Renders the Conduit DMG background (1x + 2x PNG, combined into background.tiff).
// Usage: swift scripts/make-dmg-background.swift <out-dir> <version>
// All artwork (gradient, caduceus, arrow) is original vector drawing code.
import AppKit
import Foundation

let W: CGFloat = 640
let H: CGFloat = 400

guard CommandLine.arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: make-dmg-background.swift <out-dir> <version>\n".utf8))
    exit(2)
}
let outDir = CommandLine.arguments[1]
let version = CommandLine.arguments[2]
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Icon slots (top-left origin coordinates; must match dmg-settings.py).
let appSlot = CGPoint(x: 170, y: 190)
let applicationsSlot = CGPoint(x: 470, y: 190)

func drawCaduceus(_ g: CGContext) {
    let cx = W / 2
    g.saveGState()
    g.setAlpha(0.15)
    g.beginTransparencyLayer(auxiliaryInfo: nil)
    g.setFillColor(rgb(0xFFFFFF))
    g.setStrokeColor(rgb(0xFFFFFF))
    g.setLineCap(.round)
    g.setLineJoin(.round)

    let topY: CGFloat = 52, bottomY: CGFloat = 362

    // Wings: layered feather arcs, mirrored about the staff.
    let tips: [(dx: CGFloat, y: CGFloat)] = [(178, 66), (166, 96), (146, 124), (118, 148)]
    for s in [CGFloat(-1), 1] {
        for (i, t) in tips.enumerated() {
            let rootX = cx + s * 8
            let rootY = 104 + CGFloat(i) * 9
            let tip = CGPoint(x: cx + s * t.dx, y: t.y)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: rootX, y: rootY))
            // upper edge bows up and out, lower edge returns with a fuller belly
            p.addCurve(to: tip,
                       control1: CGPoint(x: cx + s * (t.dx * 0.35), y: rootY - 34),
                       control2: CGPoint(x: cx + s * (t.dx * 0.8), y: t.y - 14))
            p.addCurve(to: CGPoint(x: rootX, y: rootY + 10),
                       control1: CGPoint(x: cx + s * (t.dx * 0.78), y: t.y + 30),
                       control2: CGPoint(x: cx + s * (t.dx * 0.40), y: rootY + 24))
            p.closeSubpath()
            g.addPath(p)
            g.fillPath()
        }
    }

    // Staff
    g.setLineWidth(9)
    g.move(to: CGPoint(x: cx, y: topY + 10))
    g.addLine(to: CGPoint(x: cx, y: bottomY))
    g.strokePath()

    // Orb
    g.fillEllipse(in: CGRect(x: cx - 17, y: topY - 17, width: 34, height: 34))

    // Snakes: symmetric S-curves winding the staff
    let sTop: CGFloat = 118, sBottom: CGFloat = 330
    let amp: CGFloat = 46
    for s in [CGFloat(-1), 1] {
        let path = CGMutablePath()
        let n = 120
        for k in 0...n {
            let t = CGFloat(k) / CGFloat(n)
            let taper = 1 - 0.0 * t
            let x = cx + s * amp * taper * sin(t * 2 * .pi * 1.5)
            let y = sTop + (sBottom - sTop) * t
            if k == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        g.setLineWidth(8)
        g.addPath(path)
        g.strokePath()
        // head at the top end, tail tip implied by the round cap
        let headX = cx + s * amp * sin(0.0)
        _ = headX
        let hx = cx + s * 14, hy = sTop - 8
        g.fillEllipse(in: CGRect(x: hx - 8, y: hy - 6, width: 16, height: 12))
    }

    g.endTransparencyLayer()
    g.restoreGState()
}

func drawArrow(_ g: CGContext) {
    let start = CGPoint(x: appSlot.x + 88, y: appSlot.y + 6)
    let end = CGPoint(x: applicationsSlot.x - 92, y: applicationsSlot.y + 6)
    let c1 = CGPoint(x: start.x + 50, y: start.y - 40)
    let c2 = CGPoint(x: end.x - 50, y: end.y - 40)
    g.saveGState()
    g.setAlpha(0.9)
    g.beginTransparencyLayer(auxiliaryInfo: nil)
    g.setStrokeColor(rgb(0xE8B04A))
    g.setFillColor(rgb(0xE8B04A))
    g.setLineWidth(4)
    g.setLineCap(.round)
    g.setLineJoin(.round)
    g.move(to: start)
    g.addCurve(to: end, control1: c1, control2: c2)
    g.strokePath()
    // arrowhead aligned to the end tangent
    let ang = atan2(end.y - c2.y, end.x - c2.x)
    let len: CGFloat = 18, spread: CGFloat = 0.5
    g.move(to: CGPoint(x: end.x + 2 * cos(ang), y: end.y + 2 * sin(ang)))
    g.addLine(to: CGPoint(x: end.x - len * cos(ang - spread), y: end.y - len * sin(ang - spread)))
    g.move(to: CGPoint(x: end.x + 2 * cos(ang), y: end.y + 2 * sin(ang)))
    g.addLine(to: CGPoint(x: end.x - len * cos(ang + spread), y: end.y - len * sin(ang + spread)))
    g.strokePath()
    g.endTransparencyLayer()
    g.restoreGState()
}

func drawText(_ s: String, font: NSFont, color: NSColor, centerX: CGFloat? = nil, rightX: CGFloat? = nil, baselineTop: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let str = NSAttributedString(string: s, attributes: attrs)
    let size = str.size()
    var x: CGFloat = 0
    if let c = centerX { x = c - size.width / 2 }
    if let r = rightX { x = r - size.width }
    // unflipped drawing: convert top-based y to bottom-based
    str.draw(at: NSPoint(x: x, y: H - baselineTop - size.height))
}

func render(scale: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W) * scale, pixelsHigh: Int(H) * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H) // 144 dpi for 2x
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let g = ctx.cgContext

    // Radial glow background (bottom-left origin here; symmetric so no flip needed)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let grad = CGGradient(colorsSpace: cs, colors: [rgb(0x6CC8EC), rgb(0x1F3A80)] as CFArray, locations: [0, 1])!
    g.drawRadialGradient(grad, startCenter: CGPoint(x: W / 2, y: H / 2), startRadius: 0,
                         endCenter: CGPoint(x: W / 2, y: H / 2), endRadius: 400, options: [.drawsAfterEndLocation])

    // Vector art uses top-left coordinates
    g.saveGState()
    g.translateBy(x: 0, y: H)
    g.scaleBy(x: 1, y: -1)
    drawCaduceus(g)
    drawArrow(g)
    g.restoreGState()

    drawText("Drag Conduit to Applications", font: NSFont.systemFont(ofSize: 15, weight: .medium),
             color: .white, centerX: W / 2, baselineTop: 322)
    drawText("v\(version)", font: NSFont.systemFont(ofSize: 11, weight: .regular),
             color: NSColor.white.withAlphaComponent(0.5), rightX: W - 16, baselineTop: 350)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, _ name: String) throws {
    let data = rep.representation(using: .png, properties: [:])!
    try data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
}
try writePNG(render(scale: 1), "background.png")
try writePNG(render(scale: 2), "background@2x.png")

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
p.arguments = ["-cathidpicheck", "\(outDir)/background.png", "\(outDir)/background@2x.png",
               "-out", "\(outDir)/background.tiff"]
try p.run()
p.waitUntilExit()
exit(p.terminationStatus)
