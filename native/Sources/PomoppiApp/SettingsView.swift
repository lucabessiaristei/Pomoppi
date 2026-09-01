import AppKit
import SwiftUI
import PomoppiCore

// Content of the SwiftUI `Settings` scene. `Tab(_:systemImage:)` only
// becomes a preference toolbar of icons when it lives in that scene —
// not in a custom NSWindow.
struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @AppStorage("pomoppi.settingsTab") private var selectedTab = "rhythm"

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Rhythm", systemImage: "timer", value: "rhythm") {
                RhythmTab(viewModel: viewModel)
            }
            Tab("Appearance", systemImage: "paintpalette", value: "appearance") {
                AppearanceTab(viewModel: viewModel)
            }
            Tab("Window", systemImage: "macwindow", value: "window") {
                WindowTab(viewModel: viewModel)
            }
            Tab("Keys", systemImage: "keyboard", value: "keys") {
                KeysTab(viewModel: viewModel)
            }
            Tab("Sound", systemImage: "speaker.wave.2", value: "sound") {
                SoundTab(viewModel: viewModel)
            }
            Tab("Obsidian", systemImage: "book.closed", value: "obsidian") {
                ObsidianTab(viewModel: viewModel)
            }
        }
        .scenePadding()
        .frame(minWidth: 520, idealWidth: 560, minHeight: 400, idealHeight: 560)
        .onAppear(perform: disableSettingsRestoration)
    }

    // The Settings scene would otherwise restore itself at login; Pomoppi
    // only opens this window from the gear, tray, or shortcut.
    private func disableSettingsRestoration() {
        for window in NSApp.windows where window !== NSApp.mainWindow {
            if window.title.contains("Settings") || window.identifier?.rawValue.contains("Settings") == true {
                window.isRestorable = false
            }
        }
    }
}

extension SettingsViewModel {
    fileprivate func binding<T>(_ keyPath: WritableKeyPath<PomoppiSettings, T>) -> Binding<T> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { newValue in self.update { $0[keyPath: keyPath] = newValue } })
    }

    fileprivate func colorBinding(_ keyPath: WritableKeyPath<PomoppiSettings, String>) -> Binding<Color> {
        Binding(
            get: { Color(hex: self.settings[keyPath: keyPath]) },
            set: { newColor in self.update { $0[keyPath: keyPath] = newColor.toHex() } })
    }
}

private extension View {
    func settingsForm() -> some View {
        self
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Rhythm

private struct RhythmTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Stepper(
                    "Focus length: \(Int(viewModel.settings.focusMinutes)) min",
                    value: viewModel.binding(\.focusMinutes), in: 1...180, step: 1)
            } header: {
                Text("Focus")
            } footer: {
                Text("Or click the clock on the widget.")
            }
            Section {
                Stepper(
                    "Short break: \(Int(viewModel.settings.shortBreakMinutes)) min",
                    value: viewModel.binding(\.shortBreakMinutes), in: 1...180, step: 1)
                Stepper(
                    "Long break: \(Int(viewModel.settings.longBreakMinutes)) min",
                    value: viewModel.binding(\.longBreakMinutes), in: 1...180, step: 1)
                Stepper(
                    "Long break every \(viewModel.settings.longBreakEvery) sessions",
                    value: viewModel.binding(\.longBreakEvery), in: 2...10)
            } header: {
                Text("Breaks")
            } footer: {
                Text("Or click the dots on the widget.")
            }
            Section("Automation") {
                Toggle("Start breaks automatically", isOn: viewModel.binding(\.autoStartBreaks))
                Toggle("Start the next focus automatically", isOn: viewModel.binding(\.autoStartFocus))
                Toggle("Ask what I’m working on before each focus", isOn: viewModel.binding(\.askForTaskName))
            }
        }
        .settingsForm()
    }
}

// MARK: - Appearance

