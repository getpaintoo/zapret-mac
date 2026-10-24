// Рисует значок приложения в папку .iconset: swift app/icon.swift build/AppIcon.iconset
// Тёмный скруглённый квадрат, зелёное кольцо и треугольник — как главная кнопка.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.09                                   // поля, как у значков macOS
    let r = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225)
    NSGradient(starting: NSColor(white: 0.20, alpha: 1), ending: NSColor(white: 0.06, alpha: 1))!.draw(in: bg, angle: -90)
    NSColor(white: 1, alpha: 0.08).setStroke()
    bg.lineWidth = max(1, s * 0.004)
    bg.stroke()

    let green = NSColor(calibratedRed: 0.20, green: 0.84, blue: 0.40, alpha: 1)
    let c = NSPoint(x: s / 2, y: s / 2)
    let ringR = r.width * 0.31
    let glow = NSShadow()
    glow.shadowColor = green.withAlphaComponent(0.75)
    glow.shadowBlurRadius = s * 0.05
    glow.set()
    let ring = NSBezierPath(ovalIn: NSRect(x: c.x - ringR, y: c.y - ringR, width: ringR * 2, height: ringR * 2))
    ring.lineWidth = r.width * 0.055
    green.setStroke()
    ring.stroke()

    let t = r.width * 0.15
    let tri = NSBezierPath()
    tri.move(to: NSPoint(x: c.x - t * 0.62, y: c.y - t))
    tri.line(to: NSPoint(x: c.x - t * 0.62, y: c.y + t))
    tri.line(to: NSPoint(x: c.x + t * 1.05, y: c.y))
    tri.close()
    tri.lineJoinStyle = .round
    tri.lineWidth = r.width * 0.04
    green.setFill()
    tri.fill()
    tri.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
