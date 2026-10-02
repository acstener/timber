import SwiftUI

enum Species {
    case pine, oak, birch, maple, blossom, dead, bush

    var aspect: CGFloat {
        switch self {
        case .pine: return 0.6
        case .oak, .maple, .blossom: return 0.76
        case .birch: return 0.58
        case .dead: return 0.78
        case .bush: return 2.2
        }
    }

    /// A folder that's mostly media grows as a blossom, mostly installers as a birch, etc.
    private static func dominant(_ node: Node) -> Species? {
        guard node.size > 0 else { return nil }
        var media: Int64 = 0, install: Int64 = 0, apps: Int64 = 0
        for c in node.children.prefix(40) {
            switch c.kind {
            case .video, .image, .audio: media += c.size
            case .installer, .archive, .diskImage: install += c.size
            case .app: apps += c.size
            default: break
            }
        }
        let half = node.size / 2
        if media > half { return .blossom }
        if install > half { return .birch }
        if apps > half { return .maple }
        return nil
    }

    static func of(_ node: Node, deadwood: Bool) -> Species {
        if deadwood { return .dead }
        switch node.kind {
        case .folder: return dominant(node) ?? .pine
        case .app: return .maple
        case .video, .image, .audio: return .blossom
        case .installer, .archive, .diskImage: return .birch
        case .bundle: return .oak
        default: return node.isDirectory ? .pine : .oak
        }
    }
}

// MARK: - Shapes

struct PineCanopy: Shape {
    var tiers = 4
    func path(in r: CGRect) -> Path {
        var p = Path()
        let overlap: CGFloat = 0.62
        let tierH = r.height / (CGFloat(tiers - 1) * overlap + 1)
        for i in 0..<tiers {
            let top = r.minY + CGFloat(i) * tierH * overlap
            let bottom = top + tierH
            let w = r.width * (0.42 + 0.58 * CGFloat(i + 1) / CGFloat(tiers))
            let cx = r.midX
            p.move(to: CGPoint(x: cx, y: top))
            p.addQuadCurve(to: CGPoint(x: cx + w / 2, y: bottom), control: CGPoint(x: cx + w * 0.18, y: top + tierH * 0.55))
            p.addQuadCurve(to: CGPoint(x: cx - w / 2, y: bottom), control: CGPoint(x: cx, y: bottom + tierH * 0.16))
            p.addQuadCurve(to: CGPoint(x: cx, y: top), control: CGPoint(x: cx - w * 0.18, y: top + tierH * 0.55))
            p.closeSubpath()
        }
        return p
    }
}

/// A cloud of overlapping circles: oaks, maples, blossoms, bushes.
struct BlobCanopy: Shape {
    var seed: String
    var lobes = 7
    func path(in r: CGRect) -> Path {
        var rng = Seeded(seed)
        var p = Path()
        let core = CGRect(x: r.minX + r.width * 0.12, y: r.minY + r.height * 0.18, width: r.width * 0.76, height: r.height * 0.78)
        p.addEllipse(in: core)
        for i in 0..<lobes {
            let a = Double(i) / Double(lobes) * 2 * .pi + rng.range(-0.3, 0.3)
            let rad = rng.range(0.26, 0.36) * min(r.width, r.height * 1.1)
            let cx = r.midX + CGFloat(cos(a)) * (r.width / 2 - rad * 0.95)
            let cy = r.midY + CGFloat(sin(a)) * (r.height / 2 - rad * 0.95)
            p.addEllipse(in: CGRect(x: cx - rad, y: cy - rad, width: rad * 2, height: rad * 2))
        }
        return p
    }
}

struct TaperTrunk: Shape {
    var topWidth: CGFloat = 0.55
    func path(in r: CGRect) -> Path {
        var p = Path()
        let tw = r.width * topWidth
        p.move(to: CGPoint(x: r.midX - tw / 2, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX + tw / 2, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.midX + tw / 2, y: r.maxY - r.height * 0.15))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.midX - tw / 2, y: r.minY), control: CGPoint(x: r.midX - tw / 2, y: r.maxY - r.height * 0.15))
        p.closeSubpath()
        return p
    }
}