private struct AppearanceTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                CardPickerGrid(
                    items: PomoppiSettings.friendIDs,
                    selected: viewModel.settings.friend,
                    cardSize: CGSize(width: 48, height: 48),
                    label: { $0.capitalized },
                    image: { friend in
                        // Filled with paper first: friend art is line art
                        // ('#' ink, '.' transparent, 'w' paper highlights),
                        // so with no background of its own a light ink
                        // colour would go nearly invisible against no fill.
                        PixelPreviews.friendIcon(
                            friendID: friend, inkColor: viewModel.settings.inkColor, paperColor: viewModel.settings.paperColor)
                    },
                    onSelect: { friend in viewModel.update { $0.friend = friend } })
                Toggle("Let the pet wander back and forth", isOn: viewModel.binding(\.petMovement))
            } header: {
                Text("Pet")
            }

            Section("Theme") {
                ThemePresetPicker(viewModel: viewModel)
                ColorPicker("Ink", selection: viewModel.colorBinding(\.inkColor), supportsOpacity: false)
                ColorPicker("Paper", selection: viewModel.colorBinding(\.paperColor), supportsOpacity: false)
            }

            Section("Window edge") {
                CardPickerGrid(
                    items: PomoppiSettings.frameStyles,
                    selected: viewModel.settings.frameStyle,
                    cardSize: CGSize(width: 55, height: 62),
                    label: { $0.capitalized },
                    image: { style in
                        PixelPreviews.backgroundCard(
                            backgroundID: viewModel.settings.background, frameStyle: style,
                            inkColor: viewModel.settings.inkColor, paperColor: viewModel.settings.paperColor)
                    },
                    onSelect: { style in viewModel.update { $0.frameStyle = style } })
            }

            Section("Background") {
                CardPickerGrid(
                    items: PomoppiSettings.backgroundIDs,
                    selected: viewModel.settings.background,
                    cardSize: CGSize(width: 55, height: 62),
                    label: { $0.capitalized },
                    image: { background in
                        PixelPreviews.backgroundCard(
                            backgroundID: background, frameStyle: viewModel.settings.frameStyle,
                            inkColor: viewModel.settings.inkColor, paperColor: viewModel.settings.paperColor)
                    },
                    onSelect: { background in viewModel.update { $0.background = background } })
            }

            Section {
                Picker("Size", selection: viewModel.binding(\.scale)) {
                    ForEach([1, 2, 3, 4], id: \.self) { size in
                        Text("\(size)×").tag(size)
                    }
                }
                .pickerStyle(.segmented)
                LabeledContent("Opacity") {
                    HStack(spacing: 8) {
                        Slider(value: viewModel.binding(\.opacity), in: 0.3...1.0, step: 0.1)
                        Text("\(Int((viewModel.settings.opacity * 100).rounded()))%")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 40, alignment: .trailing)
                    }
                }
            } header: {
                Text("Size & transparency")
            } footer: {
                Text("1× is very small — 104×128 physical pixels.")
            }
        }
        .settingsForm()
    }
}

