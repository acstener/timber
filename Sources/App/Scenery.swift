import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
    static let blaze = Color(hex: 0xFF6B1A)     // forester's marking paint
    static let keepBlue = Color(hex: 0x3D8BFF)
    static let reviewGold = Color(hex: 0xF5C542)
    static let bark = Color(hex: 0x6B4A32)
    static let barkDark = Color(hex: 0x4A3222)
    static let sawdust = Color(hex: 0xE9C894)
}

/// Sky, hills and ground follow the time of day.
struct Palette: Equatable {
    var skyTop: Color
    var skyBottom: Color
    var hillFar: Color
    var hillMid: Color
    var hillNear: Color
    var groundTop: Color
    var groundBottom: Color
    var sun: Color
    var isNight: Bool
    var foliageShift: Double   // 0 day, negative = darker
    var haze: Color

    static let day = Palette(skyTop: Color(hex: 0x6FB8EE), skyBottom: Color(hex: 0xD9EEF8), hillFar: Color(hex: 0xA9CFB4),
                             hillMid: Color(hex: 0x86BB8C), hillNear: Color(hex: 0x6AA66B), groundTop: Color(hex: 0x6DAA55),
                             groundBottom: Color(hex: 0x3F7A3A), sun: Color(hex: 0xFFF3C4), isNight: false, foliageShift: 0,
                             haze: Color(hex: 0xD9EEF8))
    static let dawn = Palette(skyTop: Color(hex: 0x8DA7D8), skyBottom: Color(hex: 0xFAD6B8), hillFar: Color(hex: 0xC2B4C4),
                              hillMid: Color(hex: 0x98A891), hillNear: Color(hex: 0x76966A), groundTop: Color(hex: 0x6E9A55),
                              groundBottom: Color(hex: 0x3E6A38), sun: Color(hex: 0xFFE0B0), isNight: false, foliageShift: -0.03,
                              haze: Color(hex: 0xFAD6B8))
    static let dusk = Palette(skyTop: Color(hex: 0x3B3F78), skyBottom: Color(hex: 0xF4A46A), hillFar: Color(hex: 0x8C6E8E),
                              hillMid: Color(hex: 0x5E5F72), hillNear: Color(hex: 0x3F5848), groundTop: Color(hex: 0x4C6E3F),
                              groundBottom: Color(hex: 0x27402A), sun: Color(hex: 0xFFC27A), isNight: false, foliageShift: -0.12,
                              haze: Color(hex: 0xE89A70))
    static let night = Palette(skyTop: Color(hex: 0x070D24), skyBottom: Color(hex: 0x23305A), hillFar: Color(hex: 0x1E2A48),
                               hillMid: Color(hex: 0x182A36), hillNear: Color(hex: 0x14282A), groundTop: Color(hex: 0x1C3626),
                               groundBottom: Color(hex: 0x0D1D14), sun: Color(hex: 0xF2F0E6), isNight: true, foliageShift: -0.3,
                               haze: Color(hex: 0x23305A))

    static func current(mode: String, date: Date = Date()) -> Palette {
        switch mode {
        case "day": return .day
        case "dusk": return .dusk
        case "night": return .night
        case "dawn": return .dawn
        default:
            let h = Calendar.current.component(.hour, from: date)
            switch h {
            case 5..<8: return .dawn
            case 8..<17: return .day
            case 17..<20: return .dusk
            default: return .night
            }
        }
    }
}

struct PaletteKey: EnvironmentKey { static let defaultValue = Palette.day }
extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Deterministic per-name randomness so a forest looks the same every visit.
struct Seeded {
    private var state: UInt64
    init(_ s: String) {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        state = h | 1
    }
    mutating func next() -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000
    }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
}

struct HillShape: Shape {
    var seed: String
    var baseline: CGFloat   // 0...1 from top
    var amplitude: CGFloat  // fraction of height

