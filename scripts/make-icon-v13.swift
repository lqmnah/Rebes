// make-icon-v13.swift — v1.3 app icon from a user-provided render.
// Crops the grey backdrop around the squircle in the source PNG, masks the
// corners transparent, recenters on the standard 1024 icon canvas (824pt
// artwork), and emits assets/AppIcon.icns plus preview PNGs for review.
//
//   swift scripts/make-icon-v13.swift <input.png> <output-dir>

import AppKit
import CoreGraphics

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 3 else { die("usage: make-icon-v13.swift <input.png> <output-dir>") }
let inputPath = args[1]
let outDir = args[2]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

guard let src = NSImage(contentsOfFile: inputPath),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    die("cannot load \(inputPath)")
}
let W = cg.width, H = cg.height

// Decode to straight RGBA for sampling. Row 0 = top scanline (matches
// CGImage.cropping's top-left-origin rect).
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                          bytesPerRow: W * 4, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    die("no bitmap context")
}
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
guard let data = ctx.data else { die("no bitmap data") }
let buf = data.assumingMemoryBound(to: UInt8.self)

// Memory row 0 is the TOP scanline, so px(x, y) is top-down — matching
// CGImage.cropping's top-left-origin rect.
func px(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
    let o = (y * W + x) * 4
    return (Double(buf[o]) / 255, Double(buf[o + 1]) / 255, Double(buf[o + 2]) / 255)
}

// Background reference = average of the four 24x24 corner patches.
var bg = (r: 0.0, g: 0.0, b: 0.0); var n = 0.0
for (cx, cy) in [(0, 0), (W - 24, 0), (0, H - 24), (W - 24, H - 24)] {
    for dx in 0..<24 { for dy in 0..<24 {
        let p = px(cx + dx, cy + dy)
        bg.r += p.r; bg.g += p.g; bg.b += p.b; n += 1
    } }
}
bg.r /= n; bg.g /= n; bg.b /= n

func dist(_ x: Int, _ y: Int) -> Double {
    let p = px(x, y)
    return abs(p.r - bg.r) + abs(p.g - bg.g) + abs(p.b - bg.b)
}

// Rows/columns count as "content" when enough pixels differ strongly from the
// backdrop — the blurred UI shapes in the backdrop stay under the threshold.
let thr = 0.45
let minCount = 40
var top = -1, bottom = -1, left = -1, right = -1
for y in 0..<H {
    var c = 0
    for x in 0..<W where dist(x, y) > thr { c += 1; if c >= minCount { break } }
    if c >= minCount { if top < 0 { top = y }; bottom = y }
}
for x in 0..<W {
    var c = 0
    for y in 0..<H where dist(x, y) > thr { c += 1; if c >= minCount { break } }
    if c >= minCount { if left < 0 { left = x }; right = x }
}
guard top >= 0, left >= 0 else { die("could not find icon bounds") }

var bw = right - left + 1
var bh = bottom - top + 1
print("detected bounds: x \(left)...\(right) (\(bw)), y \(top)...\(bottom) (\(bh)), bg=(\(bg.r), \(bg.g), \(bg.b))")

// The artwork is a square squircle; if detection skews (>4% off square),
// trust the vertical extent (dark top edge = strongest signal) and center
// horizontally on the canvas midline.
if abs(bw - bh) > Int(0.04 * Double(max(bw, bh))) {
    print("bounds not square — falling back to square-centered on height")
    let cx = W / 2
    left = cx - bh / 2; bw = bh
    print("adjusted: x \(left) width \(bw)")
}
let side = max(bw, bh)
let cropRect = CGRect(x: left, y: top, width: side, height: side)
guard let cropped = cg.cropping(to: cropRect) else { die("crop failed") }

// Compose the 1024 canvas: artwork at 824pt centered, corners masked with the
// macOS squircle radius (~22.37%), inset 2px so no grey sliver survives at
// the very edge of the source's own corner curve.
let canvas = 1024
let art = 824
func renderIcon(size: Int) -> CGImage {
    let s = Double(size) / Double(canvas)
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                      bytesPerRow: size * 4, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let margin = Double(canvas - art) / 2 * s
    let artSize = Double(art) * s
    let rect = CGRect(x: margin, y: margin, width: artSize, height: artSize)
    let inset = rect.insetBy(dx: 2 * s, dy: 2 * s)
    let radius = inset.width * 0.2237
    let path = CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil)
    c.addPath(path)
    c.clip()
    c.interpolationQuality = .high
    c.draw(cropped, in: rect)
    return c.makeImage()!
}

func writePNG(_ image: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else { die("png encode failed") }
    try! png.write(to: URL(fileURLWithPath: path))
}

// iconset
let iconset = outDir + "/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    writePNG(renderIcon(size: base), "\(iconset)/icon_\(base)x\(base).png")
    writePNG(renderIcon(size: base * 2), "\(iconset)/icon_\(base)x\(base)@2x.png")
}

// Previews: full icon on checkerboard + top-left corner zoom (mask check).
let full = renderIcon(size: 1024)
writePNG(full, outDir + "/preview-full.png")
do {
    let zoomSrc = full.cropping(to: CGRect(x: 60, y: 1024 - 60 - 240, width: 240, height: 240))!
    let zc = CGContext(data: nil, width: 480, height: 480, bitsPerComponent: 8,
                       bytesPerRow: 480 * 4, space: cs,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // checkerboard behind, to reveal any grey remnants vs true transparency
    for cx in 0..<12 { for cy in 0..<12 {
        zc.setFillColor((cx + cy) % 2 == 0 ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0.7, alpha: 1))
        zc.fill(CGRect(x: cx * 40, y: cy * 40, width: 40, height: 40))
    } }
    zc.interpolationQuality = .none
    zc.draw(zoomSrc, in: CGRect(x: 0, y: 0, width: 480, height: 480))
    writePNG(zc.makeImage()!, outDir + "/preview-corner.png")
}
print("iconset + previews written to \(outDir)")