private struct CardPickerGrid<ID: Hashable>: View {
    let items: [ID]
    let selected: ID
    var cardSize: CGSize = CGSize(width: 55, height: 62)
    let label: (ID) -> String
    let image: (ID) -> NSImage?
    let onSelect: (ID) -> Void

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: max(cardSize.width, 56) + 8), spacing: 12)]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(items, id: \.self) { item in
                let isSelected = item == selected
                Button {
                    onSelect(item)
                } label: {
                    VStack(spacing: 6) {
                        cardPreview(for: item)
                            .frame(width: cardSize.width, height: cardSize.height)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
                            )
                        Text(label(item))
                            .font(.caption)
                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func cardPreview(for item: ID) -> some View {
        if let nsImage = image(item) {
            Image(nsImage: nsImage)
                .interpolation(.none)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
        }
    }
}

private struct ThemePreset {
    let name: String
    let ink: String
    let paper: String
}

private let themePresets: [ThemePreset] = [
    ThemePreset(name: "Classic", ink: "#000000", paper: "#FFFFFF"),
    ThemePreset(name: "LCD Green", ink: "#276231", paper: "#80B391"),
    ThemePreset(name: "Pine", ink: "#E0FFC2", paper: "#064734"),
    ThemePreset(name: "Midnight", ink: "#E2E8F0", paper: "#0F172A"),
    ThemePreset(name: "OLED", ink: "#FFFFFF", paper: "#000000"),
    ThemePreset(name: "Amber", ink: "#FFB000", paper: "#1A1100"),
    ThemePreset(name: "Cocoa", ink: "#2B1B12", paper: "#F4E9DC"),
    ThemePreset(name: "Berry", ink: "#FDE4ED", paper: "#3B1C2A"),
    ThemePreset(name: "Sakura", ink: "#5D2A42", paper: "#FFD6EC"),
    ThemePreset(name: "Lavender", ink: "#372856", paper: "#E8DDFF"),
    ThemePreset(name: "Mint", ink: "#1F473E", paper: "#D5F2E6"),
    ThemePreset(name: "Peach", ink: "#683525", paper: "#FFE1CF"),
]

private struct ThemePresetPicker: View {
    @ObservedObject var viewModel: SettingsViewModel

    private let columns = [GridItem(.adaptive(minimum: 56), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(themePresets, id: \.name) { preset in
                let isSelected = viewModel.settings.inkColor == preset.ink && viewModel.settings.paperColor == preset.paper
                Button {
                    viewModel.update {
                        $0.inkColor = preset.ink
                        $0.paperColor = preset.paper
                    }
                } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(hex: preset.paper))
                                .frame(width: 36, height: 36)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
                                )
                            Circle()
                                .fill(Color(hex: preset.ink))
                                .frame(width: 14, height: 14)
                        }
                        Text(preset.name)
                            .font(.caption2)
                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Window

private struct WindowTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section("Widget") {
                Toggle("Keep the widget on top of other windows", isOn: viewModel.binding(\.alwaysOnTop))
                Toggle("Pop to the front when a session ends", isOn: viewModel.binding(\.raiseOnEnd))
            }
            Section {
                Toggle("Open Pomoppi when I log in", isOn: viewModel.binding(\.launchAtLogin))
                Toggle("Start without showing the widget", isOn: viewModel.binding(\.startHidden))
            } header: {
                Text("Startup")
            } footer: {
                Text("Launch at login only registers when Pomoppi is running as an installed app. “Start hidden” applies the next time Pomoppi launches.")
            }
        }
        .settingsForm()
    }
}

// MARK: - Sound

private struct SoundTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Toggle("Play a chime when a session ends", isOn: viewModel.binding(\.soundEnabled))
                Stepper(
                    "Keep ringing for \(Int(viewModel.settings.ringSeconds)) seconds",
                    value: viewModel.binding(\.ringSeconds), in: 0...60, step: 5)
                    .disabled(!viewModel.settings.soundEnabled)
            }
        }
        .settingsForm()
    }
}

// MARK: - Obsidian

private struct ObsidianTab: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section("Logging") {
                Toggle("Log sessions to Obsidian", isOn: viewModel.binding(\.loggingEnabled))
            }
            Section("Vault") {
                LabeledContent("Vault") {
                    HStack(spacing: 8) {
                        Text(viewModel.settings.vaultPath.isEmpty ? "None chosen" : viewModel.settings.vaultPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 220, alignment: .trailing)
                        Button("Choose…", action: pickVault)
                    }
                }
                TextField("Folder", text: viewModel.binding(\.dailyNoteFolder), prompt: Text("Pomodoro"))
                TextField("Filename", text: viewModel.binding(\.dailyNoteFormat), prompt: Text("YYYY-MM-DD"))
                TextField("Heading", text: viewModel.binding(\.logHeading), prompt: Text("## Pomodoros"))
            }
            .disabled(!viewModel.settings.loggingEnabled)
            Section("What to log") {
                Toggle("Completed breaks", isOn: viewModel.binding(\.logBreaks))
                Toggle("Aborted sessions", isOn: viewModel.binding(\.logAborted))
            }
            .disabled(!viewModel.settings.loggingEnabled)
            Section {
                HStack {
                    Button(isTesting ? "Testing…" : "Test Connection", action: runTest)
                        .disabled(isTesting || !viewModel.settings.loggingEnabled)
                    if let testResult {
                        Text(testResult)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .settingsForm()
    }

    private func pickVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.update { $0.vaultPath = url.path }
    }

    private func runTest() {
        isTesting = true
        testResult = nil
        let logger = viewModel.obsidianLogger
        Task {
            let result = await logger.test()
            await MainActor.run {
                isTesting = false
                testResult = result.ok ? "Wrote to \(result.path ?? "")" : (result.error ?? "Failed")
            }
        }
    }
}

// MARK: - Keys

