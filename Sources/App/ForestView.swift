import SwiftUI
import QuickLook

struct Slot: Identifiable {
    let node: Node
    let species: Species
    let x: CGFloat
    let baseY: CGFloat
    let height: CGFloat
    let row: Int
    let dir: CGFloat
    let order: Int
    var id: ObjectIdentifier { node.id }
}

enum ForestLayout {
    static let maxTrees = 22

    /// Biggest trees in the front row, centre-out; the rest scattered along a hazier back row.
    /// Height grows with the square root of size so canopy area tracks bytes.
    static func slots(for nodes: [Node], in rect: CGRect, deadwood: (Node) -> Bool) -> [Slot] {
        let nodes = Array(nodes.prefix(maxTrees)).filter { $0.size > 0 }
        guard let biggest = nodes.first?.size, biggest > 0 else { return [] }
        let H = rect.height
        let frontBase = rect.maxY - max(64, H * 0.12)
        let backBase = frontBase - max(70, H * 0.16)
        let maxH = min(frontBase - rect.minY - 60, H * 0.54, rect.width * 0.21 / Species.pine.aspect)
        let minH: CGFloat = max(34, H * 0.06)

        func h(_ n: Node) -> CGFloat {
            minH + (maxH - minH) * CGFloat(sqrt(Double(n.size) / Double(biggest)))
        }

        var front: [(Node, Species, CGFloat)] = []
        var used: CGFloat = 0
        var rest: [Node] = []
        for n in nodes {
            let sp = Species.of(n, deadwood: deadwood(n))
            let w = max(h(n) * sp.aspect * 0.92, 116)
            if front.count < 9 && (front.isEmpty || used + w <= rect.width * 0.96) {
                front.append((n, sp, h(n)))
                used += w
            } else {
                rest.append(n)
            }
        }

        // centre-out ordering: biggest in the middle
        var arranged: [(Node, Species, CGFloat)] = []
        for (i, t) in front.enumerated() {
            if i.isMultiple(of: 2) { arranged.insert(t, at: 0) } else { arranged.append(t) }
        }
        let widths = arranged.map { max($0.2 * $0.1.aspect * 0.92, 116) }
        let total = widths.reduce(0, +)
        let squeeze = min(1, rect.width * 0.96 / max(total, 1))
        var x = rect.midX - total * squeeze / 2
        var out: [Slot] = []
        for (i, t) in arranged.enumerated() {
            let w = widths[i] * squeeze
            let cx = x + w / 2
            var rng = Seeded(t.0.path)
            out.append(Slot(node: t.0, species: t.1, x: cx, baseY: frontBase + CGFloat(rng.range(-6, 6)), height: t.2 * min(1, squeeze + 0.15),
                            row: 1, dir: cx < rect.midX ? 1 : -1, order: out.count))
            x += w
        }

        if !rest.isEmpty {
            // Back-row trees go in the gaps between front trees (and beyond the ends) so they stay visible.
            let fronts = out.map(\.x).sorted()
            var gaps: [CGFloat] = []
            if let first = fronts.first, let last = fronts.last {
                gaps.append((rect.minX + first) / 2)
                for (a, b) in zip(fronts, fronts.dropFirst()) { gaps.append((a + b) / 2) }
                gaps.append((last + rect.maxX) / 2)
            }
            // Biggest back trees take the outer gaps, where nothing blocks them.
            gaps.sort { abs($0 - rect.midX) > abs($1 - rect.midX) }
            var rng = Seeded("back\(rest.count)")
            let extraSpacing = rect.width / CGFloat(max(1, rest.count - gaps.count))
            for (i, n) in rest.enumerated() {
                let cx: CGFloat
                if i < gaps.count {
                    cx = gaps[i] + CGFloat(rng.range(-12, 12))
                } else {
                    let j = i - gaps.count
                    cx = rect.minX + extraSpacing * (CGFloat(j) + 0.5) + CGFloat(rng.range(-0.2, 0.2)) * extraSpacing
                }
                out.append(Slot(node: n, species: Species.of(n, deadwood: deadwood(n)), x: cx,
                                baseY: backBase + CGFloat(rng.range(-10, 10)), height: h(n) * 0.8,
                                row: 0, dir: cx < rect.midX ? 1 : -1, order: out.count))
            }
        }
        return out.sorted { ($0.row, $0.baseY) < ($1.row, $1.baseY) }
    }
}

extension Seeded {
    var hashValueish: Double { var s = self; return s.next() }
}

// MARK: - The stage that holds one grove

struct ForestStage: View {
    let grove: Node
    let rect: CGRect
    @Environment(ForestModel.self) private var model

