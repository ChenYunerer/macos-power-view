import AppKit

// A charged battery on a quiet macOS tile, legible down to Finder's smallest size.
func drawIcon(in context: CGContext) {
    let tile = NSBezierPath(roundedRect: NSRect(x: 90, y: 90, width: 844, height: 844),
                            xRadius: 188, yRadius: 188)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -8), blur: 16,
                      color: NSColor.black.withAlphaComponent(0.08).cgColor)
    NSColor(srgbRed: 0.98, green: 0.98, blue: 0.965, alpha: 1).setFill()
    tile.fill()
    context.restoreGState()

    // The separated terminal distinguishes the silhouette from a toggle switch.
    let terminal = NSBezierPath(roundedRect: NSRect(x: 797, y: 459, width: 38, height: 106),
                                xRadius: 15, yRadius: 15)
    NSColor(srgbRed: 0.53, green: 0.72, blue: 0.66, alpha: 1).setFill()
    terminal.fill()

    let battery = NSBezierPath(roundedRect: NSRect(x: 211, y: 344, width: 552, height: 336),
                               xRadius: 66, yRadius: 66)
    let mint = NSGradient(starting: NSColor(srgbRed: 0.64, green: 0.81, blue: 0.74, alpha: 1),
                          ending: NSColor(srgbRed: 0.46, green: 0.68, blue: 0.61, alpha: 1))!
    mint.draw(in: battery, angle: -90)

    let bolt = NSBezierPath()
    bolt.move(to: NSPoint(x: 532, y: 630))
    bolt.line(to: NSPoint(x: 401, y: 494))
    bolt.line(to: NSPoint(x: 476, y: 494))
    bolt.line(to: NSPoint(x: 449, y: 393))
    bolt.line(to: NSPoint(x: 578, y: 531))
    bolt.line(to: NSPoint(x: 503, y: 531))
    bolt.close()
    NSColor(srgbRed: 0.98, green: 0.99, blue: 0.97, alpha: 1).setFill()
    bolt.fill()
}

let destination = CommandLine.arguments[1]
let iconset = destination + "/AppIcon.iconset"
try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        drawIcon(in: context)
        NSGraphicsContext.restoreGraphicsState()
        let png = bitmap.representation(using: .png, properties: [:])!
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: URL(fileURLWithPath: "\(iconset)/icon_\(size)x\(size)\(suffix).png"))
        if pixels == 1024, CommandLine.arguments.count > 2 {
            try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset, "-o", destination + "/PowerIcon.icns"]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
try FileManager.default.removeItem(atPath: iconset)
