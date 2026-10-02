import SwiftUI
import AppKit

enum ChopPhase: Equatable {
    case swing(Int)
    case bounce
    case falling
    case fallen
}

struct Toast: Identifiable, Equatable {
    enum Style { case info, success, warning }
    let id = UUID()
    var style: Style
    var message: String
}

@MainActor
@Observable
final class ForestModel {
    static let shared = ForestModel()

    enum Phase { case welcome, scanning, forest }

    var phase: Phase = .welcome
    var root: Node?
    var trail: [Node] = []
    var selected: Node?
    var hovered: Node?
    /// Nodes aren't observable, so anything that mutates the tree bumps this.
    var revision = 0

    // Scanning
    var scanSnapshot = ScanProgress.Snapshot()
    var sprouts: [Node] = []
    var scanStarted = Date()
    var scanDuration: TimeInterval = 0
    /// True for the beat between the scan finishing and the forest appearing (the 3D swoop).
    var scanFinishing = false
    /// Replaying the survey animation from the tree we already have (no disk access).
    var replaying = false
    /// New id per survey so the 3D scene always starts fresh.
    var surveyID = UUID()
    private var progress: ScanProgress?
    private var scanTask: Task<Void, Never>?

    // Deadwood & ranger
    var findings: [Finding] = []
    var findingsByNode: [ObjectIdentifier: Finding] = [:]
    var deadwoodPicks: Set<ObjectIdentifier> = []
    var verdicts: [String: RangerVerdict] = [:]
    var rangerPending: Set<String> = []
    var rangerError: String?
    var surveying = false

    // Chopping
    var chopPhases: [ObjectIdentifier: ChopPhase] = [:]
    var confirming: Node?
    var confirmingGit: GitCheck?
    /// git status for selected repos/worktrees, keyed by path.
    var gitChecks: [String: GitCheck] = [:]
    var gitLoading: Set<String> = []
    var skipConfirmations = false
    var reclaimed: Int64 = 0
    var choppedCount = 0
    var undoStack: [(record: ChopRecord, node: Node, parent: Node)] = []
    var clearingDeadwood = false
    var shakeTrigger = 0
    var lastHaul: (bytes: Int64, id: UUID)?

    var volume = VolumeInfo.of()
    var toast: Toast?
    var showDeadwood = true
    var quickLookURL: URL?

    var jevModel: String { UserDefaults.standard.string(forKey: "jevModel") ?? JevClient.defaultModel }
    var autoRanger: Bool { UserDefaults.standard.bool(forKey: "autoRanger") }

    let sound = SoundBoard.shared

    var current: Node? { trail.last }
    var unreadable: Int { scanSnapshot.unreadable }
    var hasJevKey: Bool { JevClient.fromEnvironmentOrKeychain() != nil }

    // MARK: - Scanning

