import Foundation

public enum Safety: Int, Comparable, CaseIterable, Sendable {
    case safe = 0, likely, review

    public static func < (a: Safety, b: Safety) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .safe: return "Safe to clear"
        case .likely: return "Probably safe"
        case .review: return "Look first"
        }
    }
    public var key: String {
        switch self {
        case .safe: return "safe"
        case .likely: return "likely"
        case .review: return "review"
        }
    }
}

/// Something the deadwood rules recognise: a cache, build output, installer, or other
/// space that's usually safe to reclaim.
public struct Finding: Identifiable, @unchecked Sendable {
    public var id: ObjectIdentifier { node.id }
    public let node: Node
    public let title: String
    public let reason: String
    public let safety: Safety
    public let symbol: String
    /// False for things Timber can only point at (e.g. the Trash itself).
    public var choppable = true
    public var isWorktree = false
}

public enum Deadwood {
    private struct Rule {
        let title: String
        let reason: String
        let safety: Safety
        let symbol: String
        var choppable = true
    }

    private static let exact: [String: Rule] = {
        var r: [String: Rule] = [:]
        func add(_ paths: [String], _ title: String, _ reason: String, _ safety: Safety, _ symbol: String, choppable: Bool = true) {
            for p in paths { r[p] = Rule(title: title, reason: reason, safety: safety, symbol: symbol, choppable: choppable) }
        }
        add(["Library/Developer/Xcode/DerivedData"], "Xcode DerivedData",
            "Build products and indexes. Xcode rebuilds them the next time you build.", .safe, "hammer.fill")
        add(["Library/Developer/Xcode/iOS DeviceSupport", "Library/Developer/Xcode/watchOS DeviceSupport",
             "Library/Developer/Xcode/tvOS DeviceSupport", "Library/Developer/Xcode/visionOS DeviceSupport",
             "Library/Developer/Xcode/macOS DeviceSupport"], "Device support files",
            "Debug symbols copied from devices you've plugged in. Xcode copies them again next time you connect.", .likely, "iphone")
        add(["Library/Developer/Xcode/Archives"], "Xcode archives",
            "Builds you archived for release. Keep any you still need to symbolicate crash reports.", .review, "archivebox.fill")
        add(["Library/Developer/CoreSimulator/Caches"], "Simulator caches",
            "Simulator runtime caches. Rebuilt when a simulator boots.", .safe, "iphone.gen3")
        add(["Library/Developer/CoreSimulator/Devices"], "Simulator devices",
            "Every Simulator you've created, with the apps and data inside. `xcrun simctl delete unavailable` is a gentler cut.", .review, "iphone.gen3")
        add(["Library/Developer/XCPGDevices"], "Playground simulators",
            "Simulators Xcode Playgrounds spun up. Recreated on demand.", .likely, "iphone.gen3")
        add(["Library/Caches/Homebrew"], "Homebrew downloads",
            "Bottles and tarballs Homebrew already installed. Same as `brew cleanup`.", .safe, "mug.fill")
        add([".npm/_cacache"], "npm cache", "Packages npm downloaded before. Fetched again when needed.", .safe, "shippingbox.fill")
        add(["Library/pnpm/store", ".pnpm-store", ".local/share/pnpm/store"], "pnpm store",
            "pnpm's shared package store. Projects re-link it on the next install.", .safe, "shippingbox.fill")
        add(["Library/Caches/Yarn", ".yarn/berry/cache"], "Yarn cache", "Yarn's download cache.", .safe, "shippingbox.fill")
        add([".bun/install/cache"], "Bun cache", "Bun's package cache.", .safe, "shippingbox.fill")
        add([".gradle/caches"], "Gradle caches", "Downloaded dependencies and build caches. Gradle re-fetches them.", .safe, "shippingbox.fill")
        add([".m2/repository"], "Maven repository", "Downloaded Java dependencies. Re-downloaded on the next build.", .likely, "shippingbox.fill")
        add([".cargo/registry"], "Cargo registry", "Downloaded Rust crates. Re-fetched on the next build.", .safe, "shippingbox.fill")
        add(["go/pkg/mod"], "Go module cache", "Downloaded Go modules. Same as `go clean -modcache`.", .likely, "shippingbox.fill")
        add([".cache/pip", "Library/Caches/pip"], "pip cache", "Python packages pip downloaded before.", .safe, "shippingbox.fill")
        add([".cache/uv", "Library/Caches/uv"], "uv cache", "uv's Python package cache.", .safe, "shippingbox.fill")
        add(["Library/Caches/CocoaPods"], "CocoaPods cache", "Pod downloads. Re-fetched on `pod install`.", .safe, "shippingbox.fill")
        add(["Library/Caches/ms-playwright"], "Playwright browsers", "Browsers Playwright downloaded for tests. `npx playwright install` brings them back.", .likely, "safari.fill")
        add([".cache/huggingface"], "Hugging Face models",
            "AI models and datasets you've downloaded. They re-download on demand, but they're big and slow to fetch.", .review, "brain.head.profile")
        add([".ollama/models"], "Ollama models", "Local AI models. `ollama rm` is the tidy way to drop the ones you don't use.", .review, "brain.head.profile")
        add([".lmstudio/models", ".cache/lm-studio/models"], "LM Studio models", "Local AI models you downloaded.", .review, "brain.head.profile")
        add(["Library/Containers/com.docker.docker/Data/vms"], "Docker disk image",
            "Docker's whole virtual disk: images, containers and volumes. Run `docker system prune` instead of trashing this.", .review, "cube.box.fill", choppable: false)
        add(["Library/Application Support/MobileSync/Backup"], "iPhone & iPad backups",
            "Local device backups. Check you have a newer one (or iCloud Backup) before removing old ones.", .review, "iphone")
        add([".Trash"], "Already in the Trash", "This is chopped wood waiting to be hauled away. Empty the Trash to get it back.", .review, "trash.fill", choppable: false)
        add(["Library/Logs"], "Logs", "Diagnostic logs apps keep writing. Safe to clear.", .likely, "doc.plaintext.fill")
        add(["Library/Application Support/Code/CachedExtensionVSIXs", "Library/Application Support/Code/Cache",
             "Library/Application Support/Code/CachedData", "Library/Application Support/Cursor/CachedExtensionVSIXs",
             "Library/Application Support/Cursor/Cache", "Library/Application Support/Cursor/CachedData"],
            "Editor caches", "VS Code / Cursor caches. Rebuilt automatically.", .safe, "chevron.left.forwardslash.chevron.right")
        add(["Library/Android/sdk/system-images"], "Android system images", "Emulator images. Re-downloadable in Android Studio.", .likely, "apps.iphone")
        add([".android/avd"], "Android emulators", "Your Android virtual devices and their data.", .review, "apps.iphone")
        return r
    }()