private struct KeysTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                ForEach(Shortcuts.actions, id: \.id) { action in
                    ShortcutRow(action: action, viewModel: viewModel)
                }
            } header: {
                Text("Global shortcuts")
            } footer: {
                Text("These fire even while Pomoppi isn’t the frontmost app. A shortcut needs a modifier; two actions can’t share the same combo.")
            }
            Section {
                Button("Reset to Defaults") {
                    viewModel.update { $0.shortcuts = Shortcuts.defaults }
                }
            }
            Section {
                ForEach(widgetKeyBindings) { binding in
                    LabeledContent(binding.action) {
                        Text(binding.keys)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("While the widget is focused")
            } footer: {
                Text("Fixed keys. They only fire while the widget window itself has focus.")
            }
        }
        .settingsForm()
    }
}

private struct WidgetKeyBinding: Identifiable {
    var id: String { keys }
    let keys: String
    let action: String
}

private let widgetKeyBindings: [WidgetKeyBinding] = [
    WidgetKeyBinding(keys: "Space / Return", action: "Start / pause"),
    WidgetKeyBinding(keys: "S", action: "Skip phase"),
    WidgetKeyBinding(keys: "R", action: "Reset phase"),
    WidgetKeyBinding(keys: "T", action: "Name what you’re working on"),
    WidgetKeyBinding(keys: "O", action: "Keep on top"),
    WidgetKeyBinding(keys: "P", action: "Save SVG snapshot"),
    WidgetKeyBinding(keys: ", or ⌘,", action: "Open settings"),
    WidgetKeyBinding(keys: "Esc", action: "Dismiss the ring, or hide the widget"),
    WidgetKeyBinding(keys: "↑ / ↓", action: "Adjust focus length, while idle"),
]

private struct ShortcutRow: View {
    let action: ShortcutAction
    @ObservedObject var viewModel: SettingsViewModel
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        LabeledContent {
            Button(action: toggleRecording) {
                Text(isRecording ? "Type shortcut" : Shortcuts.display(viewModel.settings.shortcuts[action.id] ?? ""))
                    .frame(minWidth: 120)
            }
            .buttonStyle(.bordered)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.label)
                if !action.hint.isEmpty {
                    Text(action.hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            defer { stopRecording() }
            // Escape alone cancels without changing the binding.
            if event.keyCode == 53, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                return nil
            }
            if let combo = Self.combo(for: event) {
                var shortcuts = viewModel.settings.shortcuts
                shortcuts[action.id] = combo
                viewModel.update { $0.shortcuts = shortcuts }
            }
            return nil // swallow so a captured key never types/beeps elsewhere
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static let functionKeyCodes: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    // Builds a raw accelerator string from a captured key event —
    // PomoppiSettings runs every write through Shortcuts.validate(), which
    // normalizes and resolves conflicts, so this only needs to produce
    // something Shortcuts.normalize() can parse, not a fully-canonical form.
    private static func combo(for event: NSEvent) -> String? {
        var mods: [String] = []
        if event.modifierFlags.contains(.command) { mods.append("Command") }
        if event.modifierFlags.contains(.control) { mods.append("Control") }
        if event.modifierFlags.contains(.option) { mods.append("Alt") }
        if event.modifierFlags.contains(.shift) { mods.append("Shift") }
        guard !mods.isEmpty else { return nil } // a bare key would be refused anyway

        if let name = functionKeyCodes[event.keyCode] {
            return (mods + [name]).joined(separator: "+")
        }
        if let special = event.specialKey {
            let name: String?
            switch special {
            case .upArrow: name = "Up"
            case .downArrow: name = "Down"
            case .leftArrow: name = "Left"
            case .rightArrow: name = "Right"
            case .carriageReturn, .enter: name = "Return"
            case .tab: name = "Tab"
            case .delete: name = "Backspace"
            case .deleteForward: name = "Delete"
            case .home: name = "Home"
            case .end: name = "End"
            case .pageUp: name = "PageUp"
            case .pageDown: name = "PageDown"
            default: name = nil
            }
            if let name { return (mods + [name]).joined(separator: "+") }
        }
        guard let chars = event.charactersIgnoringModifiers, let first = chars.first else { return nil }
        if first == " " { return (mods + ["Space"]).joined(separator: "+") }
        return (mods + [String(first)]).joined(separator: "+")
    }
}
