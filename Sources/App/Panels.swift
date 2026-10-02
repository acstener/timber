import SwiftUI

struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.2), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 18, y: 8)
    }
}

// MARK: - Top bar

struct TopBar: View {
    @Environment(ForestModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 64, height: 1)
            Button { model.back() } label: {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .background(.regularMaterial, in: Circle())
            .disabled(model.trail.count <= 1)
            .opacity(model.trail.count <= 1 ? 0.4 : 1)
            .help("Back up the trail (Esc)")

            Trail()
            Spacer(minLength: 12)

            Menu {
                Button("Replay the survey", systemImage: "play.fill") { model.replaySurvey() }
                Button("Back to the welcome screen", systemImage: "house") { model.backToWelcome() }
                Divider()
                Button("Survey again for real", systemImage: "arrow.clockwise") { model.rescan() }
            } label: {
                Label("Replay", systemImage: "play.circle.fill")
            } primaryAction: {
                model.replaySurvey()
            }
            .menuStyle(.button)
            .buttonStyle(GlassButtonStyle(small: true))
            .fixedSize()
            .help("Replay the 3D survey animation (⌘⇧P). Click the arrow for more.")

            Button { withAnimation(.spring(duration: 0.4)) { model.showDeadwood.toggle() } } label: {
                Label("Deadwood", systemImage: "leaf.arrow.triangle.circlepath")
            }
            .buttonStyle(GlassButtonStyle(small: true))
            .help("Show or hide the deadwood list (⌘1)")

            Button { model.surveyGrove() } label: {
                HStack(spacing: 6) {
                    if model.surveying { ProgressView().controlSize(.mini) } else { Image(systemName: "binoculars.fill") }
                    Text("Ask the Ranger")
                }
            }
            .buttonStyle(GlassButtonStyle(small: true))
            .help("Jev marks every tree in this grove: chop, look first, or keep (⌘R)")

            VolumeGauge()
            LogPile()
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .frame(height: 52)
    }
}

struct Trail: View {
    @Environment(ForestModel.self) private var model
    var body: some View {
        let trail = model.trail
        let shown: [Node?] = trail.count > 5 ? [trail[0], nil] + trail.suffix(3) : trail
        HStack(spacing: 4) {
            ForEach(Array(shown.enumerated()), id: \.offset) { i, n in
                if i > 0 { Image(systemName: "chevron.compact.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }
                if let n {
                    let isLast = n === trail.last
                    Button { model.jump(to: n) } label: {
                        HStack(spacing: 5) {
                            if i == 0 { Image(systemName: "tree.fill").font(.system(size: 11)) }
                            Text(n.displayName).lineLimit(1)
                        }
                        .font(.system(size: 12.5, weight: isLast ? .bold : .medium, design: .rounded))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(isLast ? AnyShapeStyle(.thickMaterial) : AnyShapeStyle(.clear), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isLast)
                } else {
                    Text("…").foregroundStyle(.secondary)
                }
            }
        }
        .padding(3)
        .background(.regularMaterial, in: Capsule())
        .animation(.spring(duration: 0.35), value: trail.count)
    }
}

struct VolumeGauge: View {
    @Environment(ForestModel.self) private var model
    var body: some View {
        let v = model.volume
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(Fmt.bytes(v.available)).font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit()
                Text("free").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            }
            DiskBar(fraction: v.usedFraction).frame(width: 110, height: 5)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .help("\(v.name): \(Fmt.bytes(v.used)) used of \(Fmt.bytes(v.total))")
    }
}

struct LogPile: View {
    @Environment(ForestModel.self) private var model
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                LogPileIcon(count: min(6, 1 + model.choppedCount))
                    .frame(width: 26, height: 20)
                    .keyframeAnimator(initialValue: 1.0, trigger: model.lastHaul?.id) { c, s in c.scaleEffect(s) } keyframes: { _ in
                        KeyframeTrack { SpringKeyframe(1.35, duration: 0.15); SpringKeyframe(1, duration: 0.4) }
                    }
                VStack(alignment: .leading, spacing: 0) {
                    Text("CHOPPED").font(.system(size: 8.5, weight: .heavy, design: .rounded)).foregroundStyle(.secondary).kerning(0.6)
                    Text(Fmt.bytes(model.reclaimed))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: model.reclaimed)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(model.reclaimed > 0 ? Color.blaze.opacity(0.6) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) { LogPilePopover() }
    }
}

struct LogPilePopover: View {
    @Environment(ForestModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                LogPileIcon(count: 6).frame(width: 40, height: 30)
                VStack(alignment: .leading) {
                    Text("\(model.choppedCount) tree\(model.choppedCount == 1 ? "" : "s") chopped").font(.headline)
                    Text("\(Fmt.bytes(model.reclaimed)) waiting in the Trash").foregroundStyle(.secondary)
                }
            }
            Text("Space comes back when the Trash is emptied. Until then, anything chopped can be planted back.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Undo last chop") { model.undo() }.disabled(model.undoStack.isEmpty)
                Button("Open Trash") { model.openTrash() }
                Spacer()
                Button("Haul it away…") { confirmEmpty() }
                    .buttonStyle(.borderedProminent).tint(Color.blaze)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func confirmEmpty() {
        let a = NSAlert()
        a.messageText = "Empty the Trash?"
        a.informativeText = "This permanently deletes everything in the Trash — not just what Timber chopped. It can't be undone."
        a.addButton(withTitle: "Empty Trash")
        a.addButton(withTitle: "Cancel")
        a.alertStyle = .warning
        if a.runModal() == .alertFirstButtonReturn { model.emptyTrash() }
    }
}

struct LogPileIcon: View {
    var count: Int
    var body: some View {
        Canvas { ctx, size in
            let r = size.height / 4.2
            let positions: [CGPoint] = [
                CGPoint(x: r, y: size.height - r), CGPoint(x: r * 3, y: size.height - r), CGPoint(x: r * 5, y: size.height - r),
                CGPoint(x: r * 2, y: size.height - r * 2.7), CGPoint(x: r * 4, y: size.height - r * 2.7), CGPoint(x: r * 3, y: size.height - r * 4.3),
            ]
            for p in positions.prefix(max(1, count)) {
                let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(Color.bark))
                ctx.fill(Path(ellipseIn: rect.insetBy(dx: r * 0.22, dy: r * 0.22)), with: .color(Color.sawdust))
                ctx.stroke(Path(ellipseIn: rect.insetBy(dx: r * 0.55, dy: r * 0.55)), with: .color(Color(hex: 0xB98D58)), lineWidth: 0.8)
            }
        }
    }
}

