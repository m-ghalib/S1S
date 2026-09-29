// Draws the "Ghost tail" app icon: two text lines on an ivory tile, an orange
// caret, and a faded suggestion after it.
// Also draws the same glyph, without the tile, as the menu bar template image.
// Run from the repo root: swift Scripts/generate-app-icon.swift
// Writes Resources/AppIcon.icns, the 1024 px asset-catalog PNG, and MenuBarIcon.imageset.
import AppKit

func srgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let ink = srgb(0x16161A)
let caret = srgb(0xE8643B)
let edge = srgb(0xD6CFC2)
let groundTop = srgb(0xFBFAF7)
let groundBottom = srgb(0xE4DED2)

/// A bar in the 100-unit tile grid: x, y (from top), width, height, fill, opacity.
typealias Bar = (x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, color: CGColor, alpha: CGFloat)

/// Small sizes get thicker strokes so the glyph survives downsampling.
func bars(forPixels px: Int) -> [Bar] {
    if px <= 16 {
        return [(18, 28, 64, 13, ink, 1), (18, 57, 26, 13, ink, 1),
                (48, 50, 9, 27, caret, 1), (61, 57, 21, 13, ink, 0.25)]
    }
    if px <= 32 {
        return [(20, 31, 60, 10, ink, 1), (20, 58, 26, 10, ink, 1),
                (49.5, 51, 6, 23, caret, 1), (59, 58, 21, 10, ink, 0.22)]
    }
    return [(20, 31, 60, 9, ink, 1), (20, 58, 26, 9, ink, 1),
            (50, 52, 4.5, 21, caret, 1), (58.5, 58, 21.5, 9, ink, 0.2)]
}

func render(pixels px: Int) -> Data {
    let size = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Top-left origin so coordinates match the design file.
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)

    // macOS icon grid: an 824 pt tile centered in a 1024 pt canvas.
    let inset = size * 100 / 1024
    let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let unit = tile.width / 100
    let corner = 22 * unit
    let tilePath = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)

    // Drop shadow (y is flipped, so a positive offset points down on screen).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03,
                  color: CGColor(gray: 0, alpha: 0.3))
    ctx.addPath(tilePath)
    ctx.setFillColor(groundBottom)
    ctx.fillPath()
    ctx.restoreGState()

    // Vertical ivory gradient.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: nil, colors: [groundTop, groundBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])
    ctx.restoreGState()

    // Hairline edge so the light tile holds up on light backgrounds.
    let lineWidth = max(1, size / 512)
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
                       cornerWidth: corner, cornerHeight: corner, transform: nil))
    ctx.setStrokeColor(edge)
    ctx.setLineWidth(lineWidth)
    ctx.strokePath()

    for bar in bars(forPixels: px) {
        let rect = CGRect(x: tile.minX + bar.x * unit, y: tile.minY + bar.y * unit,
                          width: bar.w * unit, height: bar.h * unit)
        let radius = min(rect.width, rect.height) / 2
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(bar.color.copy(alpha: bar.alpha)!)
        ctx.fillPath()
    }

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

/// Menu bar glyph on an 18 pt canvas, in points. Black plus alpha only: AppKit
/// tints template images for light, dark, and highlighted menu bars, and keeps
/// the alpha, so the suggestion still reads as faded.
let menuBarBars: [Bar] = [(2, 3.5, 14, 2.5, ink, 1), (2, 10.5, 5, 2.5, ink, 1),
                          (8.25, 8, 1.5, 7.5, ink, 1), (11, 10.5, 5, 2.5, ink, 0.35)]

func renderMenuBar(scale: Int) -> Data {
    let px = 18 * scale
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    for bar in menuBarBars {
        let rect = CGRect(x: bar.x, y: bar.y, width: bar.w, height: bar.h)
        let radius = min(rect.width, rect.height) / 2
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(CGColor(gray: 0, alpha: bar.alpha))
        ctx.fillPath()
    }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    rep.size = NSSize(width: 18, height: 18)
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    try! render(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try! render(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
try! render(pixels: 1024).write(to: URL(fileURLWithPath: "Sources/S1S/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil failed")
let menuBarSet = "Sources/S1S/Resources/Assets.xcassets/MenuBarIcon.imageset/"
try! renderMenuBar(scale: 1).write(to: URL(fileURLWithPath: menuBarSet + "MenuBarIcon.png"))
try! renderMenuBar(scale: 2).write(to: URL(fileURLWithPath: menuBarSet + "MenuBarIcon@2x.png"))
print("Wrote Resources/AppIcon.icns, AppIcon.appiconset/AppIcon.png, and MenuBarIcon.imageset")