    var body: some View {
        let _ = model.revision
        let slots = ForestLayout.slots(for: grove.children, in: rect) { model.findingsByNode[$0.id] != nil }
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(slots) { s in
                TreeView(node: s.node, species: s.species, height: s.height, haze: s.row == 0 ? 0.6 : 0,
                         alwaysLabel: s.row == 1, dir: s.dir, sproutDelay: Double(s.order) * 0.035)
                    .position(x: s.x, y: s.baseY - s.height / 2)
            }
            undergrowth(slots: slots)
        }
        .animation(.spring(duration: 0.6, bounce: 0.15), value: model.revision)
    }

    @ViewBuilder private func undergrowth(slots: [Slot]) -> some View {
        let shown = Set(slots.map(\.node.id))
        let rest = grove.children.filter { !shown.contains($0.id) }
        let bytes = rest.reduce(Int64(0)) { $0 + $1.size } + grove.hiddenSize
        let count = rest.count + grove.hiddenCount
        if count > 0 && bytes > 0 {
            UndergrowthBush(count: count, bytes: bytes)
                .position(x: rect.maxX - 90, y: rect.maxY - max(64, rect.height * 0.12) - max(70, rect.height * 0.16) - 10)
        }
    }
}

struct UndergrowthBush: View {
    let count: Int
    let bytes: Int64
    @State private var hover = false
    var body: some View {
        VStack(spacing: 4) {
            TreeBody(species: .bush, seed: "undergrowth")
                .frame(width: 70, height: 32)
            Text("+\(Fmt.count(count)) smaller · \(Fmt.bytes(bytes))")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.regularMaterial, in: Capsule())
                .opacity(hover ? 1 : 0.75)
        }
        .onHover { hover = $0 }
        .help("Files and folders too small to grow into trees here.")
    }
}

// MARK: - Forest screen

struct ForestScreen: View {
    @Environment(ForestModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        GeometryReader { geo in
            let leftInset: CGFloat = model.showDeadwood ? 328 : 24
            let rightInset: CGFloat = 332
            let rect = CGRect(x: leftInset, y: 70, width: max(200, geo.size.width - leftInset - rightInset), height: geo.size.height - 70)
            ZStack(alignment: .topLeading) {
                SceneBackdrop()
                    .onTapGesture { model.select(nil) }

                if let grove = model.current {
                    ForestStage(grove: grove, rect: rect)
                        .id(grove.id)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.85, anchor: .bottom).combined(with: .opacity),
                            removal: .scale(scale: 1.25, anchor: .bottom).combined(with: .opacity)))
                }
            }
            .shake(model.shakeTrigger)
            .overlay(alignment: .top) { TopBar() }
            .overlay(alignment: .topLeading) {
                if model.showDeadwood {
                    DeadwoodPanel()
                        .frame(width: 300)
                        .padding(.leading, 16).padding(.top, 64).padding(.bottom, 16)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .overlay(alignment: .topTrailing) {
                Inspector()
                    .frame(width: 304)
                    .padding(.trailing, 16).padding(.top, 64).padding(.bottom, 16)
            }
            .overlay(alignment: .bottom) { ToastView().padding(.bottom, 26) }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { model.moveSelection(-1, in: visibleOrder); return .handled }
        .onKeyPress(.rightArrow) { model.moveSelection(1, in: visibleOrder); return .handled }
        .onKeyPress(.return) { if let s = model.selected { model.enter(s) }; return .handled }
        .onKeyPress(.escape) { if model.selected != nil { model.select(nil) } else { model.back() }; return .handled }
        .onKeyPress(.delete) { if let s = model.selected { model.requestChop(s) }; return .handled }
        .onKeyPress(.space) {
            if let s = model.selected { model.quickLookURL = model.quickLookURL == nil ? s.url : nil }
            return .handled
        }
        .quickLookPreview($model.quickLookURL)
        .alert(item: Binding(get: { model.confirming.map(ConfirmBox.init) }, set: { if $0 == nil { model.confirming = nil } })) { box in
            let git = model.confirmingGit
            var msg = "\(Fmt.bytes(box.node.size))\(box.node.isDirectory ? " · \(Fmt.count(box.node.fileCount)) files" : "") will go to the Trash. ⌘Z plants it back."
            if let git {
                msg = (git.warning.map { "⚠️ \($0) It only exists in this folder.\n\n" } ?? "") + git.summary + ".\n\n" + msg
                if git.isWorktree { msg += " Git will forget the worktree so its branch frees up." }
                if git.conductor { msg += " Archive it in Conductor too." }
            }
            return Alert(
                title: Text(git?.atRisk == true ? "Chop \(box.node.displayName) and its unsaved work?" : "Chop \(box.node.displayName)?"),
                message: Text(msg),
                primaryButton: .destructive(Text(git?.atRisk == true ? "Chop anyway" : "Chop it")) { Task { await model.chop(box.node) } },
                secondaryButton: .cancel()
            )
        }
    }

    /// Trees in on-screen left-to-right order for arrow keys.
    private var visibleOrder: [Node] {
        guard let c = model.current else { return [] }
        return Array(c.children.prefix(ForestLayout.maxTrees))
    }
}