struct AxeShape: Shape {
    /// Handle along the vertical centre line, head at the top facing right.
    func path(in r: CGRect) -> Path {
        var p = Path()
        let hw = r.width * 0.13
        p.addRoundedRect(in: CGRect(x: r.midX - hw / 2, y: r.minY + r.height * 0.06, width: hw, height: r.height * 0.94), cornerSize: CGSize(width: hw / 2, height: hw / 2))
        return p
    }
}

struct AxeHead: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let top = r.minY, h = r.height * 0.3
        p.move(to: CGPoint(x: r.midX - r.width * 0.16, y: top + h * 0.15))
        p.addLine(to: CGPoint(x: r.midX + r.width * 0.12, y: top + h * 0.2))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: top - h * 0.05), control: CGPoint(x: r.midX + r.width * 0.35, y: top + h * 0.1))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: top + h * 1.05), control: CGPoint(x: r.maxX + r.width * 0.12, y: top + h * 0.5))
        p.addQuadCurve(to: CGPoint(x: r.midX + r.width * 0.12, y: top + h * 0.8), control: CGPoint(x: r.midX + r.width * 0.35, y: top + h * 0.9))
        p.addLine(to: CGPoint(x: r.midX - r.width * 0.16, y: top + h * 0.85))
        p.closeSubpath()
        return p
    }
}

struct AxeIcon: View {
    var body: some View {
        ZStack {
            AxeShape().fill(Color(hex: 0xB07A45))
            AxeHead().fill(LinearGradient(colors: [Color(hex: 0xE8EDF2), Color(hex: 0x8D99A6)], startPoint: .leading, endPoint: .trailing))
        }
        .rotationEffect(.degrees(30))
    }
}

struct TreeHitShape: Shape {
    var species: Species
    func path(in r: CGRect) -> Path {
        var p = Path()
        switch species {
        case .bush:
            p.addEllipse(in: r)
        case .pine, .birch:
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY * 0.85))
            p.addLine(to: CGPoint(x: r.midX + r.width * 0.12, y: r.maxY))
            p.addLine(to: CGPoint(x: r.midX - r.width * 0.12, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY * 0.85))
            p.closeSubpath()
        default:
            p.addEllipse(in: CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.78))
            p.addRect(CGRect(x: r.midX - r.width * 0.12, y: r.minY + r.height * 0.5, width: r.width * 0.24, height: r.height * 0.5))
        }
        return p
    }
}

// MARK: - Tree body

struct TreeBody: View {
    var species: Species
    var seed: String
    var notch: Int = 0
    var notchSide: CGFloat = -1
    var mark: RangerVerdict.Mark? = nil
    @Environment(\.palette) private var pal

