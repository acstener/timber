import Foundation
import AppKit
import IOKit
import IOKit.ps

// The engine bay: live RAM / CPU / swap / thermal readings, processes rolled up by app,
// startup items, and OBD-style trouble codes. Ported from Redline, minus the dashboard.

public struct BatteryInfo: Sendable {
    public var percent: Int
    public var charging: Bool
    public var onAC: Bool
    public var cycles: Int?
    public var health: Double?
}

/// Processes rolled up to the app bundle that owns them (so 40 Chrome helpers read as "Google Chrome").
public struct AppGroup: Sendable {
    public let id: String
    public var name: String
    public var bundlePath: String?
    public var cpu: Double
    public var memory: UInt64
    public var count: Int
    public var isSystem: Bool
    public var pids: [Int32] = []
    public var ownedByUser = true
}

public struct EngineReading: Sendable {
    public var cpu: Double
    public var cores: Int
    public var chip: String
    public var os: String
    public var memTotal: UInt64
    public var memUsed: UInt64
    /// 0…1, from the kernel's "% of memory still available" signal.
    public var pressure: Double
    public var pressureLevel: String
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var thermal: ProcessInfo.ThermalState
    public var loadAvg: [Double]
    public var uptime: TimeInterval
    public var lowPower: Bool
    public var battery: BatteryInfo?
    public var disk: VolumeInfo
    public var apps: [AppGroup]
    public var processCount: Int

    public var thermalLabel: String {
        switch thermal {
        case .nominal: return "nominal"
        case .fair: return "fair (warm)"
        case .serious: return "serious (throttling)"
        case .critical: return "critical (throttling hard)"
        @unknown default: return "unknown"
        }
    }
    public var userApps: [AppGroup] { apps.filter { !$0.isSystem } }
}

public enum Severity: Int, Comparable, Sendable {
    case advisory, warning, critical
    public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    public var label: String { ["advisory", "warning", "critical"][rawValue] }
}

/// One concrete thing slowing the Mac down, and what to do about it.
public struct TroubleCode: Sendable {
    public let code: String
    public let system: String
    public let severity: Severity
    public let title: String
    public let detail: String
    public var fix: String?
}

public struct LaunchItem: Sendable {
    public enum Scope: String, Sendable { case user, agents, daemons }
    public let label: String
    public let vendor: String
    public let program: String
    public let scope: Scope
    public let runAtLoad: Bool
    public let keepAlive: Bool
    public let path: String
    public var isApple: Bool { label.hasPrefix("com.apple.") }
}

public enum Engine {
    // MARK: Readings