// MARK: - Inspector

struct Inspector: View {
    @Environment(ForestModel.self) private var model

    var body: some View {
        let _ = model.revision
        Panel {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let n = model.selected {
                        TreeDetail(node: n).id(n.id)
                            .transition(.opacity.combined(with: .offset(x: 10)))
                    } else if let g = model.current {
                        GroveSummary(grove: g)
                            .transition(.opacity)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        .animation(.spring(duration: 0.35), value: model.selected?.id)
    }
}

struct TreeDetail: View {
    let node: Node
    @Environment(ForestModel.self) private var model

    var body: some View {
        let finding = model.findingsByNode[node.id]
        let verdict = model.verdicts[node.path]
        let parentSize = node.parent?.size ?? node.size
        let fraction = parentSize > 0 ? Double(node.size) / Double(parentSize) : 0
        let blocked = Chopper.protectedReason(node.path) ?? ((finding?.choppable == false) ? finding?.reason : nil)

        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                TreeBody(species: Species.of(node, deadwood: finding != nil), seed: node.path, mark: verdict?.policyMark)
                    .frame(width: 34, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(node.displayName)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .lineLimit(2)
                    Label(node.kind.label, systemImage: node.kind.symbol)
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(Fmt.bytes(node.size))
                    .font(.system(size: 36, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                VStack(alignment: .leading, spacing: 4) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.primary.opacity(0.08))
                            Capsule().fill(Color.blaze.gradient).frame(width: max(4, g.size.width * fraction))
                        }
                    }
                    .frame(height: 6)
                    Text("\(fraction < 0.01 ? "<1" : String(Int((fraction * 100).rounded())))% of \(node.parent?.displayName ?? "this grove")")
                        .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                if node.isDirectory { fact("Files", Fmt.count(node.fileCount), "doc.on.doc") }
                fact("Last touched", Fmt.relative(node.newestDate), "clock")
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").frame(width: 16).foregroundStyle(.secondary)
                    Text(Fmt.tilde(node.path))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
                .font(.system(size: 12))
            }

            if let finding { DeadwoodCard(finding: finding) }
            if let git = model.gitChecks[node.path] { GitCard(check: git) }
            else if model.gitLoading.contains(node.path) {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking git…").font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary) }
            }
            RangerCard(node: node, verdict: verdict)

            VStack(spacing: 8) {
                if let blocked {
                    Label(blocked, systemImage: "lock.fill")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                }
                Button { model.requestChop(node) } label: {
                    HStack(spacing: 8) {
                        AxeIcon().frame(width: 14, height: 20)
                        Text("Chop")
                        Spacer()
                        Text("⌫").font(.system(size: 12, weight: .semibold)).opacity(0.7)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(BlazeButtonStyle())
                .disabled(blocked != nil || model.chopPhases[node.id] != nil)

                HStack(spacing: 8) {
                    if node.isDirectory && !node.children.isEmpty {
                        smallAction("Walk in", "figure.walk") { model.enter(node) }
                    }
                    smallAction("Peek", "eye") { model.quickLookURL = node.url }
                    smallAction("Finder", "folder") { model.revealInFinder(node) }
                }
            }
        }
    }

    private func fact(_ label: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 16).foregroundStyle(.secondary)
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.semibold)
        }
        .font(.system(size: 12, design: .rounded))
    }

    private func smallAction(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                Text(title).font(.system(size: 10.5, weight: .semibold, design: .rounded))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct SafetyPill: View {
    let safety: Safety
    var body: some View {
        Text(safety.label)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
    var color: Color {
        switch safety {
        case .safe: return Color(hex: 0x3FA45B)
        case .likely: return Color(hex: 0xC7921E)
        case .review: return Color.keepBlue
        }
    }
}

struct DeadwoodCard: View {
    let finding: Finding
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Deadwood", systemImage: "leaf.arrow.triangle.circlepath")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                SafetyPill(safety: finding.safety)
            }
            Text(finding.title).font(.system(size: 13, weight: .semibold, design: .rounded))
            Text(finding.reason).font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct GitCard: View {
    let check: GitCheck
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(check.isWorktree ? "Git worktree" : "Git repository", systemImage: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(check.atRisk ? "Unsaved work" : "All saved")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .foregroundStyle(check.atRisk ? Color.blaze : Color(hex: 0x3FA45B))
                    .background((check.atRisk ? Color.blaze : Color(hex: 0x3FA45B)).opacity(0.15), in: Capsule())
            }
            if let b = check.branch {
                Label(b, systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced)).lineLimit(1)
            }
            row("pencil", check.uncommitted == 0 ? "No uncommitted changes" : "\(check.uncommitted) uncommitted change\(check.uncommitted == 1 ? "" : "s")", check.uncommitted > 0)
            row("arrow.up.circle", check.onlyHere == 0 ? "Every commit exists elsewhere" : "\(check.onlyHere) commit\(check.onlyHere == 1 ? "" : "s") only here", check.onlyHere > 0)
            if let main = check.mainRepo {
                row("folder", "Main repo: \(Fmt.tilde(main))", false)
            }
            if check.isWorktree {
                Text("Chopping tells git to forget this worktree so its branch frees up. ⌘Z restores both.")
                    .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if check.conductor {
                Label("Conductor workspace: archive it in Conductor too.", systemImage: "info.circle")
                    .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func row(_ icon: String, _ text: String, _ warn: Bool) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(warn ? Color.blaze : .secondary)
            .lineLimit(1).truncationMode(.middle)
    }
}

struct RangerCard: View {
    let node: Node
    let verdict: RangerVerdict?
    @Environment(ForestModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Ranger", systemImage: "binoculars.fill")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Jev").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.tertiary)
            }
            if let v = verdict {
                HStack(spacing: 8) {
                    markSwatch(v.policyMark)
                    Text(v.headline).font(.system(size: 14, weight: .bold, design: .rounded))
                }
                Text(v.categoryLabel).font(.system(size: 11.5, design: .rounded)).foregroundStyle(.secondary)
                VStack(spacing: 6) {
                    meter("Grows back on its own", v.regenerates, Color(hex: 0x3FA45B))
                    meter("Holds personal stuff", v.irreplaceable, Color.keepBlue)
                    meter("Would break something", v.breaksSomething, Color.blaze)
                }
                .padding(.top, 2)
            } else if model.rangerPending.contains(node.path) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("The ranger's taking a look…").font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
                }
            } else {
                Text(model.hasJevKey ? "Get a second opinion before you swing." : "Add a TypeSafe key in Settings and Jev will mark trees for you.")
                    .font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.hasJevKey {
                    Button { model.askRanger([node]) } label: { Label("Ask the Ranger", systemImage: "binoculars") }
                        .buttonStyle(GlassButtonStyle(small: true))
                } else {
                    SettingsLink { Label("Open Settings", systemImage: "gearshape") }
                        .buttonStyle(GlassButtonStyle(small: true))
                }
            }
        }
        .padding(12)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func markSwatch(_ m: RangerVerdict.Mark) -> some View {
        let c: Color = m == .chop ? .blaze : (m == .keep ? .keepBlue : .reviewGold)
        return Capsule().fill(c).frame(width: 18, height: 7).rotationEffect(.degrees(m == .chop ? -22 : 0))
    }

    private func meter(_ label: String, _ value: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 11, design: .rounded))
                Spacer()
                Text("\(Int((value * 100).rounded()))%").font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.08))
                    Capsule().fill(color).frame(width: max(3, g.size.width * value))
                }
            }
            .frame(height: 4)
        }
    }
}