    private var rngBase: Seeded { Seeded(seed) }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                switch species {
                case .pine: pine(w, h)
                case .oak: round(w, h, colors: [0x5DA84E, 0x4C9A45, 0x6BB55A, 0x3F8A44])
                case .maple: round(w, h, colors: [0xE2582E, 0xD9462B, 0xEE7A35, 0xC93D2A])
                case .blossom: round(w, h, colors: [0xF4A6C0, 0xEE93B3, 0xF7B8CD, 0xE985AA])
                case .birch: birch(w, h)
                case .dead: dead(w, h)
                case .bush: bush(w, h)
                }
                if species != .bush { trunkDecor(w, h) }
            }
        }
    }

    private func foliage(_ options: [UInt32]) -> Color {
        var rng = rngBase
        let c = Color(hex: options[Int(rng.next() * Double(options.count)) % options.count])
        return c.shaded(pal.foliageShift)
    }

    private var trunkColors: [Color] { [Color.bark.shaded(pal.foliageShift + 0.08), Color.barkDark.shaded(pal.foliageShift)] }

    @ViewBuilder private func pine(_ w: CGFloat, _ h: CGFloat) -> some View {
        let base = foliage([0x2F7D4F, 0x3A8A55, 0x2C6E4A, 0x45935A, 0x26684A])
        TaperTrunk(topWidth: 0.6)
            .fill(LinearGradient(colors: trunkColors, startPoint: .leading, endPoint: .trailing))
            .frame(width: w * 0.13, height: h * 0.22)
            .offset(x: w * 0.435, y: h * 0.78)
        PineCanopy()
            .fill(LinearGradient(colors: [base.shaded(0.12), base, base.shaded(-0.25)], startPoint: .leading, endPoint: .trailing))
            .frame(width: w, height: h * 0.86)
        PineCanopy()
            .fill(base.shaded(0.28).opacity(0.35))
            .frame(width: w * 0.42, height: h * 0.7)
            .offset(x: w * 0.2, y: h * 0.05)
            .blendMode(.softLight)
    }

    @ViewBuilder private func round(_ w: CGFloat, _ h: CGFloat, colors: [UInt32]) -> some View {
        let base = foliage(colors)
        TaperTrunk(topWidth: 0.5)
            .fill(LinearGradient(colors: trunkColors, startPoint: .leading, endPoint: .trailing))
            .frame(width: w * 0.15, height: h * 0.42)
            .offset(x: w * 0.425, y: h * 0.58)
        BlobCanopy(seed: seed)
            .fill(LinearGradient(colors: [base.shaded(0.15), base, base.shaded(-0.22)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: w, height: h * 0.74)
        BlobCanopy(seed: seed + "hi", lobes: 4)
            .fill(base.shaded(0.35).opacity(0.3))
            .frame(width: w * 0.5, height: h * 0.36)
            .offset(x: w * 0.14, y: h * 0.06)
    }

    @ViewBuilder private func birch(_ w: CGFloat, _ h: CGFloat) -> some View {
        let base = foliage([0xF2C14E, 0xE9B53F, 0xF5CF6A]).shaded(0)
        ZStack(alignment: .top) {
            Rectangle().fill(Color(hex: 0xF1EEE6).shaded(pal.foliageShift))
            VStack(spacing: h * 0.05) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule().fill(Color(hex: 0x2B2B2B).opacity(0.75)).frame(width: w * (i.isMultiple(of: 2) ? 0.06 : 0.04), height: 2)
                        .offset(x: i.isMultiple(of: 2) ? -w * 0.015 : w * 0.02)
                }
            }
            .padding(.top, h * 0.04)
        }
        .frame(width: w * 0.1, height: h * 0.55)
        .offset(x: w * 0.45, y: h * 0.45)
        BlobCanopy(seed: seed, lobes: 6)
            .fill(LinearGradient(colors: [base.shaded(0.15), base, base.shaded(-0.2)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: w, height: h * 0.66)
    }

    @ViewBuilder private func dead(_ w: CGFloat, _ h: CGFloat) -> some View {
        let wood = Color(hex: 0x8A7563).shaded(pal.foliageShift)
        Canvas { ctx, size in
            var rng = Seeded(seed)
            func branch(_ from: CGPoint, _ angle: Double, _ len: CGFloat, _ width: CGFloat, _ depth: Int) {
                let to = CGPoint(x: from.x + CGFloat(cos(angle)) * len, y: from.y + CGFloat(sin(angle)) * len)
                var p = Path(); p.move(to: from)
                p.addQuadCurve(to: to, control: CGPoint(x: (from.x + to.x) / 2 + CGFloat(rng.range(-0.1, 0.1)) * len, y: (from.y + to.y) / 2))
                ctx.stroke(p, with: .color(wood), style: StrokeStyle(lineWidth: width, lineCap: .round))
                guard depth > 0 else { return }
                let n = depth > 2 ? 2 : Int(rng.range(2, 3.99))
                for _ in 0..<n {
                    branch(to, angle + rng.range(-0.75, 0.75), len * CGFloat(rng.range(0.55, 0.75)), max(1, width * 0.62), depth - 1)
                }
            }
            let base = CGPoint(x: size.width / 2, y: size.height)
            let trunkTop = CGPoint(x: size.width / 2, y: size.height * 0.5)
            var trunk = Path()
            trunk.move(to: CGPoint(x: base.x - size.width * 0.07, y: base.y))
            trunk.addLine(to: CGPoint(x: trunkTop.x - size.width * 0.03, y: trunkTop.y))
            trunk.addLine(to: CGPoint(x: trunkTop.x + size.width * 0.03, y: trunkTop.y))
            trunk.addLine(to: CGPoint(x: base.x + size.width * 0.07, y: base.y))
            trunk.closeSubpath()
            ctx.fill(trunk, with: .color(wood))
            branch(trunkTop, -.pi / 2 - 0.45, size.height * 0.22, size.width * 0.05, 3)
            branch(trunkTop, -.pi / 2 + 0.4, size.height * 0.24, size.width * 0.05, 3)
            branch(CGPoint(x: trunkTop.x, y: trunkTop.y + size.height * 0.1), -.pi / 2 + 1.0, size.height * 0.16, size.width * 0.035, 2)
            // a few last brown leaves
            for _ in 0..<7 {
                let x = rng.range(0.15, 0.85) * size.width, y = rng.range(0.08, 0.45) * size.height
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 5, height: 3.5)), with: .color(Color(hex: 0xB9824A).opacity(0.8)))
            }
        }
    }

    @ViewBuilder private func bush(_ w: CGFloat, _ h: CGFloat) -> some View {
        let base = foliage([0x3F7F43, 0x4A8A4A]).shaded(-0.05)
        BlobCanopy(seed: seed, lobes: 9)
            .fill(LinearGradient(colors: [base.shaded(0.12), base.shaded(-0.2)], startPoint: .top, endPoint: .bottom))
    }

    /// Axe notch and the ranger's paint mark on the trunk.
    @ViewBuilder private func trunkDecor(_ w: CGFloat, _ h: CGFloat) -> some View {
        let trunkW: CGFloat = species == .pine ? w * 0.11 : (species == .birch ? w * 0.1 : w * 0.13)
        let y = h * 0.9
        if notch > 0 {
            let d = trunkW * 0.22 * CGFloat(notch)
            Path { p in
                let x = w / 2 + notchSide * trunkW / 2
                p.move(to: CGPoint(x: x, y: y - d * 0.6))
                p.addLine(to: CGPoint(x: x - notchSide * d, y: y))
                p.addLine(to: CGPoint(x: x, y: y + d * 0.35))
                p.closeSubpath()
            }
            .fill(Color.sawdust)
        }
        if let mark {
            let markY = species == .pine ? h * 0.83 : h * 0.72
            Group {
                switch mark {
                case .chop:
                    Capsule().fill(Color.blaze)
                        .frame(width: trunkW * 1.25, height: max(3, trunkW * 0.42))
                        .rotationEffect(.degrees(-22))
                case .review:
                    Circle().fill(Color.reviewGold).frame(width: trunkW * 0.75, height: trunkW * 0.75)
                case .keep:
                    Capsule().fill(Color.keepBlue)
                        .frame(width: trunkW * 1.1, height: max(3, trunkW * 0.35))
                }
            }
            .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
            .position(x: w / 2, y: markY)
            .transition(.scale(scale: 0.2).combined(with: .opacity))
        }
    }
}

