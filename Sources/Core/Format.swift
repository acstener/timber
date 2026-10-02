import Foundation

public enum Fmt {
    public static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, b), countStyle: .file)
    }

    public static func count(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    public static func relative(_ d: Date?) -> String {
        guard let d else { return "unknown" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }

    public static func isoDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    public static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    public static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

public struct VolumeInfo: Sendable {
    public var name: String
    public var total: Int64
    public var available: Int64

    public var used: Int64 { max(0, total - available) }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    public static func of(_ url: URL = URL(fileURLWithPath: NSHomeDirectory())) -> VolumeInfo {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        let v = try? url.resourceValues(forKeys: keys)
        let important = v?.volumeAvailableCapacityForImportantUsage ?? 0
        let plain = Int64(v?.volumeAvailableCapacity ?? 0)
        return VolumeInfo(name: v?.volumeName ?? "Disk", total: Int64(v?.volumeTotalCapacity ?? 0), available: max(important, plain))
    }
}
