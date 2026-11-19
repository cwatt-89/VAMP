// Renders the VAMP app icon in the FloydNet Terminal style:
// black ground, hairline frame, stretched Times New Roman "V" inside a nested "screen" compartment.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
func hex(_ v: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
hex(0x000000).setFill()
NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185).fill()

let frame = plate.insetBy(dx: 96, dy: 96)
hex(0x2A2A2A).setStroke()
let fp = NSBezierPath(rect: frame); fp.lineWidth = 6; fp.stroke()

// Inner "guest screen": accent hairline, offset like a nested window.
let screen = NSRect(x: frame.midX - 40, y: frame.minY + 70, width: frame.maxX - 56 - (frame.midX - 40), height: 230)
hex(0x17D97A).setStroke()
let sp = NSBezierPath(rect: screen); sp.lineWidth = 10; sp.stroke()
hex(0x0E8A4F).setFill()
NSRect(x: screen.minX + 30, y: screen.minY + 30, width: screen.width - 60, height: 26).fill()
hex(0x3DFFA0).setFill()
NSRect(x: screen.maxX - 70, y: screen.maxY - 70, width: 36, height: 36).fill()

let font = NSFont(name: "TimesNewRomanPSMT", size: 330) ?? NSFont.systemFont(ofSize: 330)
let str = NSAttributedString(string: "V", attributes: [.font: font, .foregroundColor: hex(0xF2F2F2)])
ctx.saveGState()
ctx.translateBy(x: frame.minX + 46, y: frame.minY + 250)
ctx.scaleBy(x: 1, y: 1.55)
str.draw(at: .zero)
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