// MARK: - Particles

final class ParticleSim {
    enum Kind { case chip, leaf, dust, spark }
    struct P {
        var x, y, vx, vy: Double
        var life, maxLife: Double
        var size: Double
        var rot, spin: Double
        var color: Color
        var kind: Kind
        var delay: Double
        var gravity: Double
        var drag: Double
    }
    var ps: [P] = []
    private var last: TimeInterval = 0

    func burst(_ kind: Kind, at pt: CGPoint, count: Int, dir: Double, spread: Double, speed: ClosedRange<Double>,
               colors: [Color], size: ClosedRange<Double>, delay: Double = 0, life: ClosedRange<Double> = 0.6...1.1) {
        for _ in 0..<count {
            let a = dir + Double.random(in: -spread...spread)
            let s = Double.random(in: speed)
            let g: Double, dr: Double
            switch kind {
            case .chip: g = 900; dr = 0.4
            case .leaf: g = 120; dr = 2.2
            case .dust: g = -20; dr = 2.8
            case .spark: g = 300; dr = 1
            }
            let l = Double.random(in: life)
            ps.append(P(x: pt.x, y: pt.y, vx: cos(a) * s, vy: sin(a) * s, life: l, maxLife: l, size: Double.random(in: size),
                        rot: Double.random(in: 0...6.28), spin: Double.random(in: -12...12), color: colors.randomElement() ?? .white,
                        kind: kind, delay: delay + Double.random(in: 0...0.04), gravity: g, drag: dr))
        }
        last = 0
    }