struct ConfirmBox: Identifiable {
    let node: Node
    var id: ObjectIdentifier { node.id }
}

extension View {
    func shake(_ trigger: Int) -> some View {
        keyframeAnimator(initialValue: CGSize.zero, trigger: trigger) { content, off in
            content.offset(off)
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(CGSize(width: 0, height: 5), duration: 0.04)
                LinearKeyframe(CGSize(width: -3, height: -3), duration: 0.05)
                LinearKeyframe(CGSize(width: 2, height: 2), duration: 0.05)
                LinearKeyframe(CGSize(width: -1, height: -1), duration: 0.05)
                SpringKeyframe(.zero, duration: 0.2)
            }
        }
    }
}

// MARK: - Welcome

struct WelcomeScreen: View {
    @Environment(ForestModel.self) private var model
    @State private var appear = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                SceneBackdrop(groundLine: 0.7)
                DecorativeForest(size: geo.size)
                VStack(spacing: 22) {
                    VStack(spacing: 6) {
                        HStack(alignment: .center, spacing: 14) {
                            AxeIcon().frame(width: 40, height: 64)
                            Text("Timber")
                                .font(.system(size: 76, weight: .black, design: .serif))
                                .foregroundStyle(.white)
                        }
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                        Text("Your disk is a forest. Chop what you don't need.")
                            .font(.system(size: 18, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))
                            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    }
                    .offset(y: appear ? 0 : -12)
                    .opacity(appear ? 1 : 0)

                    VolumeCard(volume: model.volume)
                        .frame(width: 440)
                        .offset(y: appear ? 0 : 12)
                        .opacity(appear ? 1 : 0)

                    VStack(spacing: 10) {
                        Button { model.startScan(URL(fileURLWithPath: NSHomeDirectory())) } label: {
                            Label("Survey my Home folder", systemImage: "house.fill")
                                .frame(width: 280)
                        }
                        .buttonStyle(BlazeButtonStyle(big: true))
                        .keyboardShortcut(.defaultAction)

                        HStack(spacing: 10) {
                            Button { model.chooseFolder() } label: { Label("Choose a folder…", systemImage: "folder") }
                            Button { model.startScan(URL(fileURLWithPath: "/System/Volumes/Data")) } label: {
                                Label("Whole disk", systemImage: "internaldrive")
                            }
                            .help("Surveys everything on the startup disk. Grant Full Disk Access for the full picture.")
                        }
                        .buttonStyle(GlassButtonStyle())

                        if model.root != nil {
                            Button { model.replaySurvey() } label: {
                                Label("Replay the last survey", systemImage: "play.circle.fill")
                            }
                            .buttonStyle(GlassButtonStyle(small: true))
                            .help("Re-runs the 3D survey from your last scan, without rescanning")
                        }
                    }
                    .opacity(appear ? 1 : 0)

                    VStack(spacing: 5) {
                        Label("Nothing is deleted. Chopped trees go to the Trash, and ⌘Z plants them back.", systemImage: "leaf.fill")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                        Text("Your files stay on your Mac. Anonymous usage counts only, never file names. Change it in Settings.")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .opacity(0.75)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.3), radius: 4)
                    .padding(.top, 4)
                }
                .padding(.bottom, geo.size.height * 0.16)
            }
        }
        .onAppear {
            model.volume = VolumeInfo.of()
            withAnimation(.spring(duration: 0.9).delay(0.1)) { appear = true }
        }
    }
}

struct DecorativeForest: View {
    let size: CGSize
    var body: some View {
        let species: [Species] = [.pine, .pine, .oak, .birch, .pine, .maple, .pine, .blossom, .pine, .oak, .dead, .pine, .pine, .oak, .pine]
        ZStack {
            ForEach(Array(species.enumerated()), id: \.offset) { i, sp in
                var rng = Seeded("deco\(i)")
                let edge = abs(Double(i) / Double(species.count - 1) - 0.5) * 2 // 0 centre, 1 edge
                let h = CGFloat(rng.range(0.16, 0.26) + edge * 0.2) * size.height
                let x = CGFloat(Double(i) / Double(species.count - 1)) * size.width * 1.04 - size.width * 0.02
                let base = size.height * CGFloat(0.84 + rng.range(-0.04, 0.06))
                DecoTree(species: sp, seed: "deco\(i)", height: h, delay: Double(i) * 0.05)
                    .position(x: x, y: base - h / 2)
                    .opacity(edge < 0.35 ? 0.0 : 1)
            }
        }
        .allowsHitTesting(false)
    }
}

