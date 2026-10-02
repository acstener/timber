import Foundation

// Timber MCP server: lets Claude survey your disk, find deadwood, ask the Jev ranger,
// and chop (move to Trash) — over stdio JSON-RPC.

setvbuf(stdout, nil, _IOLBF, 0)

func log(_ s: String) {
    FileHandle.standardError.write(Data(("[timber-mcp] " + s + "\n").utf8))
}

func send(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

let instructions = """
Timber shows where disk space is going on this Mac and frees it by moving things to the Trash (never permanent deletion).
Typical flow: disk_overview → find_deadwood (and/or survey for the big picture) → ranger to get Jev's safety marks on candidates → \
present a short plan to the user with sizes and reasons → only after the user clearly agrees, call chop with the exact paths. \
Never chop personal files (documents, photos, projects) without explicit approval of each path. \
Space returns once the user empties the Trash; restore can put things back.
"""

// MARK: - Scan cache

final class ScanCache: @unchecked Sendable {
    var roots: [String: (node: Node, at: Date, unreadable: Int)] = [:]

    func tree(for path: String, fresh: Bool) async -> (Node, Int) {
        if !fresh {
            if let hit = roots[path], Date().timeIntervalSince(hit.at) < 900 { return (hit.node, hit.unreadable) }
            // A cached ancestor scan already covers it.
            for (root, hit) in roots where Date().timeIntervalSince(hit.at) < 900 && path.hasPrefix(root + "/") {
                if let n = hit.node.find(path: path) { return (n, hit.unreadable) }
            }
        }
        let progress = ScanProgress()
        let started = Date()
        let node = await Scanner.scan(URL(fileURLWithPath: path), progress: progress)
        let snap = progress.snapshot
        log("scanned \(path): \(Fmt.count(snap.files)) files, \(Fmt.bytes(node.size)) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        roots[path] = (node, Date(), snap.unreadable)
        return (node, snap.unreadable)
    }

    func cached(_ path: String) -> Node? {
        for (_, hit) in roots { if let n = hit.node.find(path: path) { return n } }
        return nil
    }

    func forget(_ path: String) {
        for (root, hit) in roots {
            if path == root || path.hasPrefix(root + "/") {
                if let n = hit.node.find(path: path) { n.detach() }
            }
        }
    }
}

let cache = ScanCache()

func resolve(_ raw: Any?, default def: String = "~") -> String {
    let s = (raw as? String).flatMap { $0.isEmpty ? nil : $0 } ?? def
    return (Fmt.expand(s) as NSString).standardizingPath
}

func describe(_ n: Node, depth: Int, limit: Int) -> [String: Any] {
    var d: [String: Any] = [
        "path": Fmt.tilde(n.path),
        "size": Fmt.bytes(n.size),
        "bytes": n.size,
        "kind": n.kind.label.lowercased(),
    ]
    if n.isDirectory { d["files"] = n.fileCount }
    if let date = n.newestDate { d["last_modified"] = Fmt.relative(date) }
    if let f = Deadwood.classify(n) { d["deadwood"] = "\(f.title) — \(f.safety.label.lowercased())" }
    if depth > 0, !n.children.isEmpty {
        d["children"] = n.children.prefix(limit).map { describe($0, depth: depth - 1, limit: limit) }
        let rest = n.children.dropFirst(limit)
        let restBytes = rest.reduce(Int64(0)) { $0 + $1.size } + n.hiddenSize
        if restBytes > 0 { d["everything_else"] = "\(Fmt.bytes(restBytes)) across \(rest.count + n.hiddenCount) smaller items" }
    }
    return d
}

func fdaTip(_ unreadable: Int) -> String? {
    unreadable > 0 ? "\(unreadable) folders couldn't be read. Granting Full Disk Access to the app running this server (System Settings → Privacy & Security) shows everything." : nil
}

// MARK: - Tools

let tools: [[String: Any]] = [
    [
        "name": "disk_overview",
        "title": "Disk overview",
        "description": "How full the disk is: capacity, free space, and anything Timber has already chopped that's still in the Trash.",
        "inputSchema": ["type": "object", "properties": [String: Any]()],
        "annotations": ["readOnlyHint": true],
    ],
    [
        "name": "survey",
        "title": "Survey a folder",
        "description": "Measure a folder and return its biggest children as a size tree. The first scan of a big folder can take a minute; later calls reuse it for 15 minutes.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "Folder to measure. Defaults to ~ (home). For the whole disk use /System/Volumes/Data."],
                "depth": ["type": "integer", "description": "How many levels of children to include (1-4, default 2)."],
                "limit": ["type": "integer", "description": "Max children per level (default 12)."],
                "fresh": ["type": "boolean", "description": "Rescan instead of using a recent scan."],
            ],
        ],
        "annotations": ["readOnlyHint": true],
    ],
    [
        "name": "find_deadwood",
        "title": "Find deadwood",
        "description": "Find space that's usually safe to reclaim: app caches, Xcode DerivedData, node_modules in old projects, package-manager caches, installers, simulator data, old big downloads. Each has a safety level (safe / likely / review) and a reason.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "Where to look (default ~)."],
                "min_size_mb": ["type": "number", "description": "Ignore findings smaller than this (default 50)."],
                "fresh": ["type": "boolean"],
            ],
        ],
        "annotations": ["readOnlyHint": true],
    ],
    [
        "name": "ranger",
        "title": "Ask the Jev ranger",
        "description": "Ask TypeSafe's Jev model to mark paths as chop / review / keep ('mark' applies Timber's safety policy on top of Jev's raw choice), with probabilities that each regenerates, holds irreplaceable personal content, or would break something. Sends only names, sizes and dates. Needs TYPESAFE_API_KEY.",
        "inputSchema": [
            "type": "object",
            "properties": ["paths": ["type": "array", "items": ["type": "string"], "description": "Paths to judge (max 40)."]],
            "required": ["paths"],
        ],
        "annotations": ["readOnlyHint": true, "openWorldHint": true],
    ],
    [
        "name": "chop",
        "title": "Chop (move to Trash)",
        "description": "Move the given paths to the Trash. Reversible with restore until the Trash is emptied. Only call after the user has approved these exact paths. Protected system and personal root folders are refused. Git checkouts with unsaved work (uncommitted changes, or commits on no other branch/remote) are refused unless allow_unsaved_git_work is true. Chopping a git worktree also makes git forget it (freeing its branch); restore brings both back.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "paths": ["type": "array", "items": ["type": "string"]],
                "reason": ["type": "string", "description": "One line on why, recorded in the chop log."],
                "allow_unsaved_git_work": ["type": "boolean", "description": "Chop git checkouts even if they have uncommitted changes or commits that exist nowhere else. Only set after the user explicitly OKs losing that work."],
            ],
            "required": ["paths"],
        ],
        "annotations": ["destructiveHint": true, "idempotentHint": false],
    ],
    [
        "name": "restore",
        "title": "Restore from Trash",
        "description": "Put chopped items back where they were. Pass original paths, or omit to list what can be restored.",
        "inputSchema": [
            "type": "object",
            "properties": ["paths": ["type": "array", "items": ["type": "string"]]],
        ],
    ],
]

