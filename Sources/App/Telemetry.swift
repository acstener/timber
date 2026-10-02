import Foundation

/// Anonymous, coarse usage stats sent to PostHog. Never sends file names, paths, folder
/// names, Jev verdict details or anything about what's on your disk — only counts, size
/// buckets and which features were used. Off switch: Settings → General.
enum Telemetry {
    private static let host = URL(string: "https://eu.i.posthog.com/i/v0/e/")!
    /// PostHog project key. It's a public, write-only key designed to ship inside clients.
    private static let apiKey = "phc_DGTUKScCXfFehGH6epBvcA8CrQX7y5AhTC2sDkfLAbH"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "telemetryOn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "telemetryOn") }
    }

    /// A random id for this install. Not tied to you, your Mac or your account.
    private static var installID: String {
        if let id = UserDefaults.standard.string(forKey: "installID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "installID")
        return id
    }

    private static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    static func track(_ event: String, _ props: [String: Any] = [:]) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TIMBER_TELEMETRY_DEBUG"] == nil { return }
        #endif
        guard enabled else { return }
        var properties: [String: Any] = props
        properties["app"] = "timber"
        properties["app_version"] = appVersion
        properties["os_version"] = ProcessInfo.processInfo.operatingSystemVersionString
        properties["$lib"] = "timber-mac"
        properties["$process_person_profile"] = false   // anonymous events, no person profiles
        properties["$geoip_disable"] = true             // no location lookup
        properties["$ip"] = ""                          // don't record the sender's IP
        let body: [String: Any] = [
            "api_key": apiKey,
            "event": event,
            "distinct_id": installID,
            "properties": properties,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: host, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        URLSession.shared.dataTask(with: req).resume()
    }

    /// Bytes → a coarse bucket, so exact sizes never leave the Mac.
    static func bucket(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        switch gb {
        case ..<0.1: return "<100MB"
        case ..<1: return "100MB-1GB"
        case ..<10: return "1-10GB"
        case ..<50: return "10-50GB"
        case ..<200: return "50-200GB"
        default: return "200GB+"
        }
    }
}