struct GroveSummary: View {
    let grove: Node
    @Environment(ForestModel.self) private var model

    var body: some View {
        let trees = grove.children.prefix(ForestLayout.maxTrees)
        let marked = trees.filter { model.verdicts[$0.path] != nil }.count
        VStack(alignment: .leading, spacing: 14) {
            Text("THIS GROVE").font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundStyle(.secondary).kerning(0.8)
            Text(grove.displayName).font(.system(size: 20, weight: .bold, design: .rounded)).lineLimit(2)
            Text(Fmt.bytes(grove.size)).font(.system(size: 36, weight: .heavy, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
            VStack(alignment: .leading, spacing: 6) {
                row("tree.fill", "\(trees.count) trees standing")
                row("doc.on.doc", "\(Fmt.count(grove.fileCount)) files")
                if let biggest = grove.children.first { row("crown.fill", "Biggest: \(biggest.displayName)") }
                if marked > 0 { row("binoculars.fill", "\(marked) marked by the ranger") }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                hint("cursorarrow.click", "Click a tree to inspect it")
                hint("cursorarrow.click.2", "Double-click to walk into a folder")
                hint("delete.left", "⌫ chops the selected tree")
                hint("arrow.uturn.backward", "⌘Z plants it back")
            }
            LegendView()
            if grove.unreadable || model.unreadable > 0 {
                Button { model.openFullDiskAccess() } label: {
                    Label("Some folders were locked. Grant Full Disk Access to see everything.", systemImage: "lock.open")
                        .font(.system(size: 11.5, design: .rounded)).multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon).font(.system(size: 12.5, weight: .medium, design: .rounded)).lineLimit(1)
    }
    private func hint(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon).font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
    }
}

struct LegendView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FIELD GUIDE").font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundStyle(.secondary).kerning(0.8)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 8) {
                legend(.pine, "Folder")
                legend(.dead, "Deadwood")
                legend(.oak, "File")
                legend(.blossom, "Media")
                legend(.birch, "Installer / archive")
                legend(.maple, "App")
            }
            HStack(spacing: 12) {
                paint(.blaze, "Fell", -22)
                paint(.reviewGold, "Look first", 0)
                paint(.keepBlue, "Keep", 0)
            }
            .padding(.top, 2)
        }
    }
    private func legend(_ s: Species, _ t: String) -> some View {
        HStack(spacing: 6) {
            TreeBody(species: s, seed: t).frame(width: 14, height: 20)
            Text(t).font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
    private func paint(_ c: Color, _ t: String, _ angle: Double) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(c).frame(width: 14, height: 5).rotationEffect(.degrees(angle))
            Text(t).font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Deadwood

struct DeadwoodPanel: View {
    @Environment(ForestModel.self) private var model

    var body: some View {
        let findings = model.findings
        let picked = findings.filter { model.deadwoodPicks.contains($0.id) }
        let pickedBytes = picked.reduce(Int64(0)) { $0 + $1.node.size }
        let totalBytes = findings.filter(\.choppable).reduce(Int64(0)) { $0 + $1.node.size }

        Panel {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("Deadwood", systemImage: "leaf.arrow.triangle.circlepath")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                        Spacer()
                        Text(Fmt.bytes(totalBytes))
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    Text("Caches and leftovers that grow back on their own.")
                        .font(.system(size: 11.5, design: .rounded)).foregroundStyle(.secondary)
                }
                .padding(16)

                Divider().opacity(0.5)

                if findings.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "sparkles").font(.title2).foregroundStyle(.secondary)
                        Text("No deadwood left. Tidy forest!").font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                            ForEach(Safety.allCases, id: \.self) { s in
                                let group = findings.filter { $0.safety == s }
                                if !group.isEmpty {
                                    Section {
                                        ForEach(group) { f in DeadwoodRow(finding: f) }
                                    } header: {
                                        sectionHeader(s, group)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                    }
                    .scrollIndicators(.never)
                }

                Divider().opacity(0.5)
                Button { confirmClear(picked.count, pickedBytes) } label: {
                    HStack {
                        if model.clearingDeadwood { ProgressView().controlSize(.small).tint(.white) } else { AxeIcon().frame(width: 12, height: 18) }
                        Text(model.clearingDeadwood ? "Clearing…" : (picked.isEmpty ? "Pick deadwood to clear" : "Clear \(picked.count) · \(Fmt.bytes(pickedBytes))"))
                            .contentTransition(.numericText())
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(BlazeButtonStyle())
                .disabled(picked.isEmpty || model.clearingDeadwood)
                .padding(12)
            }
        }
    }

    private func confirmClear(_ count: Int, _ bytes: Int64) {
        let a = NSAlert()
        a.messageText = "Clear \(count) patch\(count == 1 ? "" : "es") of deadwood?"
        a.informativeText = "\(Fmt.bytes(bytes)) of caches and build leftovers will go to the Trash. Anything you miss can be planted back from the Trash."
        a.addButton(withTitle: "Clear Deadwood")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { Task { await model.clearDeadwood() } }
    }

    private func sectionHeader(_ s: Safety, _ group: [Finding]) -> some View {
        let ids = Set(group.filter(\.choppable).map(\.id))
        let allOn = !ids.isEmpty && ids.isSubset(of: model.deadwoodPicks)
        return HStack {
            SafetyPill(safety: s)
            Text(Fmt.bytes(group.reduce(0) { $0 + $1.node.size })).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            Spacer()
            if !ids.isEmpty {
                Button(allOn ? "None" : "All") {
                    if allOn { model.deadwoodPicks.subtract(ids) } else { model.deadwoodPicks.formUnion(ids) }
                    model.sound.play(.tick, volume: 0.4)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.blaze)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.regularMaterial)
    }
}

struct DeadwoodRow: View {
    let finding: Finding
    @Environment(ForestModel.self) private var model
    @State private var hover = false

    var body: some View {
        let picked = model.deadwoodPicks.contains(finding.id)
        let verdict = model.verdicts[finding.node.path]
        HStack(spacing: 9) {
            Button {
                if picked { model.deadwoodPicks.remove(finding.id) } else { model.deadwoodPicks.insert(finding.id) }
                model.sound.play(.tick, volume: 0.4)
            } label: {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(picked ? Color.blaze : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(!finding.choppable)
            .opacity(finding.choppable ? 1 : 0.3)

            Image(systemName: finding.symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(finding.title).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                    if let v = verdict {
                        Capsule().fill(v.policyMark == .chop ? Color.blaze : (v.policyMark == .keep ? Color.keepBlue : Color.reviewGold))
                            .frame(width: 10, height: 4)
                            .help("Ranger: \(v.headline)")
                    }
                }
                Text(Fmt.tilde(finding.node.path))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Text(Fmt.bytes(finding.node.size))
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(model.selected === finding.node ? Color.blaze.opacity(0.14) : (hover ? Color.primary.opacity(0.06) : .clear)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.reveal(finding.node) }
        .help(finding.reason)
        .contextMenu { TreeMenu(node: finding.node) }
        .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
    }
}

// MARK: - Toast

struct ToastView: View {
    @Environment(ForestModel.self) private var model
    var body: some View {
        if let t = model.toast {
            HStack(spacing: 10) {
                Image(systemName: icon(t.style)).foregroundStyle(color(t.style))
                Text(t.message).font(.system(size: 13, weight: .medium, design: .rounded))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .frame(maxWidth: 520)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(color(t.style).opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(t.id)
        }
    }
    private func icon(_ s: Toast.Style) -> String {
        switch s { case .info: return "leaf.fill"; case .success: return "checkmark.seal.fill"; case .warning: return "exclamationmark.triangle.fill" }
    }
    private func color(_ s: Toast.Style) -> Color {
        switch s { case .info: return Color(hex: 0x3FA45B); case .success: return Color.blaze; case .warning: return Color.reviewGold }
    }
}
