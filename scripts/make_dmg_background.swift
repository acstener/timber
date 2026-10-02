// Renders the DMG window background (560×380 @2x): a little forest scene with a drag hint.
import AppKit

let W: CGFloat = 1120, H: CGFloat = 760
let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()
func hex(_ h: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}
NSGradient(colors: [hex(0xD9EEF8), hex(0x8DC6EE)])!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)
func hill(_ base: CGFloat, _ amp: CGFloat, _ color: NSColor, _ phase: CGFloat) {
    let p = NSBezierPath(); p.move(to: .zero)
    for i in 0...80 { let x = CGFloat(i) / 80 * W; p.line(to: NSPoint(x: x, y: base + amp * sin(x / W * .pi * 2.4 + phase))) }
    p.line(to: NSPoint(x: W, y: 0)); p.close(); color.setFill(); p.fill()
}
hill(250, 22, hex(0xA9CFB4), 0.4)
hill(190, 16, hex(0x86BB8C), 2.1)
hill(120, 10, hex(0x6DAA55), 1.0)
func pine(_ x: CGFloat, _ y: CGFloat, _ h: CGFloat, _ c: NSColor) {
    hex(0x6B4A32).setFill()
    NSBezierPath(rect: NSRect(x: x - h * 0.05, y: y, width: h * 0.1, height: h * 0.22)).fill()
    for i in 0..<3 {
        let top = y + h - CGFloat(i) * h * 0.24, w = h * (0.32 + CGFloat(i) * 0.14)
        let p = NSBezierPath(); p.move(to: NSPoint(x: x, y: top))
        p.line(to: NSPoint(x: x + w / 2, y: top - h * 0.42)); p.line(to: NSPoint(x: x - w / 2, y: top - h * 0.42)); p.close()
        c.setFill(); p.fill()
    }
}
for (x, h) in [(40.0, 120.0), (95.0, 80.0), (1010.0, 130.0), (1070.0, 90.0), (960.0, 70.0), (150.0, 60.0)] {
    pine(x, 150, h, hex([0x2F7D4F, 0x3A8A55, 0x2C6E4A][Int(x) % 3]))
}
// dashed arrow between the icons
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 430, y: 420)); arrow.curve(to: NSPoint(x: 680, y: 420), controlPoint1: NSPoint(x: 500, y: 470), controlPoint2: NSPoint(x: 610, y: 470))
arrow.lineWidth = 6; arrow.setLineDash([16, 12], count: 2, phase: 0); arrow.lineCapStyle = .round
hex(0xFF6B1A).setStroke(); arrow.stroke()
let head = NSBezierPath(); head.move(to: NSPoint(x: 690, y: 412)); head.line(to: NSPoint(x: 660, y: 440)); head.line(to: NSPoint(x: 655, y: 400)); head.close()
hex(0xFF6B1A).setFill(); head.fill()
let para = NSMutableParagraphStyle(); para.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30, weight: .bold), .foregroundColor: hex(0x23402B), .paragraphStyle: para]
("Drag Timber into Applications" as NSString).draw(in: NSRect(x: 0, y: 610, width: W, height: 50), withAttributes: attrs)
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
