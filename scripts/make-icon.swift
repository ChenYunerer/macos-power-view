import AppKit

// A single power symbol on a quiet macOS rounded tile.
func drawIcon(in context: CGContext) {
    let tile = NSBezierPath(roundedRect: NSRect(x: 90, y: 90, width: 844, height: 844),
                            xRadius: 188, yRadius: 188)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -8), blur: 16,
                      color: NSColor.black.withAlphaComponent(0.08).cgColor)
    NSColor(srgbRed: 0.98, green: 0.98, blue: 0.965, alpha: 1).setFill()
    tile.fill()
    context.restoreGState()

    let mark = CGMutablePath()
    mark.addArc(center: CGPoint(x: 512, y: 488), radius: 207,
                startAngle: 125 * .pi / 180, endAngle: 415 * .pi / 180, clockwise: false)
    mark.move(to: CGPoint(x: 512, y: 550))
    mark.addLine(to: CGPoint(x: 512, y: 748))
    context.setLineWidth(74)
    context.setLineCap(.round)
    context.setStrokeColor(NSColor(srgbRed: 0.50, green: 0.72, blue: 0.64, alpha: 1).cgColor)
    context.addPath(mark)
    context.strokePath()
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