    func startScan(_ url: URL) {
        scanTask?.cancel()
        progress?.cancel()
        let p = ScanProgress()
        progress = p
        sprouts = []
        root = nil
        trail = []
        selected = nil
        findings = []
        findingsByNode = [:]
        deadwoodPicks = []
        scanSnapshot = .init()
        scanFinishing = false
        surveyID = UUID()
        scanStarted = Date()
        let home = NSHomeDirectory()
        Telemetry.track("survey_started", ["target": url.path == home ? "home" : (url.path == "/System/Volumes/Data" ? "whole_disk" : "folder")])
        withAnimation(.smooth(duration: 0.6)) { phase = .scanning }
        sound.play(.whoosh)

        scanTask = Task { [weak self] in
            let poll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(120))
                    await MainActor.run { self?.scanSnapshot = p.snapshot }
                }
            }
            let tree = await Scanner.scan(url, progress: p) { child in
                Task { @MainActor [weak self] in
                    guard let self, child.size > 0 else { return }
                    withAnimation(.spring(duration: 0.6, bounce: 0.35)) {
                        self.sprouts.append(child)
                        self.sprouts.sort { $0.size > $1.size }
                    }
                    if self.sprouts.count % 3 == 0 { self.sound.play(.sprout, volume: 0.25) }
                }
            }
            poll.cancel()
            guard let self, !p.isCancelled else { return }
            self.finishScan(tree, snapshot: p.snapshot)
        }
    }

    func cancelScan() {
        scanFinishing = false
        if replaying {
            replaying = false
            scanTask?.cancel()
            withAnimation(.smooth) { phase = .forest }
            return
        }
        progress?.cancel()
        scanTask?.cancel()
        withAnimation(.smooth) { phase = .welcome }
    }

    private func finishScan(_ tree: Node, snapshot: ScanProgress.Snapshot) {
        scanSnapshot = snapshot
        scanDuration = Date().timeIntervalSince(scanStarted)
        root = tree
        trail = [tree]
        findings = Deadwood.find(in: tree, minSize: 50_000_000)
        findingsByNode = Dictionary(findings.map { ($0.node.id, $0) }, uniquingKeysWith: { a, _ in a })
        deadwoodPicks = Set(findings.filter { $0.safety == .safe && $0.choppable }.map(\.id))
        volume = VolumeInfo.of(tree.url)
        revision += 1
        Telemetry.track("survey_completed", [
            "size": Telemetry.bucket(tree.size),
            "files_k": snapshot.files / 1000,
            "seconds": Int(scanDuration.rounded()),
            "deadwood_found": findings.count,
            "deadwood_size": Telemetry.bucket(findings.reduce(0) { $0 + $1.node.size }),
            "locked_folders": snapshot.unreadable > 0,
        ])
        // Tiny folders finish before the 3D survey has had a moment — stage the reveal.
        if scanDuration < 3.5 && sprouts.count > 0 {
            let kids = sprouts.sorted { $0.size < $1.size }
            sprouts = []
            scanTask = Task { [weak self] in
                guard let self else { return }
                let step = min(0.25, 3.2 / Double(max(1, kids.count)))
                for k in kids {
                    try? await Task.sleep(for: .seconds(step))
                    if Task.isCancelled || self.phase != .scanning { return }
                    withAnimation(.spring(duration: 0.6, bounce: 0.35)) {
                        self.sprouts.append(k)
                        self.sprouts.sort { $0.size > $1.size }
                    }
                }
                try? await Task.sleep(for: .milliseconds(700))
                if Task.isCancelled || self.phase != .scanning { return }
                self.landInForest()
            }
            return
        }
        landInForest()
    }

    /// The 3D camera swoops in, then the 2D forest takes over.
    private func landInForest() {
        scanFinishing = true
        sound.play(.whoosh)
        Task {
            try? await Task.sleep(for: .milliseconds(1350))
            guard phase == .scanning, scanFinishing else { return }
            scanFinishing = false
            replaying = false
            withAnimation(.smooth(duration: 0.8)) { phase = .forest }
            sound.play(.chime)
            if autoRanger && hasJevKey { surveyGrove() }
        }
    }

    /// Re-runs the 3D survey from the existing tree — instant, for demos. Small folders
    /// sprout first and the giants arrive last, like a real scan.
    func replaySurvey() {
        guard let tree = root else { return }
        scanTask?.cancel()
        progress?.cancel()
        let kids = tree.children.filter { $0.size > 0 }.sorted { $0.size < $1.size }
        sprouts = []
        scanSnapshot = .init()
        scanFinishing = false
        surveyID = UUID()
        replaying = true
        selected = nil
        Telemetry.track("replay_used")
        withAnimation(.smooth(duration: 0.6)) {
            trail = [tree]
            phase = .scanning
        }
        sound.play(.whoosh)
        scanTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(700))
            let n = kids.count
            let giants = min(8, n)
            var files = 0
            var bytes: Int64 = 0
            for (i, k) in kids.enumerated() {
                if Task.isCancelled || self.phase != .scanning { return }
                let delay = i < n - giants ? 4.2 / Double(max(1, n - giants)) : 0.5
                try? await Task.sleep(for: .seconds(delay))
                files += k.fileCount
                bytes += k.size
                self.scanSnapshot = ScanProgress.Snapshot(files: files, bytes: bytes, current: k.path, unreadable: 0)
                withAnimation(.spring(duration: 0.6, bounce: 0.35)) {
                    self.sprouts.append(k)
                    self.sprouts.sort { $0.size > $1.size }
                }
                if i % 3 == 0 || i >= n - giants { self.sound.play(.sprout, volume: 0.25) }
            }
            try? await Task.sleep(for: .milliseconds(600))
            if Task.isCancelled || self.phase != .scanning { return }
            self.landInForest()
        }
    }

    func backToWelcome() {
        scanTask?.cancel()
        replaying = false
        scanFinishing = false
        sound.play(.whoosh, volume: 0.6)
        withAnimation(.smooth(duration: 0.6)) { phase = .welcome }
    }

    func rescan() {
        guard let r = root else { return }
        startScan(r.url)
    }

    // MARK: - Navigation

    func select(_ node: Node?) {
        guard selected !== node else { return }
        selected = node
        if let node {
            sound.play(.tick, volume: 0.5)
            loadGit(node)
        }
    }

    func loadGit(_ node: Node) {
        let path = node.path
        guard node.isDirectory, gitChecks[path] == nil, !gitLoading.contains(path), Git.isCheckout(path) else { return }
        gitLoading.insert(path)
        Task {
            let check = await Task.detached { Git.check(path) }.value
            gitLoading.remove(path)
            if let check { withAnimation(.smooth) { gitChecks[path] = check } }
        }
    }

    func enter(_ node: Node) {
        guard node.isDirectory, !node.children.isEmpty, chopPhases[node.id] == nil else {
            if node.isDirectory { flash(.info, "Nothing big inside \(node.displayName) — it's all undergrowth.") }
            return
        }
        sound.play(.whoosh)
        withAnimation(.smooth(duration: 0.55)) {
            trail.append(node)
            selected = nil
        }
    }

    func back() {
        guard trail.count > 1 else { return }
        sound.play(.whoosh, volume: 0.6)
        withAnimation(.smooth(duration: 0.5)) {
            let left = trail.removeLast()
            selected = left
        }
    }

    func jump(to node: Node) {
        guard let i = trail.firstIndex(of: node), i < trail.count - 1 else { return }
        sound.play(.whoosh, volume: 0.6)
        withAnimation(.smooth(duration: 0.5)) {
            selected = trail[i + 1]
            trail.removeSubrange((i + 1)...)
        }
    }

    /// Walks the trail to a node's parent and selects it.
    func reveal(_ node: Node) {
        guard let root, let parent = node.parent else { return }
        var chain = parent.ancestors + [parent]
        if chain.first !== root { chain = [root] }
        withAnimation(.smooth(duration: 0.5)) {
            trail = chain
            selected = node
        }
        sound.play(.whoosh, volume: 0.6)
    }

    func moveSelection(_ delta: Int, in trees: [Node]) {
        guard !trees.isEmpty else { return }
        let ordered = trees.sorted { $0.path < $1.path }
        _ = ordered
        guard let s = selected, let i = trees.firstIndex(of: s) else { select(trees.first); return }
        let j = (i + delta + trees.count) % trees.count
        select(trees[j])
    }

    // MARK: - Chopping

    func needsConfirmation(_ node: Node) -> Bool {
        if node.isDirectory && Git.isCheckout(node.path) { return true }
        if skipConfirmations { return false }
        if let f = findingsByNode[node.id], f.safety != .review { return false }
        if verdicts[node.path]?.policyMark == .chop { return false }
        return node.size >= 200_000_000 || node.isDirectory
    }

    func requestChop(_ node: Node) {
        if let why = Chopper.protectedReason(node.path) {
            sound.play(.nope)
            flash(.warning, why)
            return
        }
        if let f = findingsByNode[node.id], !f.choppable {
            sound.play(.nope)
            flash(.warning, f.reason)
            return
        }
        if needsConfirmation(node) {
            confirmingGit = node.isDirectory ? (gitChecks[node.path] ?? Git.check(node.path)) : nil
            if let g = confirmingGit { gitChecks[node.path] = g }
            confirming = node
            return
        }
        Task { await chop(node) }
    }

    private func isVisible(_ node: Node) -> Bool {
        guard let c = current else { return false }
        return node.parent === c && c.children.prefix(ForestLayout.maxTrees).contains(node)
    }

    /// The full axe → fall → haul sequence. Returns false if the Trash move failed.
    @discardableResult
    func chop(_ node: Node, fast: Bool = false) async -> Bool {
        let id = node.id
        guard chopPhases[id] == nil, let parent = node.parent else { return false }
        let visible = isVisible(node)
        let swings = fast ? 2 : 3

        // The Trash move runs while the axe swings, so the tree falls the moment it's done.
        let path = node.path, bytes = node.size
        let work = Task.detached { () -> Result<ChopRecord, Error> in
            do { return .success(try Chopper.chop(path, bytes: bytes, via: "app")) }
            catch { return .failure(error) }
        }

        if visible {
            for i in 1...swings {
                chopPhases[id] = .swing(i)
                try? await Task.sleep(for: .milliseconds(110))
                sound.play(.thunk, pitch: Float.random(in: -1.5...1.5) + Float(i) * 0.6)
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                try? await Task.sleep(for: .milliseconds(fast ? 170 : 260))
            }
        } else {
            sound.play(.thunk)
        }

        let result = await work.value

        switch result {
        case .failure(let error):
            Telemetry.track("chop_failed", ["reason": error is ChopError ? "refused" : "error"])
            if visible {
                chopPhases[id] = .bounce
                sound.play(.nope)
                try? await Task.sleep(for: .milliseconds(450))
            }
            chopPhases[id] = nil
            flash(.warning, error.localizedDescription)
            return false
        case .success(let record):
            if visible {
                chopPhases[id] = .falling
                sound.play(.creak)
                try? await Task.sleep(for: .milliseconds(fast ? 650 : 900))
                sound.play(.crash)
                shakeTrigger += 1
                chopPhases[id] = .fallen
                try? await Task.sleep(for: .milliseconds(fast ? 500 : 750))
            }
            let wasSelected = selected === node
            var neighbour: Node?
            if wasSelected, let i = parent.children.firstIndex(of: node) {
                let sibs = parent.children
                neighbour = i + 1 < sibs.count ? sibs[i + 1] : (i > 0 ? sibs[i - 1] : nil)
            }
            withAnimation(.spring(duration: 0.6, bounce: 0.2)) {
                node.detach()
                undoStack.append((record, node, parent))
                reclaimed += bytes
                choppedCount += 1
                findings.removeAll { $0.node === node || $0.node.path.hasPrefix(node.path + "/") }
                findingsByNode[id] = nil
                deadwoodPicks.remove(id)
                chopPhases[id] = nil
                if wasSelected { selected = neighbour }
                lastHaul = (bytes, UUID())
                revision += 1
            }
            if bytes > 1_000_000_000 { sound.play(.chime, volume: 0.6) }
            Telemetry.track("tree_chopped", [
                "kind": node.kind.rawValue,
                "size": Telemetry.bucket(bytes),
                "deadwood": findingsByNode[id]?.safety.key ?? (Deadwood.classify(node) != nil ? "yes" : "none"),
                "ranger_mark": verdicts[path]?.policyMark.rawValue ?? "none",
                "git_worktree": record.worktreeRecord != nil,
                "batch": fast,
            ])
            if record.worktreeRecord != nil {
                flash(.info, "Git has forgotten the worktree \(node.name), so its branch is free again. ⌘Z brings both back."
                      + (Git.isConductorWorkspace(path) ? " Archive it in Conductor too." : ""))
            }
            gitChecks[path] = nil
            return true
        }
    }

    func clearDeadwood() async {
        let picks = findings.filter { deadwoodPicks.contains($0.id) && $0.choppable }
        guard !picks.isEmpty else { return }
        clearingDeadwood = true
        var total: Int64 = 0, ok = 0, skipped = 0
        for f in picks {
            // Parent already chopped, or it vanished.
            guard FileManager.default.fileExists(atPath: f.node.path) else { continue }
            // Never bulk-chop a checkout with unsaved git work.
            if f.node.isDirectory && Git.isCheckout(f.node.path) {
                let path = f.node.path
                let check = await Task.detached { Git.check(path) }.value
                if check?.atRisk ?? true { skipped += 1; deadwoodPicks.remove(f.id); continue }
            }
            let size = f.node.size
            if await chop(f.node, fast: true) { total += size; ok += 1 }
        }
        clearingDeadwood = false
        Telemetry.track("deadwood_cleared", ["count": ok, "skipped_git": skipped, "size": Telemetry.bucket(total)])
        if ok > 0 {
            sound.play(.chime)
            flash(.success, "Cleared \(ok) patch\(ok == 1 ? "" : "es") of deadwood — \(Fmt.bytes(total)) in the Trash."
                  + (skipped > 0 ? " Skipped \(skipped) with unsaved git work." : ""))
        } else if skipped > 0 {
            flash(.warning, "Skipped \(skipped) checkout\(skipped == 1 ? "" : "s") with unsaved git work. Commit or push first, or chop it by hand.")
        }
    }

    func undo() {
        guard let last = undoStack.popLast() else { flash(.info, "Nothing to put back."); return }
        do {
            try Chopper.restore(last.record)
            withAnimation(.spring(duration: 0.6, bounce: 0.3)) {
                last.node.reattach(to: last.parent)
                reclaimed -= last.record.bytes
                choppedCount -= 1
                if let f = Deadwood.classify(last.node) {
                    findings.append(f)
                    findings.sort { $0.node.size > $1.node.size }
                    findingsByNode[last.node.id] = f
                }
                revision += 1
            }
            sound.play(.sprout)
            Telemetry.track("chop_undone")
            flash(.success, "Replanted \(last.node.displayName).")
        } catch {
            flash(.warning, error.localizedDescription)
        }
    }

    func openTrash() {
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
    }

    func emptyTrash() {
        let script = NSAppleScript(source: "tell application \"Finder\" to empty trash")
        var err: NSDictionary?
        script?.executeAndReturnError(&err)
        if let err {
            flash(.warning, "Finder didn't empty the Trash: \(err[NSAppleScript.errorMessage] as? String ?? "permission denied").")
            return
        }
        undoStack.removeAll()
        ChopLog.forgetHauled()
        Telemetry.track("trash_emptied")
        volume = VolumeInfo.of(root?.url ?? URL(fileURLWithPath: NSHomeDirectory()))
        sound.play(.crash, volume: 0.5)
        sound.play(.chime)
        flash(.success, "Hauled away. \(Fmt.bytes(volume.available)) free now.")
    }

    // MARK: - Ranger (Jev)

    func askRanger(_ nodes: [Node]) {
        guard let client = JevClient.fromEnvironmentOrKeychain(model: jevModel) else {
            rangerError = "Add a TypeSafe API key in Settings → Ranger to let Jev mark trees."
            flash(.info, "The Ranger needs a TypeSafe API key — add one in Settings.")
            return
        }
        let todo = nodes.filter { verdicts[$0.path] == nil && !rangerPending.contains($0.path) && $0.size > 0 }
        guard !todo.isEmpty else { return }
        rangerError = nil
        for n in todo { rangerPending.insert(n.path) }
        surveying = true
        sound.play(.whistle)
        Telemetry.track("ranger_used", ["trees": todo.count])
        let items = todo.map { RangerItem(node: $0, finding: findingsByNode[$0.id]) }
        let pathMap = Dictionary(todo.map { (Fmt.tilde($0.path), $0.path) }, uniquingKeysWith: { a, _ in a })
        Task {
            _ = await Ranger.judgeAll(items, client: client) { [weak self] tildePath, result in
                await MainActor.run {
                    guard let self else { return }
                    let full = pathMap[tildePath] ?? tildePath
                    self.rangerPending.remove(full)
                    switch result {
                    case .success(let v):
                        withAnimation(.spring(duration: 0.4, bounce: 0.5)) { self.verdicts[full] = v }
                        self.sound.play(.paint, volume: 0.5)
                    case .failure(let e):
                        self.rangerError = e.localizedDescription
                    }
                }
            }
            surveying = false
            if let e = rangerError { flash(.warning, e) }
        }
    }

    func surveyGrove() {
        guard let c = current else { return }
        askRanger(Array(c.children.prefix(ForestLayout.maxTrees)))
    }

    // MARK: - Misc

    func flash(_ style: Toast.Style, _ message: String) {
        let t = Toast(style: style, message: message)
        withAnimation(.spring(duration: 0.4)) { toast = t }
        Task {
            try? await Task.sleep(for: .seconds(style == .warning ? 5 : 3.2))
            if toast?.id == t.id { withAnimation(.smooth) { toast = nil } }
        }
    }

    func revealInFinder(_ node: Node) {
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Survey"
        panel.message = "Pick a folder to turn into a forest."
        if panel.runModal() == .OK, let url = panel.url { startScan(url) }
    }
}
