import AppKit

// Package the approved glass-battery artwork deterministically. Image generation
// is an authoring step only; builds use the checked-in master without networking.
guard (2...3).contains(CommandLine.arguments.count) else {
    fputs("Usage: swift scripts/make-icon.swift <resources-directory> [preview.png]\n", stderr)
    exit(1)
}
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let sourceURL = root.appendingPathComponent("Assets/PowerIcon.source.png")
guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: sourceURL)),
      bitmap.pixelsWide == 1254, bitmap.pixelsHigh == 1254, bitmap.hasAlpha,
      let cgImage = bitmap.cgImage else {
    fputs("Expected the approved 1254 × 1254 RGBA icon master.\n", stderr)
    exit(1)
}
let artwork = NSImage(cgImage: cgImage, size: NSSize(width: 1254, height: 1254))
// The source includes presentation padding. Its ivory tile is placed on the
// macOS icon grid; the vector silhouette keeps transparent edges clean at all sizes.
let sourceTile = NSRect(x: 120, y: 140, width: 1016, height: 1008)

func drawIcon(in context: CGContext, pixels: Int) {
    let frame = NSRect(x: 90, y: 90, width: 844, height: 844)
    let tile = NSBezierPath(roundedRect: frame, xRadius: 196, yRadius: 196)
    context.saveGState()
    if pixels >= 128 {
        // CGContext shadows use device pixels; do not let a full-size blur
        // spread over tiny Finder icons or tint their transparent corners.
        let scale = CGFloat(pixels) / 1024
        context.setShadow(offset: CGSize(width: 0, height: -7 * scale), blur: 14 * scale,
                          color: NSColor.black.withAlphaComponent(0.12).cgColor)
    }
    NSColor.white.setFill()
    tile.fill()
    context.restoreGState()

    context.saveGState()
    tile.addClip()
    NSGraphicsContext.current?.imageInterpolation = .high
    artwork.draw(in: frame, from: sourceTile, operation: .sourceOver, fraction: 1)
    context.restoreGState()
}

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let iconset = destination.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        drawIcon(in: context, pixels: pixels)
        NSGraphicsContext.restoreGraphicsState()
        let png = bitmap.representation(using: .png, properties: [:])!
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
        if pixels == 1024, CommandLine.arguments.count == 3 {
            try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", destination.appendingPathComponent("PowerIcon.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
try FileManager.default.removeItem(at: iconset)
