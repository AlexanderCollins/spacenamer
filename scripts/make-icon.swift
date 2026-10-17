#!/usr/bin/env swift
// Draws the app icon at every size macOS asks for and builds Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift            writes Resources/AppIcon.icns
//   swift scripts/make-icon.swift out.png    writes just the 1024 px master
//
// Drawn on Apple's 1024 pt icon grid: an 824 pt rounded square with room around it for
// the shadow. Three desktops, as in Mission Control's Spaces bar, the current one named.
// Run it again after changing anything here; the .icns is checked in.
import AppKit

let canvas: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// A rounded rectangle with continuous corners, as Apple's icon outline has: each corner
/// eases into its sides instead of meeting them as a circular arc does.
func continuousRoundedRect(_ rect: CGRect, radius r: CGFloat) -> CGPath {
    // One corner, as distances in from its two edges, starting on the edge we arrive along.
    let corner: [(CGFloat, CGFloat)] = [
        (1.52866483, 0), (1.08849323, 0), (0.86840689, 0), (0.63149399, 0.07491100),
        (0.37282392, 0.16905899), (0.16905899, 0.37282392), (0.07491100, 0.63149399),
        (0, 0.86840689), (0, 1.08849323), (0, 1.52866483),
    ]
    let corners: [(CGPoint, CGFloat, CGFloat, Bool)] = [
        (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1, false),
        (CGPoint(x: rect.maxX, y: rect.minY), -1, 1, true),
        (CGPoint(x: rect.minX, y: rect.minY), 1, 1, false),
        (CGPoint(x: rect.minX, y: rect.maxY), 1, -1, true),
    ]
    let path = CGMutablePath()
    for (index, (origin, inX, inY, alongSide)) in corners.enumerated() {
        let points = corner.map { a, b -> CGPoint in
            let (x, y) = alongSide ? (b, a) : (a, b)
            return CGPoint(x: origin.x + inX * x * r, y: origin.y + inY * y * r)
        }
        if index == 0 { path.move(to: points[0]) } else { path.addLine(to: points[0]) }
        for segment in 0..<3 {
            path.addCurve(to: points[3 * segment + 3], control1: points[3 * segment + 1], control2: points[3 * segment + 2])
        }
    }
    path.closeSubpath()
    return path
}

