// Draws TempBar's app icon and writes AppIcon.icns.
// Usage: swift make_icon.swift AppIcon.icns

import Cocoa

private func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

// Everything is laid out on Apple's 1024 pt icon grid and scaled to `pixels`.
private func drawIcon(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels) / 1024
    NSGraphicsContext.current!.cgContext.scaleBy(x: s, y: s)

    // Rounded-square body with the standard macOS drop shadow.
    let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 20 * s
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.set()
    color(0xE8364F).setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0xFF9A3C), ending: color(0xE8364F))!.draw(in: body, angle: -90)

    // Glass: a capsule tube joined to a round bulb.
    let glass = NSBezierPath(roundedRect: NSRect(x: 405, y: 300, width: 150, height: 500), xRadius: 75, yRadius: 75)
    glass.append(NSBezierPath(ovalIn: NSRect(x: 345, y: 175, width: 270, height: 270)))
    NSGraphicsContext.saveGraphicsState()
    let glassShadow = NSShadow()
    glassShadow.shadowOffset = NSSize(width: 0, height: -6 * s)
    glassShadow.shadowBlurRadius = 18 * s
    glassShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    glassShadow.set()
    NSColor.white.setFill()
    glass.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Mercury, filled a bit past half way.
    let mercury = NSBezierPath(roundedRect: NSRect(x: 445, y: 300, width: 70, height: 330), xRadius: 35, yRadius: 35)
    mercury.append(NSBezierPath(ovalIn: NSRect(x: 385, y: 215, width: 190, height: 190)))
    color(0xD7263D).setFill()
    mercury.fill()

    // Scale ticks to the right of the tube, alternating long and short.
    let ticks = NSBezierPath()
    ticks.lineWidth = 24
    ticks.lineCapStyle = .round
    for (i, y) in [480, 545, 610, 675, 740].enumerated() {
        ticks.move(to: NSPoint(x: 600, y: y))
        ticks.line(to: NSPoint(x: i % 2 == 0 ? 690 : 650, y: y))
    }
    NSColor.white.withAlphaComponent(0.9).setStroke()
    ticks.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    try drawIcon(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try drawIcon(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
