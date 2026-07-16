import AppKit

func draw(size: CGFloat, path: String) {
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let image = NSImage(size: rect.size, flipped: false) { bounds in
        NSColor.black.set()
        let path = NSBezierPath()
        let scale = size / 22.0
        path.move(to: NSPoint(x: 4 * scale, y: 16 * scale))
        path.line(to: NSPoint(x: 18 * scale, y: 16 * scale))
        path.line(to: NSPoint(x: 18 * scale, y: 13 * scale))
        path.line(to: NSPoint(x: 12.5 * scale, y: 13 * scale))
        path.line(to: NSPoint(x: 12.5 * scale, y: 4 * scale))
        path.line(to: NSPoint(x: 9.5 * scale, y: 4 * scale))
        path.line(to: NSPoint(x: 9.5 * scale, y: 13 * scale))
        path.line(to: NSPoint(x: 4 * scale, y: 13 * scale))
        path.close()
        path.fill()
        return true
    }

    let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let rep = NSBitmapImageRep(cgImage: cgImage)
    let pngData = rep.representation(using: .png, properties: [:])!
    try! pngData.write(to: URL(fileURLWithPath: path))
}

draw(size: 22, path: "Sources/TabType/Resources/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon.png")
draw(size: 44, path: "Sources/TabType/Resources/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon@2x.png")