    func step(_ t: TimeInterval) {
        let dt = last == 0 ? 1.0 / 60 : min(0.05, t - last)
        last = t
        for i in ps.indices.reversed() {
            if ps[i].delay > 0 { ps[i].delay -= dt; continue }
            ps[i].vy += ps[i].gravity * dt
            ps[i].vx *= (1 - ps[i].drag * dt)
            ps[i].vy *= (1 - ps[i].drag * dt * (ps[i].kind == .chip ? 0.2 : 1))
            ps[i].x += ps[i].vx * dt
            ps[i].y += ps[i].vy * dt
            ps[i].rot += ps[i].spin * dt
            if ps[i].kind == .leaf { ps[i].vx += sin(t * 4 + ps[i].rot) * 40 * dt }
            ps[i].life -= dt
            if ps[i].life <= 0 { ps.remove(at: i) }
        }
    }

    func draw(_ ctx: inout GraphicsContext) {
        for p in ps where p.delay <= 0 {
            let fade = min(1, p.life / p.maxLife * 2.2)
            var c = ctx
            c.translateBy(x: p.x, y: p.y)
            c.rotate(by: .radians(p.rot))
            switch p.kind {
            case .chip:
                c.fill(Path(roundedRect: CGRect(x: -p.size, y: -p.size * 0.35, width: p.size * 2, height: p.size * 0.7), cornerRadius: 1), with: .color(p.color.opacity(fade)))
            case .leaf:
                c.fill(Path(ellipseIn: CGRect(x: -p.size, y: -p.size * 0.45, width: p.size * 2, height: p.size * 0.9)), with: .color(p.color.opacity(fade)))
            case .dust:
                let grow = 1 + (1 - p.life / p.maxLife) * 2.2
                let r = p.size * grow
                c.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2)), with: .color(p.color.opacity(0.35 * fade)))
            case .spark:
                c.fill(Path(ellipseIn: CGRect(x: -p.size / 2, y: -p.size / 2, width: p.size, height: p.size)), with: .color(p.color.opacity(fade)))
            }
        }
    }
}

// MARK: - A living, choppable tree

struct TreeView: View {
    let node: Node
    let species: Species
    let height: CGFloat
    var haze: Double = 0
    var alwaysLabel = true
    var interactive = true
    var dir: CGFloat = 1
    var sproutDelay: Double = 0

    @Environment(ForestModel.self) private var model
    @Environment(\.palette) private var pal
    @State private var swayOn = false
    @State private var grown = false
    @State private var sim = ParticleSim()
    @State private var floatUp = false

    private var width: CGFloat { height * species.aspect }
    private var phase: ChopPhase? { model.chopPhases[node.id] }
    private var isSelected: Bool { model.selected === node }
    private var isHovered: Bool { model.hovered === node }
    private var verdict: RangerVerdict? { model.verdicts[node.path] }
    private var pending: Bool { model.rangerPending.contains(node.path) }

    private var swingCount: Int {
        if case .swing(let n) = phase { return n }
        return 0
    }
    private var fallAngle: Double {
        switch phase {
        case .falling, .fallen: return 88 * Double(dir)
        default: return 0
        }
    }
    private var trunkW: CGFloat { width * 0.12 }
    private var fxSize: CGSize { CGSize(width: max(width, height) * 3, height: height * 1.7) }

