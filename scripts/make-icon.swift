// Draws Tick's icon: Resources/AppIcon.icns (dark rounded square, white hourglass).
// Run: swift scripts/make-icon.swift <project dir>
import AppKit

func bitmap(_ px: Int, _ draw: (CGFloat) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func appIcon(_ px: Int) -> Data {
    bitmap(px) { size in
        let s = size / 1024
        let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
        NSGradient(starting: NSColor(white: 0.30, alpha: 1), ending: NSColor(white: 0.13, alpha: 1))!.draw(in: shape, angle: -90)
        NSColor(white: 1, alpha: 0.16).setStroke()
        shape.lineWidth = max(1, 6 * s)
        shape.stroke()
        let config = NSImage.SymbolConfiguration(pointSize: 460 * s, weight: .medium).applying(.init(paletteColors: [.white]))
        guard let image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let i = image.size
        image.draw(in: NSRect(x: body.midX - i.width / 2, y: body.midY - i.height / 2, width: i.width, height: i.height))
    }
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("TickIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! appIcon(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! appIcon(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run()
p.waitUntilExit()
try! appIcon(512).write(to: root.appendingPathComponent("Resources/AppIcon-preview.png"))
print(p.terminationStatus == 0 ? "icons written" : "iconutil failed")