    func path(in r: CGRect) -> Path {
        var rng = Seeded(seed)
        let f1 = rng.range(1.2, 2.2), f2 = rng.range(2.5, 4.5), f3 = rng.range(6, 9)
        let p1 = rng.range(0, 6.28), p2 = rng.range(0, 6.28), p3 = rng.range(0, 6.28)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        let steps = 90
        for i in 0...steps {
            let x = CGFloat(i) / CGFloat(steps)
            let y = sin(Double(x) * f1 * .pi + p1) * 0.55 + sin(Double(x) * f2 * .pi + p2) * 0.3 + sin(Double(x) * f3 * .pi + p3) * 0.08
            p.addLine(to: CGPoint(x: r.minX + x * r.width, y: r.minY + r.height * (baseline - amplitude * CGFloat(y))))
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// Little pine silhouettes along a ridge for depth.
struct RidgeTrees: Shape {
    var seed: String
    var baseline: CGFloat
    var amplitude: CGFloat
    var count: Int

    func path(in r: CGRect) -> Path {
        var rng = Seeded(seed + "ridge")
        var hill = Seeded(seed)
        let f1 = hill.range(1.2, 2.2), f2 = hill.range(2.5, 4.5), f3 = hill.range(6, 9)
        let p1 = hill.range(0, 6.28), p2 = hill.range(0, 6.28), p3 = hill.range(0, 6.28)
        var p = Path()
        for _ in 0..<count {
            let x = rng.next()
            let y = sin(x * f1 * .pi + p1) * 0.55 + sin(x * f2 * .pi + p2) * 0.3 + sin(x * f3 * .pi + p3) * 0.08
            let baseY = r.minY + r.height * (baseline - amplitude * CGFloat(y)) + 3
            let h = CGFloat(rng.range(10, 26)) * r.height / 700
            let w = h * 0.45
            let cx = r.minX + CGFloat(x) * r.width
            p.move(to: CGPoint(x: cx, y: baseY - h))
            p.addLine(to: CGPoint(x: cx + w / 2, y: baseY))
            p.addLine(to: CGPoint(x: cx - w / 2, y: baseY))
            p.closeSubpath()
        }
        return p
    }
}

struct SceneBackdrop: View {
    @Environment(\.palette) private var pal
    var groundLine: CGFloat = 0.64

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [pal.skyTop, pal.skyBottom], startPoint: .top, endPoint: .bottom)

                if pal.isNight { Stars().opacity(0.9) }

                // Sun or moon
                Circle()
                    .fill(pal.sun)
                    .frame(width: size.height * 0.11, height: size.height * 0.11)
                    .shadow(color: pal.sun.opacity(0.8), radius: pal.isNight ? 18 : 40)
                    .overlay {
                        if pal.isNight {
                            Circle().fill(pal.skyTop.opacity(0.9))
                                .frame(width: size.height * 0.1, height: size.height * 0.1)
                                .offset(x: size.height * 0.035, y: -size.height * 0.02)
                        }
                    }
                    .position(x: size.width * 0.66, y: size.height * (pal.isNight ? 0.17 : 0.2))

                if !pal.isNight {
                    Clouds().frame(width: size.width, height: size.height * 0.4)
                }

                HillShape(seed: "far", baseline: groundLine - 0.13, amplitude: 0.07)
                    .fill(pal.hillFar)
                RidgeTrees(seed: "far", baseline: groundLine - 0.13, amplitude: 0.07, count: 70)
                    .fill(pal.hillFar.mix(with: pal.hillMid, by: 0.5))
                HillShape(seed: "mid", baseline: groundLine - 0.06, amplitude: 0.05)
                    .fill(pal.hillMid)
                RidgeTrees(seed: "mid", baseline: groundLine - 0.06, amplitude: 0.05, count: 50)
                    .fill(pal.hillMid.mix(with: pal.hillNear, by: 0.6))
                HillShape(seed: "near", baseline: groundLine, amplitude: 0.025)
                    .fill(LinearGradient(colors: [pal.groundTop, pal.groundBottom], startPoint: .top, endPoint: .bottom))

                if pal.isNight { Fireflies().allowsHitTesting(false) }
            }
        }
        .ignoresSafeArea()
    }
}

struct Clouds: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24)) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let span = size.width * 1.5
                for i in 0..<6 {
                    var rng = Seeded("cloud\(i)")
                    let y = rng.range(0.12, 0.8) * size.height
                    let s = rng.range(0.6, 1.4)
                    let speed = rng.range(4, 9)
                    let x = (rng.next() * span + t * speed).truncatingRemainder(dividingBy: span) - size.width * 0.25
                    let rect = CGRect(x: x, y: y, width: 180 * s, height: 58 * s)
                    ctx.fill(CloudPuff().path(in: rect), with: .color(.white.opacity(rng.range(0.55, 0.85))))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct CloudPuff: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addEllipse(in: CGRect(x: r.minX, y: r.minY + r.height * 0.35, width: r.width * 0.5, height: r.height * 0.65))
        p.addEllipse(in: CGRect(x: r.minX + r.width * 0.22, y: r.minY, width: r.width * 0.45, height: r.height * 0.9))
        p.addEllipse(in: CGRect(x: r.minX + r.width * 0.48, y: r.minY + r.height * 0.2, width: r.width * 0.52, height: r.height * 0.8))
        return p
    }
}

struct Stars: View {
    var body: some View {
        Canvas { ctx, size in
            var rng = Seeded("stars")
            for _ in 0..<140 {
                let x = rng.next() * size.width
                let y = rng.next() * size.height * 0.55
                let s = rng.range(0.6, 2.0)
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: s, height: s)), with: .color(.white.opacity(rng.range(0.3, 0.9))))
            }
        }
        .allowsHitTesting(false)
    }
}

struct Fireflies: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                var rng = Seeded("fireflies")
                for _ in 0..<26 {
                    let bx = rng.next(), by = rng.range(0.55, 0.95), sp = rng.range(0.2, 0.6), ph = rng.range(0, 6.28)
                    let x = (bx + 0.04 * sin(t * sp + ph)) * size.width
                    let y = (by + 0.03 * cos(t * sp * 1.3 + ph)) * size.height
                    let glow = max(0, sin(t * sp * 3 + ph))
                    let r = 2 + glow * 2
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r * 3, y: y - r * 3, width: r * 6, height: r * 6)), with: .color(Color(hex: 0xEFFF8A).opacity(0.12 * glow)))
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r / 2, y: y - r / 2, width: r, height: r)), with: .color(Color(hex: 0xF6FFB0).opacity(0.4 + 0.6 * glow)))
                }
            }
        }
    }
}

extension Color {
    func mix(with other: Color, by t: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .black
        return Color(.sRGB, red: a.redComponent + (b.redComponent - a.redComponent) * t,
                     green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                     blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
                     opacity: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * t)
    }

    func shaded(_ amount: Double) -> Color {
        amount >= 0 ? mix(with: .white, by: amount) : mix(with: .black, by: -amount)
    }
}
