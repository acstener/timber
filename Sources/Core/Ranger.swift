import Foundation
import Security

/// TypeSafe's Jev: fast typed judgments. The Ranger uses it to mark trees
/// (safe to chop / look first / keep) the way foresters paint trunks.
public struct JevClient: Sendable {
    public static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    public static let defaultModel = "jev-latest"

    public let apiKey: String
    public let model: String

    public init(apiKey: String, model: String = JevClient.defaultModel) {
        self.apiKey = apiKey
        self.model = model.isEmpty ? JevClient.defaultModel : model
    }

    /// Environment first (handy for the MCP server and dev runs), then the Keychain.
    public static func fromEnvironmentOrKeychain(model: String? = nil) -> JevClient? {
        let env = ProcessInfo.processInfo.environment
        let m = model ?? env["JEV_MODEL"] ?? defaultModel
        if let k = env["TYPESAFE_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            return JevClient(apiKey: k, model: m)
        }
        if let k = Keychain.read(), !k.isEmpty { return JevClient(apiKey: k, model: m) }
        return nil
    }

    public struct APIError: LocalizedError {
        public let status: Int
        public let message: String
        public var errorDescription: String? {
            switch status {
            case 401: return "Jev rejected the API key. Check it in Settings → Ranger."
            case 429: return "Jev is rate limiting us. Try again in a moment."
            case 529: return "Jev is overloaded. Try again shortly."
            default: return message
            }
        }
    }

    public func evaluate(state: Any, questions: [String: Any]) async throws -> [String: [String: Any]] {
        var req = URLRequest(url: Self.endpoint, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "state": state, "questions": questions])

        var attempt = 0
        while true {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if (status == 429 || status == 529) && attempt < 2 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(attempt) * 800_000_000)
                continue
            }
            guard (200..<300).contains(status) else {
                let msg = (json?["message"] as? String) ?? (json?["error"] as? String) ?? "Jev returned \(status)."
                throw APIError(status: status, message: msg)
            }
            guard let answers = json?["answers"] as? [String: [String: Any]],
                  questions.keys.allSatisfy({ answers[$0] != nil }) else {
                throw APIError(status: 502, message: "Jev returned an incomplete answer. Try again.")
            }
            return answers
        }
    }
}

public struct RangerVerdict: Sendable, Codable {
    public enum Mark: String, Sendable, Codable { case chop, review, keep }
    public var mark: Mark
    public var probabilities: [String: Double]
    public var confidence: Double
    public var regenerates: Double
    public var irreplaceable: Double
    public var breaksSomething: Double
    public var category: String

    public var chopProbability: Double { probabilities["chop"] ?? 0 }

    /// Code owns the policy: Jev's raw choice is only trusted for "chop" when it's
    /// confident and nothing suggests personal content.
    public var policyMark: Mark {
        if irreplaceable >= 0.6 || (probabilities["keep"] ?? 0) >= 0.5 { return .keep }
        if mark == .chop, chopProbability >= 0.75, irreplaceable < 0.35 { return .chop }
        return mark == .keep ? .keep : .review
    }

    public var headline: String {
        switch policyMark {
        case .chop: return "Marked to fell"
        case .review: return "Look before you chop"
        case .keep: return "Leave standing"
        }
    }

    public var categoryLabel: String {
        Ranger.categories[category] ?? category.capitalized
    }

    public var asDictionary: [String: Any] {
        func r(_ x: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.2f", x)) }
        return [
            "mark": policyMark.rawValue,
            "jev_choice": mark.rawValue,
            "mark_probabilities": probabilities.mapValues(r),
            "confidence": r(confidence),
            "regenerates_automatically": r(regenerates),
            "irreplaceable_user_content": r(irreplaceable),
            "breaks_an_app_or_tool": r(breaksSomething),
            "category": categoryLabel,
        ]
    }
}

/// What the Ranger is told about one item. Only names, sizes and dates are sent — never file contents.
public struct RangerItem: Sendable {
    public var path: String
    public var kind: String
    public var size: Int64
    public var items: Int
    public var lastModified: Date?
    public var largestContents: [String]
    public var knownLocation: String?
    public var git: String?

    public init(node: Node, finding: Finding?) {
        if node.isDirectory, let g = Git.check(node.path) { git = g.summary }
        path = Fmt.tilde(node.path)
        kind = node.kind.label.lowercased()
        size = node.size
        items = node.fileCount
        lastModified = node.newestDate
        largestContents = node.children.prefix(8).map { "\($0.name) (\(Fmt.bytes($0.size)))" }
        knownLocation = finding.map { "\($0.title): \($0.reason)" }
    }

    var state: [String: Any] {
        var item: [String: Any] = [
            "path": path,
            "kind": kind,
            "size": Fmt.bytes(size),
            "file_count": items,
        ]
        if let d = lastModified {
            item["last_modified"] = "\(Fmt.relative(d)) (\(Fmt.isoDay(d)))"
        }
        if !largestContents.isEmpty { item["largest_contents"] = largestContents }
        if let k = knownLocation { item["known_location_note"] = k }
        if let git { item["git"] = git }
        return [
            "context": "A Mac user is freeing disk space. Anything they remove goes to the Trash first. Today is \(Fmt.isoDay(Date())).",
            "item": item,
        ]
    }
}

public enum Ranger {
    public static let categories: [String: String] = [
        "cache": "Cache",
        "build": "Build output",
        "dependencies": "Downloaded dependencies",
        "installer": "Installer",
        "model": "AI model / dataset",
        "media": "Photos, video or audio",
        "documents": "Documents",
        "code": "Source code / projects",
        "app": "Application",
        "app_data": "App data & settings",
        "backup": "Backup",
        "vm": "Virtual machine / container",
        "download": "Downloaded file",
        "other": "Other",
    ]