func callTool(_ name: String, _ args: [String: Any]) async throws -> Any {
    switch name {
    case "disk_overview":
        let v = VolumeInfo.of()
        let trashed = ChopLog.entries().filter { FileManager.default.fileExists(atPath: $0.trashed) }
        return [
            "volume": v.name,
            "capacity": Fmt.bytes(v.total),
            "free": Fmt.bytes(v.available),
            "used_percent": Int((v.usedFraction * 100).rounded()),
            "chopped_still_in_trash": Fmt.bytes(trashed.reduce(0) { $0 + $1.bytes }),
            "chopped_items_in_trash": trashed.count,
        ] as [String: Any]

    case "survey":
        let path = resolve(args["path"])
        let depth = min(4, max(1, args["depth"] as? Int ?? 2))
        let limit = min(40, max(1, args["limit"] as? Int ?? 12))
        let (node, unreadable) = await cache.tree(for: path, fresh: args["fresh"] as? Bool ?? false)
        var out = describe(node, depth: depth, limit: limit)
        if let tip = fdaTip(unreadable) { out["note"] = tip }
        return out

    case "find_deadwood":
        let path = resolve(args["path"])
        let minMB = (args["min_size_mb"] as? NSNumber)?.doubleValue ?? 50
        let (node, unreadable) = await cache.tree(for: path, fresh: args["fresh"] as? Bool ?? false)
        let found = Deadwood.find(in: node, minSize: Int64(minMB * 1_000_000))
        var totals: [String: Int64] = [:]
        for f in found where f.choppable { totals[f.safety.key, default: 0] += f.node.size }
        var out: [String: Any] = [
            "findings": found.prefix(60).map { f -> [String: Any] in
                var d: [String: Any] = [
                    "path": Fmt.tilde(f.node.path), "title": f.title, "size": Fmt.bytes(f.node.size), "bytes": f.node.size,
                    "safety": f.safety.key, "reason": f.reason,
                ]
                if !f.choppable { d["choppable"] = false }
                if f.isWorktree, let g = Git.check(f.node.path) { d["git"] = g.asDictionary }
                if let date = f.node.newestDate { d["last_modified"] = Fmt.relative(date) }
                return d
            },
            "totals": totals.mapValues { Fmt.bytes($0) },
        ]
        if found.count > 60 { out["more"] = "\(found.count - 60) smaller findings omitted" }
        if let tip = fdaTip(unreadable) { out["note"] = tip }
        return out

    case "ranger":
        guard let client = JevClient.fromEnvironmentOrKeychain() else {
            throw ChopError.failed("No TypeSafe key. Set TYPESAFE_API_KEY in this MCP server's env (claude mcp add timber -e TYPESAFE_API_KEY=… -- …).")
        }
        let paths = (args["paths"] as? [String] ?? []).prefix(40).map { resolve($0) }
        var items: [RangerItem] = []
        var missing: [String] = []
        for p in paths {
            var found = cache.cached(p)
            if found == nil, FileManager.default.fileExists(atPath: p) { found = await cache.tree(for: p, fresh: false).0 }
            if let n = found {
                items.append(RangerItem(node: n, finding: Deadwood.classify(n)))
            } else {
                missing.append(Fmt.tilde(p))
            }
        }
        let results = await Ranger.judgeAll(items, client: client)
        var out: [[String: Any]] = items.map { item in
            var d: [String: Any] = ["path": item.path, "size": Fmt.bytes(item.size)]
            switch results[item.path] {
            case .success(let v)?: d.merge(v.asDictionary) { a, _ in a }
            case .failure(let e)?: d["error"] = e.localizedDescription
            case nil: d["error"] = "No answer"
            }
            return d
        }
        out += missing.map { ["path": $0, "error": "Not found"] }
        return ["model": client.model, "verdicts": out]

    case "chop":
        let paths = (args["paths"] as? [String] ?? []).map { resolve($0) }
        guard !paths.isEmpty else { throw ChopError.failed("No paths given.") }
        var results: [[String: Any]] = []
        var freed: Int64 = 0
        for p in paths {
            if let why = Chopper.protectedReason(p) {
                results.append(["path": Fmt.tilde(p), "chopped": false, "error": why]); continue
            }
            let git = Git.check(p)
            if let git, git.atRisk, (args["allow_unsaved_git_work"] as? Bool) != true {
                results.append(["path": Fmt.tilde(p), "chopped": false, "git": git.asDictionary,
                                "error": (git.warning ?? "Unsaved git work.") + " Ask the user to commit/push first, or confirm losing it and retry with allow_unsaved_git_work: true."])
                continue
            }
            var bytes = cache.cached(p)?.size ?? 0
            if bytes == 0 { bytes = await Scanner.scan(URL(fileURLWithPath: p)).size }
            do {
                let rec = try Chopper.chop(p, bytes: bytes, via: "claude" + ((args["reason"] as? String).map { ": " + $0 } ?? ""))
                cache.forget(p)
                freed += bytes
                var r: [String: Any] = ["path": Fmt.tilde(p), "chopped": true, "size": Fmt.bytes(bytes), "in_trash_at": Fmt.tilde(rec.trashed)]
                if rec.worktreeRecord != nil { r["git"] = "Worktree detached: git has forgotten it and its branch is free. restore brings both back." }
                if Git.isConductorWorkspace(p) { r["note"] = "This was a Conductor workspace; the user should archive it in Conductor too." }
                results.append(r)
            } catch {
                results.append(["path": Fmt.tilde(p), "chopped": false, "error": error.localizedDescription])
            }
        }
        return [
            "results": results,
            "moved_to_trash": Fmt.bytes(freed),
            "note": "Space comes back when the Trash is emptied. Use restore to undo.",
        ] as [String: Any]

    case "restore":
        let entries = ChopLog.entries().filter { FileManager.default.fileExists(atPath: $0.trashed) }
        guard let raw = args["paths"] as? [String], !raw.isEmpty else {
            return ["restorable": entries.prefix(50).map { ["path": Fmt.tilde($0.original), "size": Fmt.bytes($0.bytes), "chopped": Fmt.relative($0.date), "via": $0.via] }]
        }
        let wanted = Set(raw.map { resolve($0) })
        var results: [[String: Any]] = []
        for p in wanted {
            guard let rec = entries.first(where: { $0.original == p }) else {
                results.append(["path": Fmt.tilde(p), "restored": false, "error": "Not in Timber's chop log or no longer in the Trash."]); continue
            }
            do { try Chopper.restore(rec); results.append(["path": Fmt.tilde(p), "restored": true]) }
            catch { results.append(["path": Fmt.tilde(p), "restored": false, "error": error.localizedDescription]) }
        }
        return ["results": results]

    default:
        throw ChopError.failed("Unknown tool \(name)")
    }
}