    var body: some View {
        treeStack
            .frame(width: width, height: height)
            .overlay(alignment: .bottom) { fxLayer }
            .overlay(alignment: .bottom) { axeLayer }
            .overlay(alignment: .bottom) { labelLayer }
            .overlay(alignment: .top) { exclamation }
            .scaleEffect(x: grown ? 1 : 0.4, y: grown ? 1 : 0.01, anchor: .bottom)
            .onAppear {
                withAnimation(.spring(duration: 0.7, bounce: 0.4).delay(sproutDelay)) { grown = true }
                withAnimation(.easeInOut(duration: Double.random(in: 2.6...4.2)).repeatForever(autoreverses: true).delay(Double.random(in: 0...1))) {
                    swayOn = true
                }
            }
            .onChange(of: phase) { _, new in react(to: new) }
            .contentShape(TreeHitShape(species: species))
            .onHover { inside in
                guard interactive else { return }
                if inside { model.hovered = node } else if model.hovered === node { model.hovered = nil }
            }
            .gesture(TapGesture().onEnded { if interactive { model.select(node) } })
            .simultaneousGesture(TapGesture(count: 2).onEnded { if interactive { model.enter(node) } })
            .contextMenu { if interactive { TreeMenu(node: node) } }
            .zIndex(phase != nil ? 10 : (isSelected ? 2 : 0))
            .help(interactive ? "\(node.displayName) — \(Fmt.bytes(node.size))" : "")
    }

    private var treeStack: some View {
        ZStack(alignment: .bottom) {
            Ellipse()
                .fill(.black.opacity(pal.isNight ? 0.3 : 0.18))
                .frame(width: width * 0.95, height: max(6, height * 0.05))
                .blur(radius: 3)
                .offset(y: height * 0.02)
                .opacity(phase == .fallen ? 0.4 : 1)

            if isSelected {
                SelectionRing()
                    .frame(width: max(width * 1.05, 40), height: max(14, height * 0.08))
                    .offset(y: height * 0.03)
            }

            if phase == .falling || phase == .fallen {
                Stump(seed: node.path)
                    .frame(width: max(trunkW * 1.6, 10), height: max(6, height * 0.05))
                    .transition(.opacity)
            }

            TreeBody(species: species, seed: node.path, notch: notchLevel, notchSide: -dir, mark: verdict?.policyMark)
                .rotationEffect(.degrees(swayOn && phase == nil ? 1.4 : -1.4), anchor: .bottom)
                .keyframeAnimator(initialValue: 0.0, trigger: swingCount) { content, x in
                    content.offset(x: x)
                } keyframes: { _ in
                    KeyframeTrack {
                        LinearKeyframe(0, duration: 0.1)
                        SpringKeyframe(-dir * 4, duration: 0.05)
                        SpringKeyframe(dir * 2.5, duration: 0.08)
                        SpringKeyframe(0, duration: 0.2)
                    }
                }
                .keyframeAnimator(initialValue: 0.0, trigger: phase == .bounce) { content, x in
                    content.offset(x: x)
                } keyframes: { _ in
                    KeyframeTrack {
                        SpringKeyframe(6, duration: 0.06)
                        SpringKeyframe(-6, duration: 0.08)
                        SpringKeyframe(4, duration: 0.08)
                        SpringKeyframe(0, duration: 0.2)
                    }
                }
                .rotationEffect(.degrees(fallAngle), anchor: .bottom)
                .animation(phase == .falling ? .timingCurve(0.55, 0, 0.95, 0.55, duration: 0.95) : .spring(duration: 0.3), value: fallAngle)
                .opacity(phase == .fallen ? 0 : 1)
                .animation(.easeIn(duration: 0.55).delay(0.15), value: phase == .fallen)
                .brightness(isHovered && phase == nil ? 0.06 : 0)
                .saturation(1 - haze * 0.35)
                .opacity(1 - haze * 0.15)

            if pending {
                RangerPulse().frame(width: 18, height: 18).offset(y: -height - 6)
            }
        }
    }