struct DecoTree: View {
    let species: Species
    let seed: String
    let height: CGFloat
    let delay: Double
    @State private var grown = false
    @State private var sway = false
    var body: some View {
        TreeBody(species: species, seed: seed)
            .frame(width: height * species.aspect, height: height)
            .rotationEffect(.degrees(sway ? 1.2 : -1.2), anchor: .bottom)
            .scaleEffect(x: 1, y: grown ? 1 : 0.01, anchor: .bottom)
            .onAppear {
                withAnimation(.spring(duration: 0.8, bounce: 0.4).delay(0.2 + delay)) { grown = true }
                withAnimation(.easeInOut(duration: Double.random(in: 2.8...4)).repeatForever()) { sway = true }
            }
    }
}

struct VolumeCard: View {
    let volume: VolumeInfo
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(volume.name, systemImage: "internaldrive.fill")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                Text("\(Int((volume.usedFraction * 100).rounded()))% full")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(volume.usedFraction > 0.9 ? Color.blaze : .secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Fmt.bytes(volume.available))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text("free of \(Fmt.bytes(volume.total))")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            DiskBar(fraction: volume.usedFraction).frame(height: 10)
            if volume.usedFraction > 0.85 {
                Text("The forest's overgrown. Let's clear a path.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.25), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 20, y: 10)
    }
}

struct DiskBar: View {
    var fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                Capsule()
                    .fill(LinearGradient(colors: [Color(hex: 0x5DBB63), fraction > 0.85 ? Color.blaze : Color(hex: 0x9BCB5A)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, g.size.width * fraction))
            }
        }
    }
}

// MARK: - Scanning

struct ScanningScreen: View {
    @Environment(ForestModel.self) private var model

    var body: some View {
        ZStack(alignment: .top) {
            SurveyView(sprouts: model.sprouts, files: model.scanSnapshot.files, finishing: model.scanFinishing)
                .id(model.surveyID)
                .ignoresSafeArea()
            ScanCard()
                .padding(.top, 46)
                .opacity(model.scanFinishing ? 0 : 1)
                .offset(y: model.scanFinishing ? -20 : 0)
                .animation(.smooth(duration: 0.5), value: model.scanFinishing)
        }
    }
}

struct ScanCard: View {
    @Environment(ForestModel.self) private var model
    @State private var lastFiles = 0
    @State private var lastAt = Date()
    @State private var rate = 0.0

    var body: some View {
        let s = model.scanSnapshot
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Color.blaze).frame(width: 8, height: 8)
                    .shadow(color: .blaze, radius: 4)
                    .phaseAnimator([0.35, 1.0]) { c, v in c.opacity(v) } animation: { _ in .easeInOut(duration: 0.6) }
                Text("SURVEYING")
                    .font(.system(size: 11, weight: .heavy, design: .rounded)).kerning(2)
                    .foregroundStyle(.white.opacity(0.85))
                Text(model.root?.displayName ?? (model.sprouts.first?.parent?.displayName ?? ""))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
            HStack(spacing: 28) {
                stat(Fmt.count(s.files), "files")
                stat(Fmt.bytes(s.bytes), "measured")
                stat(rate > 0 ? "\(Fmt.count(Int(rate)))/s" : "—", "speed")
                stat("\(model.sprouts.count)", "trees")
            }
            Text(Fmt.tilde(s.current))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(width: 460)
            Button("Stop") { model.cancelScan() }
                .buttonStyle(GlassButtonStyle(small: true))
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.blaze.opacity(0.35), lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        .onChange(of: s.files) { _, files in
            let now = Date()
            let dt = now.timeIntervalSince(lastAt)
            guard dt > 0.4 else { return }
            let r = Double(files - lastFiles) / dt
            rate = rate == 0 ? r : rate * 0.6 + r * 0.4
            lastFiles = files
            lastAt = now
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .heavy, design: .rounded)).kerning(1)
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(minWidth: 92)
    }
}

// MARK: - Buttons

struct BlazeButtonStyle: ButtonStyle {
    var big = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: big ? 16 : 14, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, big ? 26 : 16)
            .padding(.vertical, big ? 13 : 10)
            .background {
                Capsule().fill(LinearGradient(colors: [Color(hex: 0xFF8A3D), Color(hex: 0xE8551A)], startPoint: .top, endPoint: .bottom))
                    .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 1).blendMode(.overlay))
                    .shadow(color: Color.blaze.opacity(configuration.isPressed ? 0.2 : 0.45), radius: configuration.isPressed ? 4 : 12, y: configuration.isPressed ? 1 : 5)
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(enabled ? 1 : 0.45)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

struct GlassButtonStyle: ButtonStyle {
    var small = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: small ? 12 : 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, small ? 12 : 16)
            .padding(.vertical, small ? 6 : 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}