let prompts: [[String: Any]] = [[
    "name": "clear_space",
    "title": "Clear some space",
    "description": "Walk through the disk with Timber and propose what to chop.",
    "arguments": [["name": "goal", "description": "How much space you want back, e.g. 20GB", "required": false]],
]]

func promptText(_ goal: String?) -> String {
    """
    Help me free up disk space\(goal.map { " — I'd like about \($0) back" } ?? "") using the Timber tools.
    1. Call disk_overview, then find_deadwood on ~ and survey ~ (depth 2) for the big picture.
    2. Call ranger on the biggest candidates (deadwood plus anything large that looks forgotten).
    3. Show me a short table: path, size, safety/ranger mark, one-line reason. Group into "safe to chop now" and "worth a look".
    4. Ask which to chop. Only call chop with the paths I approve. Then tell me how much went to the Trash.
    """
}

// MARK: - JSON-RPC loop

func handle(_ msg: [String: Any]) async {
    let id = msg["id"]
    let method = msg["method"] as? String ?? ""
    let params = msg["params"] as? [String: Any] ?? [:]
    func reply(_ result: Any) { if let id { send(["jsonrpc": "2.0", "id": id, "result": result]) } }
    func fail(_ code: Int, _ message: String) { if let id { send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]) } }

    switch method {
    case "initialize":
        let version = params["protocolVersion"] as? String ?? "2025-06-18"
        reply([
            "protocolVersion": version,
            "capabilities": ["tools": ["listChanged": false], "prompts": ["listChanged": false]],
            "serverInfo": ["name": "timber", "title": "Timber", "version": "1.0.0"],
            "instructions": instructions,
        ])
    case "ping":
        reply([String: Any]())
    case "tools/list":
        reply(["tools": tools])
    case "prompts/list":
        reply(["prompts": prompts])
    case "prompts/get":
        let goal = (params["arguments"] as? [String: Any])?["goal"] as? String
        reply(["description": "Clear some space", "messages": [["role": "user", "content": ["type": "text", "text": promptText(goal)]]]])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        do {
            let result = try await callTool(name, args)
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
            reply(["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "isError": false])
        } catch {
            reply(["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
        }
    default:
        if method.hasPrefix("notifications/") { return }
        fail(-32601, "Method not found: \(method)")
    }
}

log("ready")
while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty, let data = line.data(using: .utf8),
          let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
    let done = DispatchSemaphore(value: 0)
    Task.detached { await handle(msg); done.signal() }
    done.wait()
}