    private var notchLevel: Int {
        switch phase {
        case .swing(let n): return n
        case .bounce: return 1
        case .falling, .fallen: return 3
        default: return 0
        }
    }

    private var fxLayer: some View {
        TimelineView(.animation(minimumInterval: nil, paused: phase == nil && sim.ps.isEmpty)) { tl in
            Canvas { ctx, _ in
                sim.step(tl.date.timeIntervalSinceReferenceDate)
                sim.draw(&ctx)
            }
        }
        .frame(width: fxSize.width, height: fxSize.height)
        .allowsHitTesting(false)
    }

    private var axeLayer: some View {
        let L = min(max(height * 0.42, 34), 96)
        return Group {
            if case .swing = phase {
                axe(L)
            } else if phase == .bounce {
                axe(L)
            }
        }
        .frame(width: fxSize.width, height: fxSize.height, alignment: .bottom)
        .allowsHitTesting(false)
    }

    private func axe(_ L: CGFloat) -> some View {
        // Pivot (the hands) sits so the head meets the trunk at ~70°.
        let notchY = height * 0.1
        return AxeIcon()
            .rotationEffect(.degrees(-30))
            .frame(width: L * 0.55, height: L)
            .keyframeAnimator(initialValue: -35.0, trigger: swingCount) { content, angle in
                content.rotationEffect(.degrees(angle), anchor: .bottom)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(-40, duration: 0.02)
                    CubicKeyframe(68, duration: 0.09)
                    SpringKeyframe(58, duration: 0.08)
                    CubicKeyframe(-35, duration: 0.22)
                }
            }
            .scaleEffect(x: dir, y: 1)
            .offset(x: -dir * (trunkW / 2 + L * 0.9), y: -(notchY - L * 0.32))
            .transition(.scale(scale: 0.5, anchor: .bottom).combined(with: .opacity))
    }

    @ViewBuilder private var labelLayer: some View {
        let show = interactive && (alwaysLabel || isHovered || isSelected) && phase != .falling && phase != .fallen
        if show {
            TreeLabel(node: node, emphasised: isSelected || isHovered, compact: !alwaysLabel)
                .fixedSize()
                .offset(y: alwaysLabel ? 40 : 34)
                .transition(.opacity.combined(with: .offset(y: 4)))
                .allowsHitTesting(false)
        }
        if phase == .fallen {
            Text("+\(Fmt.bytes(node.size))")
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                .offset(y: floatUp ? -height * 0.5 : 0)
                .opacity(floatUp ? 0 : 1)
                .onAppear { withAnimation(.easeOut(duration: 1.1)) { floatUp = true } }
                .fixedSize()
        }
    }

    @ViewBuilder private var exclamation: some View {
        if phase == .falling {
            Text("TIMBER!")
                .font(.system(size: max(16, min(30, height * 0.12)), weight: .black, design: .rounded))
                .foregroundStyle(Color.sawdust)
                .shadow(color: Color.barkDark, radius: 0, x: 2, y: 2)
                .rotationEffect(.degrees(-8 * Double(dir)))
                .fixedSize()
                .offset(x: dir * width * 0.6, y: -34)
                .transition(.scale(scale: 0.2).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }

    private func react(to p: ChopPhase?) {
        let base = CGPoint(x: fxSize.width / 2, y: fxSize.height)
        let notch = CGPoint(x: base.x - dir * trunkW / 2, y: base.y - height * 0.1)
        let chipColors = [Color.sawdust, Color(hex: 0xD9A866), Color(hex: 0xF3DDB3), Color.bark]
        switch p {
        case .swing:
            sim.burst(.chip, at: notch, count: 14, dir: dir > 0 ? -.pi * 0.8 : -.pi * 0.2, spread: 0.7, speed: 140...360,
                      colors: chipColors, size: 2...4.5, delay: 0.1)
        case .falling:
            let leafColors = leafPalette
            sim.burst(.leaf, at: CGPoint(x: base.x, y: base.y - height * 0.7), count: 16, dir: -.pi / 2, spread: 1.4,
                      speed: 30...120, colors: leafColors, size: 2.5...5, delay: 0.25, life: 1.2...2.0)
        case .fallen:
            let land = CGPoint(x: base.x + dir * height * 0.75, y: base.y - 4)
            sim.burst(.dust, at: land, count: 22, dir: -.pi / 2, spread: 1.5, speed: 40...160,
                      colors: [Color(hex: 0xC9B79C), Color(hex: 0xA89880), .white], size: 6...14, life: 0.8...1.4)
            sim.burst(.leaf, at: land, count: 22, dir: -.pi / 2, spread: 1.3, speed: 80...260,
                      colors: leafPalette, size: 2.5...5, life: 1.0...1.8)
            sim.burst(.chip, at: base, count: 8, dir: -.pi / 2, spread: 0.9, speed: 80...220, colors: chipColors, size: 2...4)
        case .bounce:
            sim.burst(.spark, at: notch, count: 10, dir: dir > 0 ? -.pi * 0.85 : -.pi * 0.15, spread: 0.5, speed: 160...320,
                      colors: [Color(hex: 0xFFF2B0), .white], size: 1.5...3, life: 0.2...0.4)
        default: break
        }
    }

    private var leafPalette: [Color] {
        switch species {
        case .maple: return [Color(hex: 0xE2582E), Color(hex: 0xF08A3C), Color(hex: 0xC93D2A)]
        case .blossom: return [Color(hex: 0xF4A6C0), Color(hex: 0xFFD3E1), .white]
        case .birch: return [Color(hex: 0xF2C14E), Color(hex: 0xF5CF6A)]
        case .dead: return [Color(hex: 0xB9824A), Color(hex: 0x8A7563)]
        default: return [Color(hex: 0x3A8A55), Color(hex: 0x5DA84E), Color(hex: 0x2C6E4A)]
        }
    }
}

struct Stump: View {
    var seed: String
    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(LinearGradient(colors: [Color.bark, Color.barkDark], startPoint: .leading, endPoint: .trailing))
                .padding(.top, 2)
            Ellipse().fill(Color.sawdust)
                .overlay(Ellipse().stroke(Color(hex: 0xB98D58), lineWidth: 1).padding(2))
                .frame(height: 5)
        }
    }
}

