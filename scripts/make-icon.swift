import AppKit

let canvas: CGFloat = 1024
let backgroundTop = NSColor(red: 0.36, green: 0.36, blue: 0.84, alpha: 1)
let backgroundBottom = NSColor(red: 0.16, green: 0.16, blue: 0.48, alpha: 1)
let gap = NSColor(red: 0.25, green: 0.25, blue: 0.64, alpha: 1)
let badge = NSColor(red: 1.0, green: 0.48, blue: 0.35, alpha: 1)

func figure(at center: NSPoint) -> NSBezierPath {
    let path = NSBezierPath(ovalIn: NSRect(x: center.x - 92, y: center.y + 13, width: 184, height: 184))
    let shoulders = NSBezierPath()
    shoulders.move(to: NSPoint(x: center.x - 170, y: center.y - 130))
    shoulders.curve(
        to: NSPoint(x: center.x + 170, y: center.y - 130),
        controlPoint1: NSPoint(x: center.x - 170, y: center.y + 60),
        controlPoint2: NSPoint(x: center.x + 170, y: center.y + 60)
    )
    shoulders.close()
    path.append(shoulders)
    return path
}

func arrow(center: NSPoint, radius: CGFloat, from start: CGFloat, to end: CGFloat) {
    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end)
    arc.lineWidth = 22
    arc.lineCapStyle = .round
    arc.stroke()

    let angle = end * .pi / 180
    let tip = NSPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    let tangent = NSPoint(x: -sin(angle), y: cos(angle))
    let normal = NSPoint(x: cos(angle), y: sin(angle))
    let head = NSBezierPath()
    head.move(to: NSPoint(x: tip.x + tangent.x * 30, y: tip.y + tangent.y * 30))
    head.line(to: NSPoint(x: tip.x + normal.x * 26, y: tip.y + normal.y * 26))
    head.line(to: NSPoint(x: tip.x - normal.x * 26, y: tip.y - normal.y * 26))
    head.close()
    head.fill()
}

func draw() {
    let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGradient(starting: backgroundTop, ending: backgroundBottom)?.draw(in: body, angle: -90)
    body.addClip()

    NSColor.white.withAlphaComponent(0.55).setFill()
    figure(at: NSPoint(x: 420, y: 560)).fill()

    let front = figure(at: NSPoint(x: 590, y: 450))
    gap.setStroke()
    front.lineWidth = 36
    front.stroke()
    NSColor.white.setFill()
    front.fill()

    let badgeCenter = NSPoint(x: 760, y: 262)
    let ring = NSBezierPath(ovalIn: NSRect(x: badgeCenter.x - 132, y: badgeCenter.y - 132, width: 264, height: 264))
    gap.setFill()
    ring.fill()
    badge.setFill()
    NSBezierPath(ovalIn: NSRect(x: badgeCenter.x - 112, y: badgeCenter.y - 112, width: 224, height: 224)).fill()

    NSColor.white.setStroke()
    NSColor.white.setFill()
    arrow(center: badgeCenter, radius: 58, from: 20, to: 150)
    arrow(center: badgeCenter, radius: 58, from: 200, to: 330)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in sizes {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    let scale = CGFloat(pixels) / canvas
    NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appending(path: "\(name).png"))
}
