// Generates Support/AppIcon.icns — a dark-indigo squircle with a glowing
// waveform glyph. Run: swift scripts/make_icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let iconsetURL = root.appendingPathComponent("build/AppIcon.iconset")
let icnsURL = root.appendingPathComponent("Support/AppIcon.icns")

try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    // Canvas margin per Apple icon grid (~9.8%), continuous-ish corners.
    let margin = size * 0.098
    let content = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
    let radius = content.width * 0.2237
    let squircle = NSBezierPath(roundedRect: content, xRadius: radius, yRadius: radius)

    // Background: deep indigo vertical gradient.
    squircle.addClip()
    let bg = NSGradient(colors: [
        NSColor(calibratedRed: 0.31, green: 0.24, blue: 0.86, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.09, blue: 0.24, alpha: 1),
    ])!
    bg.draw(in: content, angle: -90)

    // Soft radial glow behind the glyph.
    let glowColors = [
        NSColor(calibratedRed: 0.62, green: 0.55, blue: 1.0, alpha: 0.55).cgColor,
        NSColor.clear.cgColor,
    ] as CFArray
    if let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glowColors, locations: [0, 1]) {
        cg.drawRadialGradient(
            glow,
            startCenter: CGPoint(x: content.midX, y: content.midY + content.height * 0.05),
            startRadius: 0,
            endCenter: CGPoint(x: content.midX, y: content.midY),
            endRadius: content.width * 0.62,
            options: []
        )
    }

    // Waveform: five rounded bars, heights like a murmur.
    let heights: [CGFloat] = [0.26, 0.48, 0.74, 0.48, 0.26]
    let barW = content.width * 0.082
    let gap = content.width * 0.058
    let totalW = barW * 5 + gap * 4
    var x = content.midX - totalW / 2
    for h in heights {
        let barH = content.height * h
        let bar = CGRect(x: x, y: content.midY - barH / 2, width: barW, height: barH)
        let path = NSBezierPath(roundedRect: bar, xRadius: barW / 2, yRadius: barW / 2)
        // Subtle shadow for depth.
        cg.saveGState()
        cg.setShadow(
            offset: CGSize(width: 0, height: -size * 0.006),
            blur: size * 0.02,
            color: NSColor.black.withAlphaComponent(0.35).cgColor
        )
        NSColor.white.setFill()
        path.fill()
        cg.restoreGState()
        x += barW + gap
    }

    // Inner top highlight line for glassiness.
    let highlight = NSBezierPath(roundedRect: content.insetBy(dx: size * 0.004, dy: size * 0.004), xRadius: radius, yRadius: radius)
    highlight.lineWidth = size * 0.008
    NSColor.white.withAlphaComponent(0.10).setStroke()
    highlight.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, _ name: String) throws {
    let data = rep.representation(using: .png, properties: [:])!
    try data.write(to: iconsetURL.appendingPathComponent(name))
}

let sizes: [(CGFloat, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (size, name) in sizes {
    try writePNG(draw(size: size), name)
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote \(icnsURL.path)" : "iconutil failed")