struct SelectionRing: View {
    @State private var pulse = false
    var body: some View {
        Ellipse()
            .stroke(Color.blaze, lineWidth: 2.5)
            .background(Ellipse().fill(Color.blaze.opacity(0.18)))
            .scaleEffect(pulse ? 1.08 : 0.96)
            .opacity(pulse ? 0.75 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

struct RangerPulse: View {
    @State private var on = false
    var body: some View {
        Image(systemName: "binoculars.fill")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(5)
            .background(Circle().fill(Color.keepBlue))
            .scaleEffect(on ? 1.15 : 0.9)
            .onAppear { withAnimation(.easeInOut(duration: 0.5).repeatForever()) { on = true } }
    }
}

struct TreeLabel: View {
    let node: Node
    var emphasised: Bool
    var compact: Bool
    @Environment(ForestModel.self) private var model

    var body: some View {
        VStack(spacing: 1) {
            Text(node.displayName)
                .font(.system(size: compact ? 11 : 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 130)
            Text(Fmt.bytes(node.size))
                .font(.system(size: compact ? 10 : 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(emphasised ? Color.blaze.opacity(0.9) : .white.opacity(0.15), lineWidth: emphasised ? 1.5 : 0.5))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .scaleEffect(emphasised ? 1.06 : 1)
        .animation(.spring(duration: 0.25), value: emphasised)
    }
}

struct TreeMenu: View {
    let node: Node
    @Environment(ForestModel.self) private var model
    var body: some View {
        Button("Chop") { model.requestChop(node) }
        if node.isDirectory && !node.children.isEmpty { Button("Walk In") { model.enter(node) } }
        Button("Ask the Ranger") { model.askRanger([node]) }
        Divider()
        Button("Reveal in Finder") { model.revealInFinder(node) }
        Button("Quick Look") { model.quickLookURL = node.url }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.path, forType: .string)
        }
    }
}
