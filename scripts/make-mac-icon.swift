#!/usr/bin/env swift
// Usage: swift scripts/make-mac-icon.swift <input-1024.png> <output-dir>
// Masks square iOS art to Apple's macOS icon grid (824pt rounded rect, 100pt
// margins, radius 185, soft drop shadow) and writes every size named in the
// AppIcon.appiconset Contents.json of <output-dir>.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-mac-icon.swift <input-1024.png> <output-dir>\n".utf8))
    exit(2)
}
let input = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2], isDirectory: true)

guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let art = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("cannot read \(input.path)\n".utf8))
    exit(1)
}

let canvas = 1024
let shape = CGRect(x: 100, y: 100, width: 824, height: 824)
guard let ctx = CGContext(
    data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }
ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))

let path = CGPath(roundedRect: shape, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Shadow pass: an opaque fill of the shape casts the shadow (CG origin is
// bottom-left, so a negative y offset moves it down).
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 20,
              color: CGColor(gray: 0, alpha: 0.3))
ctx.addPath(path)
ctx.setFillColor(CGColor(gray: 0, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

// Art pass, clipped to the shape (replaces the shadow fill inside the shape).
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
ctx.setBlendMode(.copy)
ctx.draw(art, in: shape)
ctx.restoreGState()

guard let rendered = ctx.makeImage() else { exit(1) }

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { exit(1) }
}

let master = outDir.appendingPathComponent("icon_1024.png")
writePNG(rendered, to: master)

// pixel size -> asset-set file names (names already in Contents.json).
let sizes: [(Int, [String])] = [
    (16, ["icon_16x16@1x.png"]),
    (32, ["icon_16x16@2x.png", "icon_32x32@1x.png"]),
    (64, ["icon_32x32@2x.png"]),
    (128, ["icon_128x128@1x.png"]),
    (256, ["icon_128x128@2x.png", "icon_256x256@1x.png"]),
    (512, ["icon_256x256@2x.png", "icon_512x512@1x.png"]),
]
let fm = FileManager.default
for (px, names) in sizes {
    let first = outDir.appendingPathComponent(names[0])
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    p.arguments = ["-z", "\(px)", "\(px)", master.path, "--out", first.path]
    p.standardOutput = FileHandle.nullDevice
    try p.run(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { exit(1) }
    for extra in names.dropFirst() {
        let dst = outDir.appendingPathComponent(extra)
        try? fm.removeItem(at: dst)
        try fm.copyItem(at: first, to: dst)
    }
}
// 1024 master is the 512@2x slot; move it so the asset set has no stray file.
let top = outDir.appendingPathComponent("icon_512x512@2x.png")
try? fm.removeItem(at: top)
try fm.moveItem(at: master, to: top)