    private static let buildDirs: Set<String> = [".next", ".nuxt", ".turbo", ".parcel-cache", ".svelte-kit", ".angular", ".expo", "DerivedData", ".build", ".dart_tool"]

    /// Finds deadwood under `root`, biggest first. Nested matches are skipped.
    public static func find(in root: Node, minSize: Int64 = 20_000_000, now: Date = Date()) -> [Finding] {
        var out: [Finding] = []
        func walk(_ n: Node) {
            if let f = classify(n, now: now) {
                if n.size >= minSize { out.append(f) }
                // A worktree is listed, but its own caches (.build, node_modules) are still worth finding.
                if !f.isWorktree { return }
            }
            for c in n.children where c.isDirectory || c.size >= minSize { walk(c) }
        }
        walk(root)
        return out.sorted { $0.node.size > $1.node.size }
    }

    /// The deadwood rule matching this exact node, if any.
    public static func classify(_ n: Node, now: Date = Date()) -> Finding? {
        let home = NSHomeDirectory()
        let rel: String? = n.path.hasPrefix(home + "/") ? String(n.path.dropFirst(home.count + 1)) : nil

        if let rel, let r = exact[rel] {
            return Finding(node: n, title: r.title, reason: r.reason, safety: r.safety, symbol: r.symbol, choppable: r.choppable)
        }

        let parentPath = (n.path as NSString).deletingLastPathComponent
        let parentRel = parentPath.hasPrefix(home + "/") ? String(parentPath.dropFirst(home.count + 1)) : nil
        let name = n.name
        let ageDays = n.newest > 0 ? Int(now.timeIntervalSince1970 - n.newest) / 86_400 : 0
        let fm = FileManager.default

        if n.isDirectory {
            if parentRel == "Library/Caches" {
                let apple = name.hasPrefix("com.apple.")
                return Finding(node: n, title: "\(appName(fromCacheFolder: name)) cache",
                               reason: apple ? "A macOS cache. macOS rebuilds it, though the app may be slower the first time."
                                             : "An app's cache. The app rebuilds what it needs.",
                               safety: apple ? .likely : .safe, symbol: "tray.full.fill")
            }
            let project = (parentPath as NSString).lastPathComponent
            if Git.isWorktree(n.path) {
                let conductor = Git.isConductorWorkspace(n.path)
                let stale = ageDays > 30
                var f = Finding(node: n, title: "\(conductor ? "Conductor workspace" : "Git worktree") · \(name)",
                               reason: (stale ? "Untouched for \(ageText(ageDays)). " : "")
                                + "A git worktree of \(project). Timber checks for unsaved work first, and tells git to forget it so the branch frees up. ⌘Z restores both."
                                + (conductor ? " Archive it in Conductor too so the app forgets it." : ""),
                               safety: stale ? .likely : .review, symbol: "arrow.triangle.branch")
                f.isWorktree = true
                return f
            }
            if name == "node_modules" {
                let stale = ageDays > 30
                return Finding(node: n, title: "node_modules · \(project)",
                               reason: stale ? "Untouched for \(ageText(ageDays)). `npm install` brings it back if you return to the project."
                                             : "Installed dependencies for an active project. `npm install` brings them back.",
                               safety: stale ? .safe : .likely, symbol: "shippingbox.fill")
            }
            if buildDirs.contains(name) {
                return Finding(node: n, title: "\(name) · \(project)",
                               reason: "Build cache for \(project). Recreated on the next build.", safety: .safe, symbol: "hammer.fill")
            }
            if name == "target", fm.fileExists(atPath: parentPath + "/Cargo.toml") {
                return Finding(node: n, title: "Rust target · \(project)", reason: "Rust build output. `cargo build` recreates it.", safety: .safe, symbol: "hammer.fill")
            }
            if name == "Pods", fm.fileExists(atPath: parentPath + "/Podfile") {
                return Finding(node: n, title: "Pods · \(project)", reason: "CocoaPods dependencies. `pod install` restores them.", safety: .likely, symbol: "shippingbox.fill")
            }
            if [".venv", "venv", "env"].contains(name), fm.fileExists(atPath: n.path + "/pyvenv.cfg") {
                return Finding(node: n, title: "Python venv · \(project)",
                               reason: "A Python virtual environment\(ageDays > 30 ? ", untouched for \(ageText(ageDays))" : ""). Recreate it from requirements.",
                               safety: .likely, symbol: "shippingbox.fill")
            }
            return nil
        }

        switch n.pathExtension {
        case "ipsw":
            return Finding(node: n, title: name, reason: "Apple device firmware. Re-downloaded when needed.", safety: .safe, symbol: "iphone.and.arrow.forward")
        case "dmg", "pkg", "iso", "xip", "mpkg":
            return Finding(node: n, title: name,
                           reason: "An installer\(ageDays > 7 ? " from \(ageText(ageDays)) ago" : ""). Once the app's installed you rarely need it.",
                           safety: .likely, symbol: "opticaldiscdrive.fill")
        default: break
        }
        if let rel, rel.hasPrefix("Downloads/") {
            if n.kind == .archive, n.size >= 200_000_000 {
                return Finding(node: n, title: name, reason: "A big archive in Downloads. You've probably already unpacked it.", safety: .review, symbol: "doc.zipper")
            }
            if n.size >= 500_000_000, ageDays > 60 {
                return Finding(node: n, title: name, reason: "A big download untouched for \(ageText(ageDays)).", safety: .review, symbol: "arrow.down.circle.fill")
            }
        }
        return nil
    }

    public static func appName(fromCacheFolder name: String) -> String {
        let skip: Set<String> = ["com", "org", "net", "io", "app", "co", "uk", "client", "helper", "shipit", "desktop", "mac", "macos", "dev"]
        let parts = name.split(separator: ".").map(String.init).filter { !skip.contains($0.lowercased()) }
        guard let last = parts.last, !last.isEmpty else { return name }
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    public static func ageText(_ days: Int) -> String {
        if days < 14 { return "\(days) days" }
        if days < 60 { return "\(days / 7) weeks" }
        if days < 730 { return "\(days / 30) months" }
        return "\(days / 365) years"
    }
}