    static func questions() -> [String: Any] {
        [
            "mark": [
                "type": "choice",
                "instructions": [
                    "question": "What should the user do with `item` to free up space?",
                    "rules": [
                        "Judge from the path, kind, size, dates and largest contents only.",
                        "Caches, build output, downloaded dependencies and installers that software re-creates are safe to chop.",
                        "Anything a person made or collected (photos, videos, documents, projects, recordings, messages) must not be marked chop.",
                        "If it is unclear what it holds, prefer review.",
                    ],
                ],
                "criteria": [
                    "chop": "Safe to move to the Trash: it regenerates, re-downloads, or is clearly leftover, and losing it costs at most a slower first run or a re-download.",
                    "review": "Probably removable, but it may hold something the user cares about, so they should look inside first.",
                    "keep": "Important: personal files, active app data or settings, source code, or anything irreplaceable or needed for something to keep working.",
                ],
            ],
            "regenerates": [
                "type": "noul",
                "instructions": "If `item` were deleted, would software automatically recreate or re-download it when needed, with no lost work?",
                "criteria": [
                    "true": "It is a cache, build product, package/dependency download, or similar output that tools rebuild on demand.",
                    "false": "It holds original data, settings or user work that nothing would recreate.",
                ],
            ],
            "irreplaceable": [
                "type": "noul",
                "instructions": "Is `item` likely to contain content the user created or collected that exists nowhere else (photos, videos, documents, code, recordings, messages, saves)?",
                "criteria": [
                    "true": "Likely contains original personal or work content.",
                    "false": "Likely contains only generated, downloaded or replaceable data.",
                ],
            ],
            "breaks": [
                "type": "noul",
                "instructions": "Would deleting `item` break an installed app, tool or project until it is reinstalled or reconfigured (beyond simply being slower or re-downloading on the next run)?",
                "criteria": [
                    "true": "Something would stop working or lose its configuration.",
                    "false": "Everything keeps working; at worst it rebuilds or re-downloads.",
                ],
            ],
            "category": [
                "type": "choice",
                "instructions": "What best describes what `item` mostly contains?",
                "criteria": [
                    "cache": "A cache of temporary data",
                    "build": "Build output, intermediates or indexes",
                    "dependencies": "Downloaded packages, libraries, SDKs or toolchains",
                    "installer": "Installer, disk image or firmware file",
                    "model": "Downloaded AI models or datasets",
                    "media": "Photos, videos, music or audio",
                    "documents": "Documents, PDFs, spreadsheets or notes",
                    "code": "Source code or creative projects",
                    "app": "An application",
                    "app_data": "An app's data, settings or library",
                    "backup": "A backup or archive of other data",
                    "vm": "A virtual machine, emulator or container disk",
                    "download": "A miscellaneous downloaded file",
                    "other": "None of the above",
                ],
            ],
        ]
    }

    public static func judge(_ item: RangerItem, client: JevClient) async throws -> RangerVerdict {
        let a = try await client.evaluate(state: item.state, questions: questions())
        let markAns = a["mark"] ?? [:]
        let probs = (markAns["probabilities"] as? [String: Any])?.compactMapValues { ($0 as? NSNumber)?.doubleValue } ?? [:]
        func noul(_ k: String) -> Double { (a[k]?["noul"] as? NSNumber)?.doubleValue ?? 0 }
        return RangerVerdict(
            mark: RangerVerdict.Mark(rawValue: markAns["choice"] as? String ?? "review") ?? .review,
            probabilities: probs,
            confidence: (markAns["confidence"] as? NSNumber)?.doubleValue ?? 0,
            regenerates: noul("regenerates"),
            irreplaceable: noul("irreplaceable"),
            breaksSomething: noul("breaks"),
            category: a["category"]?["choice"] as? String ?? "other"
        )
    }

    /// One request per item, several in flight (faster than one giant batch).
    public static func judgeAll(
        _ items: [RangerItem], client: JevClient, concurrency: Int = 6,
        onResult: (@Sendable (String, Result<RangerVerdict, Error>) async -> Void)? = nil
    ) async -> [String: Result<RangerVerdict, Error>] {
        var results: [String: Result<RangerVerdict, Error>] = [:]
        await withTaskGroup(of: (String, Result<RangerVerdict, Error>).self) { group in
            var it = items.makeIterator()
            func next() -> Bool {
                guard let item = it.next() else { return false }
                group.addTask {
                    do { return (item.path, .success(try await judge(item, client: client))) }
                    catch { return (item.path, .failure(error)) }
                }
                return true
            }
            for _ in 0..<concurrency { if !next() { break } }
            while let (path, r) = await group.next() {
                results[path] = r
                await onResult?(path, r)
                _ = next()
            }
        }
        return results
    }
}

public enum Keychain {
    static let service = "uk.co.stener.timber"
    static let account = "typesafe-api-key"

    public static func read() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public static func write(_ value: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