func linearGradient(_ context: CGContext, _ colors: [CGColor], from start: CGPoint, to end: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// A desktop thumbnail: wallpaper, a couple of windows, and its name below it.
func drawDesktop(_ context: CGContext, frame: CGRect, current: Bool, name: String?) {
    let radius = frame.width * 0.075
    let card = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0x10093A, 0.35))
    context.addPath(card)
    context.setFillColor(color(0xFFFFFF))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(card)
    context.clip()
    linearGradient(context, current ? [color(0x9FD8FF), color(0x5E8BFF)] : [color(0xC9D6FF, 0.95), color(0x99A8F0, 0.95)],
                   from: CGPoint(x: frame.minX, y: frame.maxY), to: CGPoint(x: frame.maxX, y: frame.minY))
    // Two windows, the front one with a title bar.
    let unit = frame.width / 100
    let back = CGRect(x: frame.minX + 14 * unit, y: frame.minY + 18 * unit, width: 46 * unit, height: 34 * unit)
    let front = CGRect(x: frame.minX + 38 * unit, y: frame.minY + 9 * unit, width: 50 * unit, height: 36 * unit)
    for (window, alpha) in [(back, 0.55), (front, 0.95)] {
        let path = CGPath(roundedRect: window, cornerWidth: 3.5 * unit, cornerHeight: 3.5 * unit, transform: nil)
        context.addPath(path)
        context.setFillColor(color(0xFFFFFF, alpha))
        context.fillPath()
    }
    let bar = CGRect(x: front.minX, y: front.maxY - 7 * unit, width: front.width, height: 7 * unit)
    context.saveGState()
    context.addPath(CGPath(roundedRect: front, cornerWidth: 3.5 * unit, cornerHeight: 3.5 * unit, transform: nil))
    context.clip()
    context.setFillColor(color(0xE4E9FB))
    context.fill(bar)
    context.restoreGState()
    context.restoreGState()

    if current {
        context.addPath(CGPath(roundedRect: frame.insetBy(dx: -9, dy: -9), cornerWidth: radius + 9, cornerHeight: radius + 9, transform: nil))
        context.setStrokeColor(color(0xFFFFFF, 0.95))
        context.setLineWidth(7)
        context.strokePath()
    }

    // The name pill under the desktop.
    let pillHeight: CGFloat = current ? 112 : 64
    let pillWidth: CGFloat = current ? frame.width * 1.02 : frame.width * 0.62
    let pill = CGRect(x: frame.midX - pillWidth / 2, y: frame.minY - (current ? 58 : 46) - pillHeight, width: pillWidth, height: pillHeight)
    let pillPath = CGPath(roundedRect: pill, cornerWidth: pillHeight / 2, cornerHeight: pillHeight / 2, transform: nil)
    context.saveGState()
    if current { context.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: color(0x10093A, 0.35)) }
    context.addPath(pillPath)
    context.setFillColor(current ? color(0xFFFFFF) : color(0xFFFFFF, 0.45))
    context.fillPath()
    context.restoreGState()

    guard let name else { return }
    let descriptor = NSFont.systemFont(ofSize: 76, weight: .bold).fontDescriptor.withDesign(.rounded)!
    let font = NSFont(descriptor: descriptor, size: 76)!
    let text = NSAttributedString(string: name, attributes: [
        .font: font,
        .foregroundColor: NSColor(cgColor: color(0x2B1E8C))!,
        .kern: -0.5,
    ])
    let line = CTLineCreateWithAttributedString(text)
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    context.textPosition = CGPoint(x: pill.midX - bounds.width / 2 - bounds.minX, y: pill.midY - (font.capHeight / 2))
    CTLineDraw(line, context)
}

func drawIcon(_ context: CGContext) {
    let outline = continuousRoundedRect(body, radius: 185.4)

    // Drop shadow under the tile, as on Apple's icon template.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: color(0x000000, 0.30))
    context.addPath(outline)
    context.setFillColor(color(0x4B3FD9))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(outline)
    context.clip()
    linearGradient(context, [color(0x5A8CFF), color(0x5B47E8), color(0x4A22B8)],
                   from: CGPoint(x: body.minX, y: body.maxY), to: CGPoint(x: body.maxX, y: body.minY))
    // A soft light from the top.
    linearGradient(context, [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)],
                   from: CGPoint(x: body.midX, y: body.maxY), to: CGPoint(x: body.midX, y: body.midY))

    let width: CGFloat = 400, height: CGFloat = 250, sideWidth: CGFloat = 300, sideHeight: CGFloat = 188, gap: CGFloat = 52
    let top: CGFloat = 716
    let center = CGRect(x: 512 - width / 2, y: top - height, width: width, height: height)
    let sideY = center.midY - sideHeight / 2 + 4
    // The neighbours, quieter, running off the edges.
    context.saveGState()
    context.setAlpha(0.6)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    drawDesktop(context, frame: CGRect(x: center.minX - gap - sideWidth, y: sideY, width: sideWidth, height: sideHeight), current: false, name: nil)
    drawDesktop(context, frame: CGRect(x: center.maxX + gap, y: sideY, width: sideWidth, height: sideHeight), current: false, name: nil)
    context.endTransparencyLayer()
    context.restoreGState()
    drawDesktop(context, frame: center, current: true, name: "Work")
    context.restoreGState()

    // A fine edge so the tile holds its shape on light backgrounds.
    context.addPath(outline)
    context.setStrokeColor(color(0xFFFFFF, 0.10))
    context.setLineWidth(2)
    context.strokePath()
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    context.interpolationQuality = .high
    drawIcon(context)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let arguments = CommandLine.arguments.dropFirst()
if let output = arguments.first {
    try render(pixels: 1024).write(to: URL(fileURLWithPath: output))
    exit(0)
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    try render(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let destination = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", destination.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("✓ \(destination.path)")