    /// Samples the engine. CPU is measured across `sampleSeconds`.
    public static func read(sampleSeconds: Double = 1) -> EngineReading {
        let host = mach_host_self()
        let t0 = cpuTicks(host)
        let (groups, count) = scanProcesses()
        let elapsed = sampleSeconds - 0.05
        if elapsed > 0 { Thread.sleep(forTimeInterval: elapsed) }
        var cpu = 0.0
        if let a = t0, let b = cpuTicks(host) {
            let d = zip(b, a).map { Double($0 &- $1) }
            let total = d.reduce(0, +)
            if total > 0 { cpu = (d[0] + d[1] + d[3]) / total }
        }

        var memUsed: UInt64 = 0
        var stats = vm_statistics64()
        var n = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics64(host, HOST_VM_INFO64, $0, &n) }
        }
        if kr == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let appPages = stats.internal_page_count > stats.purgeable_count ? UInt64(stats.internal_page_count - stats.purgeable_count) : 0
            memUsed = (appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        }
        var pressure = 0.0
        if let level: Int32 = Sysctl.value("kern.memorystatus_level") { pressure = max(0, min(1, 1 - Double(level) / 100)) }
        let level: Int32 = Sysctl.value("kern.memorystatus_vm_pressure_level") ?? 1
        let swap: xsw_usage? = Sysctl.value("vm.swapusage")
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)

        return EngineReading(
            cpu: cpu, cores: ProcessInfo.processInfo.activeProcessorCount,
            chip: Sysctl.string("machdep.cpu.brand_string") ?? "Mac",
            os: ProcessInfo.processInfo.operatingSystemVersionString.replacingOccurrences(of: "Version ", with: "macOS "),
            memTotal: ProcessInfo.processInfo.physicalMemory, memUsed: memUsed,
            pressure: pressure, pressureLevel: level >= 4 ? "critical" : level >= 2 ? "warning" : "normal",
            swapUsed: swap?.xsu_used ?? 0, swapTotal: swap?.xsu_total ?? 0,
            thermal: ProcessInfo.processInfo.thermalState, loadAvg: load, uptime: Sysctl.uptime(),
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, battery: readBattery(), disk: VolumeInfo.of(),
            apps: groups, processCount: count)
    }

    private static func cpuTicks(_ host: mach_port_t) -> [UInt32]? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3] // user, system, idle, nice
    }

    static func readBattery() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        var info: BatteryInfo?
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            info = BatteryInfo(percent: max > 0 ? cur * 100 / max : cur, charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                               onAC: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
        }
        guard var b = info else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            func prop(_ key: String) -> Int? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
            }
            b.cycles = prop("CycleCount")
            if let raw = prop("AppleRawMaxCapacity") ?? prop("NominalChargeCapacity"), let design = prop("DesignCapacity"), design > 0 {
                b.health = min(1, Double(raw) / Double(design))
            }
        }
        return b
    }

    // MARK: Processes

    static let protectedApps: Set<String> = [
        "Finder.app", "Dock.app", "SystemUIServer.app", "loginwindow.app", "WindowManager.app",
        "ControlCenter.app", "NotificationCenter.app", "Timber.app",
    ]

    private static let friendly: [String: String] = [
        "com.apple.WebKit.WebContent": "Safari & WebKit tabs", "com.apple.WebKit.GPU": "WebKit GPU",
        "com.apple.WebKit.Networking": "WebKit networking", "mds_stores": "Spotlight index", "mdworker_shared": "Spotlight workers",
        "mds": "Spotlight", "photoanalysisd": "Photos analysis", "mediaanalysisd": "Media analysis", "backupd": "Time Machine",
        "bird": "iCloud Drive", "cloudd": "iCloud sync", "fileproviderd": "File Provider", "softwareupdated": "Software Update",
        "coreaudiod": "Core Audio",
    ]

    private struct ProcRow { let pid: Int32; let ppid: Int32; let cpu: Double; let rss: UInt64; let uid: Int; let path: String }

    private static func psRows() -> [ProcRow] {
        let out = Shell.run("/bin/ps", ["-axo", "pid=,ppid=,pcpu=,rss=,uid=,comm="])
        return out.split(separator: "\n").compactMap { line in
            let p = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard p.count == 6, let pid = Int32(p[0]), let ppid = Int32(p[1]), let cpu = Double(p[2]),
                  let rss = UInt64(p[3]), let uid = Int(p[4]) else { return nil }
            return ProcRow(pid: pid, ppid: ppid, cpu: cpu, rss: rss * 1024, uid: uid, path: String(p[5]))
        }
    }

    public static func scanProcesses() -> (groups: [AppGroup], count: Int) {
        let rows = psRows()
        var groups: [String: AppGroup] = [:]
        let me = Int(getuid())
        for r in rows {
            let (key, name, bundle) = identify(r.path)
            if groups[key] == nil {
                groups[key] = AppGroup(id: key, name: name, bundlePath: bundle, cpu: 0, memory: 0, count: 0, isSystem: isSystemPath(r.path))
            }
            groups[key]!.cpu += r.cpu
            groups[key]!.memory += r.rss
            groups[key]!.count += 1
            groups[key]!.pids.append(r.pid)
            if r.uid != me { groups[key]!.ownedByUser = false }
        }
        return (Array(groups.values), rows.count)
    }

    private static func identify(_ path: String) -> (key: String, name: String, bundle: String?) {
        // Outermost .app, so helper apps nested inside an app count toward it.
        if let r = path.range(of: ".app/") {
            let bundle = String(path[..<r.lowerBound]) + ".app"
            return (bundle, String((bundle as NSString).lastPathComponent.dropLast(4)), bundle)
        }
        let base = (path as NSString).lastPathComponent
        return (path, friendly[base] ?? base, nil)
    }

    private static func isSystemPath(_ path: String) -> Bool {
        if !path.hasPrefix("/") { return true }
        return ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/", "/private/var/", "/Library/Developer/CommandLineTools/"]
            .contains { path.hasPrefix($0) }
    }

    /// Group IDs of everything this process runs inside (the terminal or app hosting Claude). Quitting those would end the session.
    public static func hostGroupIDs() -> Set<String> {
        let rows = psRows()
        let byPID = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var out = Set<String>()
        var pid = getpid()
        var hops = 0
        while let r = byPID[pid], hops < 64 {
            out.insert(identify(r.path).key)
            if r.ppid <= 1 { break }
            pid = r.ppid; hops += 1
        }
        return out
    }

    // MARK: Quitting

    public struct QuitResult: Sendable {
        public let name: String
        public let ok: Bool
        public let message: String
        public let memory: UInt64
    }

    /// Why this group must not be stopped, or nil if it's fair game.
    public static func quitRefusal(_ g: AppGroup, hosts: Set<String>) -> String? {
        if hosts.contains(g.id) { return "\(g.name) is running this Claude session. Quitting it would end the conversation." }
        if let b = g.bundlePath, protectedApps.contains((b as NSString).lastPathComponent) { return "\(g.name) is part of macOS. Timber leaves it running." }
        // Apple's own apps (Music, Mail, News…) quit like any other; daemons and services don't.
        let appleApp = g.bundlePath?.hasPrefix("/System/Applications/") == true
        if g.isSystem && !appleApp { return "\(g.name) is a macOS process. Timber leaves it running." }
        if !g.ownedByUser { return "\(g.name) runs as another user (or root). Timber only stops your own processes." }
        return nil
    }

    /// Quits an app gracefully (it can ask to save), or sends SIGTERM to a non-app process group.
    /// `force` force-quits apps / sends SIGKILL.
    public static func quit(_ g: AppGroup, force: Bool, hosts: Set<String>) -> QuitResult {
        if let why = quitRefusal(g, hosts: hosts) { return QuitResult(name: g.name, ok: false, message: why, memory: 0) }
        if let bundle = g.bundlePath {
            let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == bundle }
            if !running.isEmpty {
                for app in running { _ = force ? app.forceTerminate() : app.terminate() }
                return QuitResult(name: g.name, ok: true, message: force ? "Force quit." : "Asked to quit (it may prompt to save).", memory: g.memory)
            }
        }
        var sent = 0
        for pid in g.pids where pid != getpid() { if kill(pid, force ? SIGKILL : SIGTERM) == 0 { sent += 1 } }
        return QuitResult(name: g.name, ok: sent > 0, message: sent > 0 ? "Sent \(force ? "SIGKILL" : "SIGTERM") to \(sent) process\(sent == 1 ? "" : "es")." : "Couldn't signal any of its processes.", memory: sent > 0 ? g.memory : 0)
    }

    // MARK: Startup items

    public static func startupItems() -> [LaunchItem] {
        let dirs: [(LaunchItem.Scope, String)] = [(.user, NSHomeDirectory() + "/Library/LaunchAgents"), (.agents, "/Library/LaunchAgents"), (.daemons, "/Library/LaunchDaemons")]
        var out: [LaunchItem] = []
        for (scope, dir) in dirs {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where file.hasSuffix(".plist") {
                let path = dir + "/" + file
                guard let d = NSDictionary(contentsOfFile: path) as? [String: Any] else { continue }
                let label = d["Label"] as? String ?? String(file.dropLast(6))
                let program = d["Program"] as? String ?? (d["ProgramArguments"] as? [String])?.first ?? ""
                var appPath: String?
                if let r = program.range(of: ".app/") { appPath = String(program[..<r.lowerBound]) + ".app" }
                out.append(LaunchItem(label: label, vendor: vendor(label: label, appPath: appPath), program: program, scope: scope,
                                      runAtLoad: d["RunAtLoad"] as? Bool ?? false,
                                      keepAlive: (d["KeepAlive"] as? Bool) ?? (d["KeepAlive"] is [String: Any]), path: path))
            }
        }
        return out.sorted { $0.vendor.localizedCaseInsensitiveCompare($1.vendor) == .orderedAscending }
    }

    private static func vendor(label: String, appPath: String?) -> String {
        if let appPath { return String((appPath as NSString).lastPathComponent.dropLast(4)) }
        let known: [String: String] = [
            "epicgames": "Epic Games", "valvesoftware": "Steam", "withopal": "Opal", "nordvpn": "NordVPN", "logi": "Logitech",
            "logitech": "Logitech", "displaylink": "DisplayLink", "docker": "Docker", "zoom": "Zoom", "google": "Google",
            "adobe": "Adobe", "microsoft": "Microsoft", "dropbox": "Dropbox", "elgato": "Elgato", "eyebeam": "SelfControl",
            "spotify": "Spotify", "jetbrains": "JetBrains",
        ]
        let parts = label.split(separator: ".").map(String.init)
        if parts.count >= 2, let name = known[parts[1].lowercased()] { return name }
        let prefixes: Set = ["com", "org", "io", "net", "co", "us", "de", "uk", "app", "dev", "homebrew"]
        if parts.count >= 2, prefixes.contains(parts[0].lowercased()) {
            return parts[0] == "homebrew" ? "Homebrew" : parts[1].prefix(1).uppercased() + parts[1].dropFirst()
        }
        return parts.first ?? label
    }

    // MARK: Trouble codes

    private static let browsers: Set<String> = [
        "Google Chrome", "Arc", "Brave Browser", "Microsoft Edge", "Firefox", "Opera", "Vivaldi", "Dia", "Comet", "Zen", "Safari & WebKit tabs",
    ]

    public static func diagnose(_ t: EngineReading, startup: [LaunchItem]) -> [TroubleCode] {
        var out: [TroubleCode] = []
        let userApps = t.userApps.filter { $0.name != "timber-mcp" && $0.name != "Timber" }
        var flagged = Set<String>()

        // Cylinders — CPU hogs
        for (i, a) in userApps.filter({ $0.cpu >= 25 }).sorted(by: { $0.cpu > $1.cpu }).prefix(3).enumerated() {
            flagged.insert(a.id)
            out.append(TroubleCode(
                code: "P030\(i + 1)", system: "Cylinder \(i + 1) misfire", severity: a.cpu >= 100 ? .critical : a.cpu >= 50 ? .warning : .advisory,
                title: "\(a.name) is burning \(Int(a.cpu))% CPU",
                detail: "Across \(a.count == 1 ? "a single process" : "\(a.count) processes"): \(String(format: "%.1f", a.cpu / 100)) of \(t.cores) cores. If it isn't in use, quitting it cools things down fast.",
                fix: "quit_apps \(a.name)"))
        }
        let load = t.loadAvg[0]
        if load > Double(t.cores) * 2 {
            out.append(TroubleCode(
                code: "P0300", system: "Random misfire", severity: load > Double(t.cores) * 6 ? .critical : .warning,
                title: "Run queue flooded: load \(Int(load)) on \(t.cores) cores",
                detail: "Usually a runaway script, a build or test watcher, or something spawning processes in a loop.", fix: "Check top_cpu"))
        }
        let spotlight = t.apps.filter { $0.id.hasSuffix("/mds_stores") || $0.id.hasSuffix("/mds") || $0.id.contains("mdworker") }.reduce(0) { $0 + $1.cpu }
        if spotlight > 35 {
            out.append(TroubleCode(code: "P0128", system: "Intake", severity: .advisory, title: "Spotlight is re-indexing (\(Int(spotlight))% CPU)",
                                   detail: "Normal after updates or big file moves and it finishes on its own. Excluding huge folders like node_modules from Spotlight helps.", fix: nil))
        }
        if let ws = t.apps.first(where: { $0.id.hasSuffix("/WindowServer") }), ws.cpu > 45 {
            out.append(TroubleCode(code: "P0350", system: "Ignition coil", severity: ws.cpu > 80 ? .warning : .advisory,
                                   title: "WindowServer is working overtime (\(Int(ws.cpu))%)",
                                   detail: "Lots of open windows, external displays, animated wallpapers and translucency all add load. Reduce Transparency is a quick win.", fix: nil))
        }

        // Oil — memory
        let topMem = userApps.sorted { $0.memory > $1.memory }.prefix(3)
        let memList = topMem.map { "\($0.name) (\(Fmt.gb($0.memory)))" }.joined(separator: ", ")
        if t.pressure > 0.55 || t.pressureLevel != "normal" {
            out.append(TroubleCode(code: "P0171", system: "Oil pressure", severity: t.pressure > 0.75 || t.pressureLevel == "critical" ? .critical : .warning,
                                   title: "Running lean on memory (\(Int(t.pressure * 100))% pressure)",
                                   detail: "macOS is compressing and swapping to keep up, which is what makes everything feel sticky. Biggest consumers: \(memList).",
                                   fix: "quit_apps on idle heavy apps"))
        }
        let swapGB = Double(t.swapUsed) / 1_073_741_824
        if swapGB > 1 {
            out.append(TroubleCode(code: "P0299", system: "Turbo underboost", severity: swapGB > 4 ? .warning : .advisory,
                                   title: String(format: "%.1f GB of memory spilled onto the SSD", swapGB),
                                   detail: "Swap is many times slower than RAM. Closing heavy apps helps; a restart clears it.", fix: "quit_apps on idle heavy apps"))
        }
        for (i, a) in topMem.enumerated() where a.memory > 2_500_000_000 && !flagged.contains(a.id) && !browsers.contains(a.name) {
            flagged.insert(a.id)
            out.append(TroubleCode(code: "P017\(4 + i)", system: "Payload", severity: a.memory > 5_000_000_000 ? .warning : .advisory,
                                   title: "\(a.name) is hauling \(Fmt.gb(a.memory))",
                                   detail: "That's \(Int(Double(a.memory) / Double(t.memTotal) * 100))% of RAM in one app. If it's idle, quitting hands that memory back.",
                                   fix: "quit_apps \(a.name)"))
        }
        for a in t.apps where browsers.contains(a.name) && (a.count >= 25 || a.memory > 3_000_000_000) {
            out.append(TroubleCode(code: "P0500", system: "Passengers", severity: a.memory > 6_000_000_000 ? .warning : .advisory,
                                   title: "\(a.name) is carrying \(a.count) passengers (\(Fmt.gb(a.memory)))",
                                   detail: "Every tab, extension and helper is its own process. Close tabs you aren't reading, or turn on the browser's memory saver.", fix: nil))
        }

        // Coolant
        switch t.thermal {
        case .serious, .critical:
            out.append(TroubleCode(code: "P0217", system: "Coolant", severity: .critical, title: "Overtemp: the CPU is being throttled",
                                   detail: "macOS is slowing the chip to shed heat. Find what's pinning the CPU and give the vents air.", fix: "Check top_cpu"))
        case .fair:
            out.append(TroubleCode(code: "P0216", system: "Coolant", severity: .advisory, title: "Running warm",
                                   detail: "Not throttling yet, but sustained heavy work will start to slow down.", fix: nil))
        default: break
        }

        // Fuel — disk
        if t.disk.total > 0 {
            let free = Double(t.disk.available) / Double(t.disk.total)
            if free < 0.20 || t.disk.available < 10_000_000_000 {
                out.append(TroubleCode(code: "P0087", system: "Fuel rail", severity: free < 0.10 || t.disk.available < 10_000_000_000 ? .critical : .warning,
                                       title: "Fuel low: only \(Fmt.bytes(t.disk.available)) free",
                                       detail: "macOS needs headroom for swap, caches and updates. Below ~15% free the whole system slows down.", fix: "find_deadwood, then chop"))
            }
        }

        // Ignition
        let third = startup.filter { !$0.isApple }
        if third.count > 6 {
            let vendors = Array(Set(third.map(\.vendor))).sorted().prefix(4).joined(separator: ", ")
            out.append(TroubleCode(code: "P0340", system: "Ignition timing", severity: third.count > 14 ? .warning : .advisory,
                                   title: "\(third.count) third-party items fire at startup",
                                   detail: "Updaters, helpers and sync tools from \(vendors) and others can sit in the background all day.", fix: "startup_items"))
        }

        // ECU
        let days = Int(t.uptime / 86_400)
        if days >= 5 {
            out.append(TroubleCode(code: "P0606", system: "ECU", severity: days >= 14 ? .warning : .advisory, title: "No reboot in \(days) days",
                                   detail: "Long uptimes let leaks, swap and stuck background processes pile up. A restart is the cheapest tune-up there is.", fix: "Restart the Mac"))
        }
        if t.lowPower {
            out.append(TroubleCode(code: "P0562", system: "Electrical", severity: .advisory, title: "Low Power Mode is capping output",
                                   detail: "It limits CPU and GPU clocks. Switch it off in Battery settings when you need full power.", fix: nil))
        }
        if let h = t.battery?.health, h < 0.8 {
            out.append(TroubleCode(code: "P0A7F", system: "Electrical", severity: .advisory, title: "Battery holds \(Int(h * 100))% of its original charge",
                                   detail: "Worn batteries deliver less peak power. Check Battery Health in System Settings.", fix: nil))
        }
        return out.sorted { $0.severity > $1.severity }
    }
}

extension Fmt {
    /// RAM-style size (binary GB).
    public static func gb(_ b: UInt64) -> String { String(format: "%.1f GB", Double(b) / 1_073_741_824) }

    public static func duration(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let d = m / 1440, h = (m % 1440) / 60, mm = m % 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(mm)m" }
        return "\(mm)m"
    }
}

enum Shell {
    @discardableResult
    static func run(_ exe: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

enum Sysctl {
    static func value<T>(_ name: String) -> T? {
        var size = MemoryLayout<T>.size
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<T>.alignment)
        defer { ptr.deallocate() }
        guard sysctlbyname(name, ptr, &size, nil, 0) == 0 else { return nil }
        return ptr.load(as: T.self)
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    /// Wall-clock time since boot (includes sleep).
    static func uptime() -> TimeInterval {
        guard let tv: timeval = value("kern.boottime") else { return ProcessInfo.processInfo.systemUptime }
        return Date().timeIntervalSince1970 - Double(tv.tv_sec)
    }
}
