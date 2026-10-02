import Foundation

/// What git knows about a folder before Timber chops it.
public struct GitCheck: Sendable {
    public var isWorktree: Bool
    /// The repo's main working tree (for a linked worktree).
    public var mainRepo: String?
    /// `.git/worktrees/<name>` — git's record of a linked worktree.
    public var metadataDir: String?
    public var branch: String?
    public var uncommitted: Int
    /// Commits reachable only from this checkout's HEAD: on no other branch and no remote.
    public var onlyHere: Int
    public var conductor: Bool

    public var atRisk: Bool { uncommitted > 0 || onlyHere > 0 }

    public var summary: String {
        var parts: [String] = []
        parts.append(isWorktree ? "Git worktree\(mainRepo.map { " of \(($0 as NSString).lastPathComponent)" } ?? "")" : "Git repository")
        if let branch { parts.append("on \(branch)") }
        var s = parts.joined(separator: " ")
        if uncommitted > 0 { s += " · \(uncommitted) uncommitted change\(uncommitted == 1 ? "" : "s")" }
        if onlyHere > 0 { s += " · \(onlyHere) commit\(onlyHere == 1 ? "" : "s") that exist nowhere else" }
        if !atRisk { s += " · everything committed and saved elsewhere" }
        return s
    }

    public var warning: String? {
        guard atRisk else { return nil }
        var bits: [String] = []
        if uncommitted > 0 { bits.append("\(uncommitted) uncommitted change\(uncommitted == 1 ? "" : "s")") }
        if onlyHere > 0 { bits.append("\(onlyHere) commit\(onlyHere == 1 ? "" : "s") not on any other branch or remote") }
        return "Unsaved git work: " + bits.joined(separator: " and ") + "."
    }

    public var asDictionary: [String: Any] {
        var d: [String: Any] = ["kind": isWorktree ? "worktree" : "repository", "uncommitted_changes": uncommitted, "commits_only_here": onlyHere]
        if let branch { d["branch"] = branch }
        if let mainRepo { d["main_repo"] = Fmt.tilde(mainRepo) }
        if conductor { d["conductor_workspace"] = true }
        return d
    }
}

private final class DataBox: @unchecked Sendable { var data = Data() }

public enum Git {
    /// Cheap: does this folder have its own `.git` (repo) or a `.git` file (linked worktree)?
    public static func isCheckout(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path + "/.git")
    }

    /// A linked worktree: `.git` is a file whose gitdir has a `commondir` marker.
    /// (Submodules also use a `.git` file, but their gitdir has no commondir — never detach those.)
    public static func isWorktree(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path + "/.git", isDirectory: &isDir), !isDir.boolValue,
              let gd = gitdir(of: path) else { return false }
        return FileManager.default.fileExists(atPath: gd + "/commondir")
    }

    public static func isConductorWorkspace(_ path: String) -> Bool {
        path.contains("/conductor/workspaces/")
    }

    /// The `gitdir:` a worktree's `.git` file points at.
    static func gitdir(of path: String) -> String? {
        guard let text = try? String(contentsOfFile: path + "/.git", encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let full = raw.hasPrefix("/") ? raw : (path as NSString).appendingPathComponent(raw)
        return (full as NSString).standardizingPath
    }

    /// Runs git to see what would be lost. Returns nil if this isn't a checkout or git isn't available.
    public static func check(_ path: String) -> GitCheck? {
        guard isCheckout(path) else { return nil }
        let worktree = isWorktree(path)
        var meta: String?
        var main: String?
        if worktree, let gd = gitdir(of: path) {
            meta = gd
            if let common = try? String(contentsOfFile: gd + "/commondir", encoding: .utf8) {
                let c = common.trimmingCharacters(in: .whitespacesAndNewlines)
                let commonDir = ((c.hasPrefix("/") ? c : (gd as NSString).appendingPathComponent(c)) as NSString).standardizingPath
                main = (commonDir as NSString).deletingLastPathComponent
            }
        }
        guard let status = run(["status", "--porcelain"], in: path) else { return nil }
        let uncommitted = status.split(separator: "\n").count
        let branch = run(["rev-parse", "--abbrev-ref", "HEAD"], in: path)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var only = 0
        if let b = branch, b != "HEAD" {
            only = Int(run(["rev-list", "--count", "HEAD", "--not", "--exclude=\(b)", "--branches", "--remotes"], in: path)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        } else {
            only = Int(run(["rev-list", "--count", "HEAD", "--not", "--branches", "--remotes"], in: path)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        }
        return GitCheck(isWorktree: worktree, mainRepo: main, metadataDir: meta, branch: branch,
                        uncommitted: uncommitted, onlyHere: only, conductor: isConductorWorkspace(path))
    }

    @discardableResult
    static func run(_ args: [String], in dir: String, timeout: TimeInterval = 8) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let box = DataBox()
        let done = DispatchSemaphore(value: 0)
        let reader = out.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            box.data = reader.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return nil }
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: box.data, as: UTF8.self) : nil
    }

    // MARK: detaching worktrees

    static var metaStore: URL {
        let dir = ChopLog.url.deletingLastPathComponent().appendingPathComponent("worktree-records", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Sets git's record of a worktree aside so git forgets it (and frees its branch) — the
    /// same effect as `git worktree prune`, but kept so undo can put it back.
    static func detachRecord(_ metadataDir: String) -> String? {
        let dest = metaStore.appendingPathComponent(UUID().uuidString).path
        do {
            try FileManager.default.moveItem(atPath: metadataDir, toPath: dest)
            return dest
        } catch {
            return nil
        }
    }

    static func reattachRecord(from stored: String, to original: String, worktree: String, mainRepo: String?) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: stored) else { return }
        if fm.fileExists(atPath: original) {
            throw ChopError.failed("Git already has a different worktree named \((original as NSString).lastPathComponent).")
        }
        try fm.moveItem(atPath: stored, toPath: original)
        if let mainRepo { run(["worktree", "repair", worktree], in: mainRepo) }
    }
}
