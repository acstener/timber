import Foundation

public struct ChopRecord: Codable, Sendable {
    public let original: String
    public let trashed: String
    public let bytes: Int64
    public let date: Date
    public var via: String
    /// For git worktrees: where git's record was set aside, where it lived, and the main repo.
    public var worktreeRecord: String? = nil
    public var worktreeRecordOriginal: String? = nil
    public var mainRepo: String? = nil
}

public enum ChopError: LocalizedError {
    case protected(String)
    case missing(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .protected(let why): return why
        case .missing(let p): return "\(p) isn't there any more."
        case .failed(let why): return why
        }
    }
}

/// Moves things to the Trash. Never deletes anything permanently.
public enum Chopper {
    private static let home = NSHomeDirectory()

    private static let protectedHome: Set<String> = [
        "", "Library", "Library/Application Support", "Library/Containers", "Library/Group Containers",
        "Library/Caches", "Library/Developer", "Library/Mobile Documents", "Library/CloudStorage", "Library/Mail",
        "Library/Messages", "Library/Photos", "Library/Safari", "Library/Developer/Xcode", "Library/Developer/CoreSimulator",
        "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Public", "Applications", ".Trash",
        ".ssh", ".gnupg", ".config", ".local", ".claude", ".zshrc", ".bash_profile", ".gitconfig"
    ]
    private static let protectedHomePrefixes = ["Library/Keychains", "Library/Preferences", ".ssh", ".gnupg", "Library/Mobile Documents/com~apple~CloudDocs"]

    /// Why this path must not be chopped, or nil if it's fair game.
    public static func protectedReason(_ path: String) -> String? {
        let p = (path as NSString).standardizingPath
        if p.hasSuffix(".photoslibrary") {
            return "That's a Photos library. Timber won't chop it — manage it inside Photos."
        }
        if p == home || p.hasPrefix(home + "/") {
            let rel = p == home ? "" : String(p.dropFirst(home.count + 1))
            if protectedHome.contains(rel) {
                return rel.isEmpty ? "That's your whole home folder." : "~/\(rel) is a load-bearing folder, so Timber won't fell it whole. Walk in and chop what's inside."
            }
            if protectedHomePrefixes.contains(where: { rel == $0 || rel.hasPrefix($0 + "/") }) {
                return "~/\(rel) holds keys or settings. Timber leaves it alone."
            }
            return nil
        }
        if p.hasPrefix("/Applications/"), p.hasSuffix(".app"), p.split(separator: "/").count == 2 {
            return nil
        }
        if p.hasPrefix("/Volumes/"), p.split(separator: "/").count > 2 {
            return nil
        }
        if p.hasPrefix("/System/Volumes/Data/Users/") {
            return protectedReason(String(p.dropFirst("/System/Volumes/Data".count)))
        }
        return "Timber only chops inside your home folder, apps in /Applications and external drives."
    }

    /// Moves `path` to the Trash and logs it so it can be restored.
    @discardableResult
    public static func chop(_ path: String, bytes: Int64, via: String) throws -> ChopRecord {
        if let why = protectedReason(path) { throw ChopError.protected(why) }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) || (try? url.checkResourceIsReachable()) == true else {
            throw ChopError.missing(path)
        }
        let worktree = Git.isWorktree(path) ? Git.gitdir(of: path) : nil
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        } catch {
            throw ChopError.failed("Couldn't move \((path as NSString).lastPathComponent) to the Trash: \(error.localizedDescription)")
        }
        var rec = ChopRecord(original: path, trashed: resulting?.path ?? "", bytes: bytes, date: Date(), via: via)
        // A worktree in the Trash leaves git thinking it still exists (and its branch stays locked).
        // Set git's record aside so git forgets it now; restore puts it back.
        if let meta = worktree, FileManager.default.fileExists(atPath: meta) {
            var main: String?
            if let common = try? String(contentsOfFile: meta + "/commondir", encoding: .utf8) {
                let c = common.trimmingCharacters(in: .whitespacesAndNewlines)
                main = (((c.hasPrefix("/") ? c : (meta as NSString).appendingPathComponent(c)) as NSString).standardizingPath as NSString).deletingLastPathComponent
            }
            if let stored = Git.detachRecord(meta) {
                rec.worktreeRecord = stored
                rec.worktreeRecordOriginal = meta
                rec.mainRepo = main
            }
        }
        ChopLog.append(rec)
        return rec
    }

    /// Puts a chopped item back where it was.
    public static func restore(_ rec: ChopRecord) throws {
        let fm = FileManager.default
        guard !rec.trashed.isEmpty, fm.fileExists(atPath: rec.trashed) else {
            throw ChopError.failed("It's no longer in the Trash.")
        }
        if fm.fileExists(atPath: rec.original) {
            throw ChopError.failed("Something new already lives at \(rec.original).")
        }
        if let original = rec.worktreeRecordOriginal, fm.fileExists(atPath: original) {
            throw ChopError.failed("Git already has a different worktree named \((original as NSString).lastPathComponent).")
        }
        try fm.createDirectory(atPath: (rec.original as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fm.moveItem(atPath: rec.trashed, toPath: rec.original)
        if let stored = rec.worktreeRecord, let original = rec.worktreeRecordOriginal {
            try Git.reattachRecord(from: stored, to: original, worktree: rec.original, mainRepo: rec.mainRepo)
        }
        ChopLog.markRestored(rec)
    }
}

/// Append-only JSON-lines log shared by the app and the MCP server.
public enum ChopLog {
    public static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Timber", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("chop-log.jsonl")
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    static func append(_ rec: ChopRecord) {
        guard var data = try? encoder.encode(rec) else { return }
        data.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    static func markRestored(_ rec: ChopRecord) {
        var all = entries()
        all.removeAll { $0.original == rec.original && $0.trashed == rec.trashed }
        let lines = all.compactMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: url, atomically: true, encoding: .utf8)
    }

    /// After the Trash is emptied: forget chops that are gone for good, and their set-aside worktree records.
    public static func forgetHauled() {
        let fm = FileManager.default
        let all = entries()
        let gone = all.filter { $0.trashed.isEmpty || !fm.fileExists(atPath: $0.trashed) }
        for g in gone { if let stored = g.worktreeRecord { try? fm.removeItem(atPath: stored) } }
        let keep = all.filter { !($0.trashed.isEmpty || !fm.fileExists(atPath: $0.trashed)) }.reversed()
        let lines = keep.compactMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Chops still sitting in the Trash, newest first.
    public static func entries() -> [ChopRecord] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? decoder.decode(ChopRecord.self, from: Data($0.utf8)) }.reversed()
    }
}
