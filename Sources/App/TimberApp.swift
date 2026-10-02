import SwiftUI

@main
struct TimberApp: App {
    @State private var model = ForestModel.shared
    @AppStorage("skyMode") private var skyMode = "auto"
    @State private var clock = Date()

    var body: some Scene {
        WindowGroup("Timber", id: "forest") {
            RootView()
                .environment(model)
                .environment(\.palette, Palette.current(mode: skyMode, date: clock))
                .frame(minWidth: 1100, minHeight: 680)
                .onReceive(Timer.publish(every: 300, on: .main, in: .common).autoconnect()) { clock = $0 }
                .onAppear {
                    autoStartIfRequested()
                    #if DEBUG
                    DevHarness.startIfRequested()
                    #endif
                    Telemetry.track("app_opened")
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Survey Home Folder") { model.startScan(URL(fileURLWithPath: NSHomeDirectory())) }
                    .keyboardShortcut("n")
                Button("Survey Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o")
                Button("Replay Survey") { model.replaySurvey() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(model.root == nil)
                Button("Back to Welcome Screen") { model.backToWelcome() }
                    .disabled(model.phase == .welcome)
                Button("Survey Again") { model.rescan() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.root == nil)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo Chop") { model.undo() }
                    .keyboardShortcut("z")
                    .disabled(model.undoStack.isEmpty)
            }
            CommandMenu("Forest") {
                Button("Chop") { if let s = model.selected { model.requestChop(s) } }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selected == nil)
                Button("Walk In") { if let s = model.selected { model.enter(s) } }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    .disabled(model.selected == nil)
                Button("Back Up the Trail") { model.back() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(model.trail.count <= 1)
                Divider()
                Button("Ask the Ranger") { model.surveyGrove() }
                    .keyboardShortcut("r")
                    .disabled(model.current == nil)
                Button(model.showDeadwood ? "Hide Deadwood" : "Show Deadwood") {
                    withAnimation(.spring(duration: 0.4)) { model.showDeadwood.toggle() }
                }
                .keyboardShortcut("1")
                Divider()
                Button("Open Trash") { model.openTrash() }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }

    /// `TIMBER_AUTOSCAN=/path` jumps straight into a survey (handy for demos and testing).
    private func autoStartIfRequested() {
        if let p = ProcessInfo.processInfo.environment["TIMBER_AUTOSCAN"], model.phase == .welcome {
            model.startScan(URL(fileURLWithPath: (p as NSString).expandingTildeInPath))
        }
    }
}

struct RootView: View {
    @Environment(ForestModel.self) private var model
    @Environment(\.palette) private var pal

    var body: some View {
        ZStack {
            switch model.phase {
            case .welcome:
                WelcomeScreen().transition(.opacity)
            case .scanning:
                ScanningScreen().transition(.opacity)
            case .forest:
                ForestScreen().transition(.opacity.combined(with: .scale(scale: 1.03)))
            }
        }
        .ignoresSafeArea()
        .background(Color(hex: 0x0D1D14))
        .preferredColorScheme(pal.isNight ? .dark : .light)
    }
}

// MARK: - Settings

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            RangerSettings().tabItem { Label("Ranger", systemImage: "binoculars") }
            ClaudeSettings().tabItem { Label("Claude", systemImage: "sparkles") }
        }
        .frame(width: 560)
        .padding(20)
    }
}

