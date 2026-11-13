import AppKit
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources")
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("harness-icon-" + UUID().uuidString)
let iconset = temporary.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: 1024, height: 1024)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(srgbRed: 0.965, green: 0.965, blue: 0.955, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 208, yRadius: 208).fill()
        NSColor(srgbRed: 0.12, green: 0.13, blue: 0.12, alpha: 1).setStroke()
        let mark = NSBezierPath(); mark.lineWidth = 40; mark.lineCapStyle = .square
        mark.move(to: NSPoint(x: 280, y: 288)); mark.line(to: NSPoint(x: 280, y: 736)); mark.line(to: NSPoint(x: 408, y: 736))
        mark.move(to: NSPoint(x: 744, y: 736)); mark.line(to: NSPoint(x: 744, y: 288)); mark.line(to: NSPoint(x: 616, y: 288))
        mark.move(to: NSPoint(x: 408, y: 448)); mark.line(to: NSPoint(x: 616, y: 448))
        mark.move(to: NSPoint(x: 408, y: 576)); mark.line(to: NSPoint(x: 616, y: 576)); mark.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try process.run(); process.waitUntilExit()
guard process.terminationStatus == 0 else { throw NSError(domain: "IconGeneration", code: Int(process.terminationStatus)) }
print("Generated Resources/AppIcon.icns")
