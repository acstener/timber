// Renders the Timber app icon: a felled-forest badge with a pine and an axe.
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

func hex(_ h: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}

// Squircle background
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
ctx.saveGState()
let shadow = NSShadow(); shadow.shadowBlurRadius = 30; shadow.shadowOffset = NSSize(width: 0, height: -12); shadow.shadowColor = hex(0x000000, 0.35)
shadow.set()
hex(0x6FB8EE).setFill(); bg.fill()
ctx.restoreGState()
bg.addClip()
NSGradient(colors: [hex(0xF7C79A), hex(0x7FC1EE), hex(0x5AA9E6)], atLocations: [0, 0.45, 1], colorSpace: .sRGB)!.draw(in: rect, angle: 90)

// Sun
hex(0xFFF3C4).setFill()
NSBezierPath(ovalIn: NSRect(x: 600, y: 600, width: 170, height: 170)).fill()

// Hills
func hill(_ base: CGFloat, _ amp: CGFloat, _ color: NSColor, _ phase: CGFloat) {
    let p = NSBezierPath(); p.move(to: NSPoint(x: 0, y: 0))
    for i in 0...60 {
        let x = CGFloat(i) / 60 * size
        p.line(to: NSPoint(x: x, y: base + amp * sin(x / size * .pi * 2.2 + phase)))
    }
    p.line(to: NSPoint(x: size, y: 0)); p.close(); color.setFill(); p.fill()
}
hill(470, 30, hex(0xA9CFB4), 0.5)
hill(400, 24, hex(0x86BB8C), 2.0)
hill(330, 14, hex(0x5E9E55), 1.0)

// Pine
func tier(_ cx: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: cx, y: top))
    p.curve(to: NSPoint(x: cx + w / 2, y: top - h), controlPoint1: NSPoint(x: cx + w * 0.18, y: top - h * 0.5), controlPoint2: NSPoint(x: cx + w * 0.4, y: top - h * 0.9))
    p.curve(to: NSPoint(x: cx - w / 2, y: top - h), controlPoint1: NSPoint(x: cx + w * 0.2, y: top - h * 1.12), controlPoint2: NSPoint(x: cx - w * 0.2, y: top - h * 1.12))
    p.curve(to: NSPoint(x: cx, y: top), controlPoint1: NSPoint(x: cx - w * 0.4, y: top - h * 0.9), controlPoint2: NSPoint(x: cx - w * 0.18, y: top - h * 0.5))
    p.close()
    NSGradient(colors: [hex(0x4FA56A), hex(0x2F7D4F), hex(0x205E3C)])!.draw(in: p, angle: 0)
}
let cx: CGFloat = 470
hex(0x6B4A32).setFill()
NSBezierPath(roundedRect: NSRect(x: cx - 26, y: 250, width: 52, height: 130), xRadius: 10, yRadius: 10).fill()
tier(cx, 820, 260, 230)
tier(cx, 700, 340, 250)
tier(cx, 570, 420, 260)

// Orange blaze mark on the trunk
ctx.saveGState()
ctx.translateBy(x: cx, y: 320); ctx.rotate(by: 0.38)
hex(0xFF6B1A).setFill()
NSBezierPath(roundedRect: NSRect(x: -42, y: -11, width: 84, height: 22), xRadius: 11, yRadius: 11).fill()
ctx.restoreGState()

// Axe leaning against the tree
ctx.saveGState()
ctx.translateBy(x: 690, y: 240); ctx.rotate(by: 0.42)
hex(0xB07A45).setFill()
NSBezierPath(roundedRect: NSRect(x: -16, y: 0, width: 32, height: 400), xRadius: 16, yRadius: 16).fill()
let head = NSBezierPath()
head.move(to: NSPoint(x: -30, y: 395)); head.line(to: NSPoint(x: 40, y: 400))
head.curve(to: NSPoint(x: 150, y: 470), controlPoint1: NSPoint(x: 90, y: 410), controlPoint2: NSPoint(x: 130, y: 440))
head.curve(to: NSPoint(x: 150, y: 300), controlPoint1: NSPoint(x: 185, y: 420), controlPoint2: NSPoint(x: 185, y: 350))
head.curve(to: NSPoint(x: 40, y: 340), controlPoint1: NSPoint(x: 130, y: 320), controlPoint2: NSPoint(x: 90, y: 335))
head.line(to: NSPoint(x: -30, y: 345)); head.close()
NSGradient(colors: [hex(0xF2F5F8), hex(0x8D99A6)])!.draw(in: head, angle: 0)
ctx.restoreGState()

// Wood chips
hex(0xE9C894).setFill()
for (x, y, r) in [(560.0, 300.0, 0.4), (600.0, 340.0, -0.6), (380.0, 290.0, 0.9), (630.0, 280.0, 0.2)] {
    ctx.saveGState(); ctx.translateBy(x: x, y: y); ctx.rotate(by: r)
    NSBezierPath(roundedRect: NSRect(x: -16, y: -6, width: 32, height: 12), xRadius: 4, yRadius: 4).fill()
    ctx.restoreGState()
}
img.unlockFocus()

let out = CommandLine.arguments[1]
let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
