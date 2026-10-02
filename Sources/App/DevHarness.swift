#if DEBUG
import AppKit
import SwiftUI

/// Dev-only: with TIMBER_DEV_DIR set, Timber reads one-line commands from `<dir>/cmd`
/// and writes window snapshots to `<dir>/<name>.png`. Lets the UI be exercised headlessly.
@MainActor
enum DevHarness {
    private static var started = false

    static func startIfRequested() {
        guard !started, let dir = ProcessInfo.processInfo.environment["TIMBER_DEV_DIR"] else { return }
        started = true
        let cmdURL = URL(fileURLWithPath: dir).appendingPathComponent("cmd")
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in
                guard let text = try? String(contentsOf: cmdURL, encoding: .utf8), !text.isEmpty else { return }
                try? FileManager.default.removeItem(at: cmdURL)
                for line in text.split(separator: "\n") { run(String(line), dir: dir) }
            }
        }
    }

    static func run(_ line: String, dir: String) {
        let m = ForestModel.shared
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        let trees = m.current.map { Array($0.children.prefix(ForestLayout.maxTrees)) } ?? []
        switch parts.first ?? "" {
        case "snap": snapshot(to: "\(dir)/\(arg.isEmpty ? "snap" : arg).png")
        case "snap3d":
            if let img = SurveyScene.current?.view.snapshot(), let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(arg.isEmpty ? "snap3d" : arg).png"))
            }
        case "scan": m.startScan(URL(fileURLWithPath: (arg as NSString).expandingTildeInPath))
        case "select": if let i = Int(arg), i < trees.count { m.select(trees[i]) }
        case "selectname": m.select(trees.first { $0.name == arg })
        case "deselect": m.select(nil)
        case "enter": if let s = m.selected { m.enter(s) }
        case "back": m.back()
        case "chop": if let s = m.selected { m.requestChop(s) }
        case "confirm": if let c = m.confirming { m.confirming = nil; Task { await m.chop(c) } }
        case "undo": m.undo()
        case "replay": m.replaySurvey()
        case "welcome": m.backToWelcome()
        case "ranger": m.surveyGrove()
        case "deadwood": m.showDeadwood.toggle()
        case "clear": Task { await m.clearDeadwood() }
        case "sky": UserDefaults.standard.set(arg, forKey: "skyMode")
        case "home": m.phase = .welcome
        case "size":
            let wh = arg.split(separator: "x").compactMap { Double($0) }
            if wh.count == 2, let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) {
                w.setContentSize(NSSize(width: wh[0], height: wh[1]))
            }
        case "state":
            let sn = m.scanSnapshot
            try? "phase=\(m.phase) files=\(sn.files) bytes=\(sn.bytes) sprouts=\(m.sprouts.count)".write(toFile: "\(dir)/state.txt", atomically: true, encoding: .utf8)
        case "dump":
            let lines = trees.enumerated().map { "\($0.offset) \($0.element.name) \(Fmt.bytes($0.element.size))" }
            let header = "grove=\(m.current?.path ?? "-") trail=\(m.trail.count)"
            try? ([header] + lines).joined(separator: "\n").write(toFile: "\(dir)/dump.txt", atomically: true, encoding: .utf8)
        default: break
        }
    }

    static func snapshot(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }),
              let view = window.contentView?.superview ?? window.contentView else { return }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