struct GeneralSettings: View {
    @AppStorage("soundOn") private var soundOn = true
    @AppStorage("skyMode") private var skyMode = "auto"
    var body: some View {
        Form {
            Toggle("Play sounds", isOn: $soundOn)
                .onChange(of: soundOn) { _, on in if on { SoundBoard.shared.play(.thunk) } }
            Picker("Sky", selection: $skyMode) {
                Text("Follow the clock").tag("auto")
                Text("Dawn").tag("dawn")
                Text("Day").tag("day")
                Text("Dusk").tag("dusk")
                Text("Night").tag("night")
            }
            Toggle(isOn: Binding(get: { Telemetry.enabled }, set: { Telemetry.enabled = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share anonymous usage stats")
                    Text("Counts and size ranges only, like “a 1–10 GB cache was chopped”. Never file names, paths or anything about what's on your disk.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Safety") {
                Text("Timber never deletes anything. Chopped items go to the Trash, and it refuses to chop system folders, keys, settings and your top-level personal folders.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("Full Disk Access") {
                Button("Open Privacy Settings") { ForestModel.shared.openFullDiskAccess() }
            }
        }
        .formStyle(.grouped)
    }
}

struct RangerSettings: View {
    @AppStorage("jevModel") private var model = JevClient.defaultModel
    @AppStorage("autoRanger") private var autoRanger = false
    @State private var key = ""
    @State private var saved = Keychain.read() != nil
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                Text("The Ranger uses TypeSafe's **Jev** model to paint marks on trees: orange to fell, gold to look first, blue to keep. Only names, sizes and dates are sent — never file contents.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("TypeSafe API key") {
                HStack {
                    SecureField(saved ? "Saved in your Keychain" : "ts-…", text: $key)
                    Button("Save") {
                        Keychain.write(key.trimmingCharacters(in: .whitespacesAndNewlines))
                        key = ""
                        saved = Keychain.read() != nil
                    }
                    .disabled(key.isEmpty)
                    if saved {
                        Button("Remove", role: .destructive) { Keychain.write(nil); saved = false }
                    }
                }
                if ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] != nil {
                    Label("Using TYPESAFE_API_KEY from the environment.", systemImage: "terminal").foregroundStyle(.secondary)
                }
                HStack {
                    Button(testing ? "Testing…" : "Test the Ranger") { test() }.disabled(testing)
                    if let testResult { Text(testResult).foregroundStyle(.secondary) }
                }
            }
            Section("Behaviour") {
                TextField("Model", text: $model)
                Toggle("Survey each new forest automatically", isOn: $autoRanger)
            }
        }
        .formStyle(.grouped)
    }

    private func test() {
        guard let client = JevClient.fromEnvironmentOrKeychain(model: model) else { testResult = "No key yet."; return }
        testing = true
        let cache = NSHomeDirectory() + "/Library/Caches"
        let n = Node(path: cache, isDirectory: true)
        Task {
            do {
                let v = try await Ranger.judge(RangerItem(node: n, finding: nil), client: client)
                testResult = "✓ Jev says ~/Library/Caches is “\(v.categoryLabel)”."
            } catch {
                testResult = error.localizedDescription
            }
            testing = false
        }
    }
}

struct ClaudeSettings: View {
    @State private var copied: String?

    private var helper: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/timber-mcp").path
    }
    private var cliCommand: String { "claude mcp add timber -s user -- '\(helper)'" }
    private var desktopJSON: String {
        """
        {
          "mcpServers": {
            "timber": {
              "command": "\(helper)",
              "env": { "TYPESAFE_API_KEY": "<your key, optional>" }
            }
          }
        }
        """
    }

    var body: some View {
        Form {
            Section {
                Text("Timber ships with an MCP server so Claude can survey your disk, find deadwood, ask the Ranger and chop — with your say-so. Try asking Claude: *“Use Timber to find me 20 GB.”*")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Claude Code") {
                snippet(cliCommand, id: "cli")
                Text("Add `-e TYPESAFE_API_KEY=…` before `--` to let Claude use the Ranger too.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Claude Desktop (claude_desktop_config.json)") {
                snippet(desktopJSON, id: "desktop")
            }
            Section("Privacy") {
                Text("The MCP server runs entirely on your Mac. It never phones home. Only Jev (if you give it a key) sees names and sizes.")
                    .foregroundStyle(.secondary)
            }
            Section("Tools Claude gets") {
                Text("disk_overview · survey · find_deadwood · ranger · chop · restore, plus a **clear_space** prompt.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func snippet(_ text: String, id: String) -> some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied == id ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = id
            }
        }
    }
}
