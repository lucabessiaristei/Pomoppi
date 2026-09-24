import AppKit
import SwiftUI
import PomoppiCore

// Content of the SwiftUI `Settings` scene. `Tab(_:systemImage:)` only
// becomes a preference toolbar of icons when it lives in that scene —
// not in a custom NSWindow.
struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @StateObject private var systemAppearance = SystemAppearanceObserver()
    @AppStorage("pomoppi.settingsTab") private var selectedTab = "general"

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("General", systemImage: "macwindow", value: "general") {
                GeneralTab(viewModel: viewModel)
            }
            Tab("Rhythm", systemImage: "timer", value: "rhythm") {
                RhythmTab(viewModel: viewModel)
            }
            Tab("Appearance", systemImage: "paintpalette", value: "appearance") {
                AppearanceTab(viewModel: viewModel)
            }
            Tab("Keys", systemImage: "keyboard", value: "keys") {
                KeysTab(viewModel: viewModel)
            }
            Tab("Sound", systemImage: "speaker.wave.2", value: "sound") {
                SoundTab(viewModel: viewModel)
            }
            Tab("Diary", systemImage: "book.closed", value: "diary") {
                DiaryTab(viewModel: viewModel)
            }
        }
        .scenePadding()
        .frame(minWidth: 520, idealWidth: 560, minHeight: 400, idealHeight: 560)
        .preferredColorScheme(Self.preferredColorScheme(for: viewModel.settings.colorScheme, systemIsDark: systemAppearance.isDark))
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

    // Applied here rather than at SettingsRootView's call site (PomoppiApp.swift):
    // this view's own `viewModel` is an @ObservedObject, so a live picker change
    // re-renders this body and the window follows immediately.
    //
    // "auto" used to pass `nil` here (defer to the system) — but AppKit only
    // reliably repaints a window when `.preferredColorScheme` hands it a real
    // *different concrete* value; clearing it back to nil doesn't force the
    // same redraw. Confirmed live: Dark -> Auto while the system is Light left
    // the window dark, and the "fix" (explicit Light, then Auto again) only
    // ever worked because Light already matched the system, so no repaint was
    // actually needed to look right. Resolving "auto" to a concrete value
    // ourselves — same approach as Windows' resolveDarkMode() in
    // SettingsWindow.swift, which never lets isDarkMode go "system, unresolved"
    // either — sidesteps that: every scheme, including Auto tracking a live
    // system flip via systemAppearance below, is a genuine value change AppKit
    // redraws for.
    private static func preferredColorScheme(for setting: String, systemIsDark: Bool) -> ColorScheme? {
        switch setting {
        case "light": return .light
        case "dark": return .dark
        default: return systemIsDark ? .dark : .light
        }
    }
}

// Mirrors the OS light/dark setting via KVO on NSApp.effectiveAppearance —
// the officially recommended way to observe app-wide appearance changes
// (WWDC 2018 "Dark Mode"), and safe here since nothing in this app ever sets
// NSApp.appearance itself, so effectiveAppearance always tracks the system.
// Backs SettingsView.preferredColorScheme(for:systemIsDark:) above.
private final class SystemAppearanceObserver: ObservableObject {
    @Published private(set) var isDark: Bool
    private var observation: NSKeyValueObservation?

    init() {
        isDark = Self.currentIsDark()
        observation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            self?.isDark = Self.currentIsDark()
        }
    }

    private static func currentIsDark() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
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
                    "Default focus length: \(Int(viewModel.settings.focusMinutes)) min",
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
            Section {
                Toggle("Start breaks automatically", isOn: viewModel.binding(\.autoStartBreaks))
                Toggle("Start the next focus automatically", isOn: viewModel.binding(\.autoStartFocus))
                Toggle("Ask what I’m working on before each focus", isOn: viewModel.binding(\.askForTaskName))
            } header: {
                Text("Automation")
            } footer: {
                Text(viewModel.settings.loggingEnabled
                    ? "Session logging is on, so Pomoppi always asks — this setting only applies while logging is off."
                    : "Pomoppi asks before each focus session. Leave it blank to skip.")
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
                    alignment: .leading,
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
            } header: {
                Text("Roommate")
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
                        PixelPreviews.frameEdgeCard(
                            frameStyle: style,
                            inkColor: viewModel.settings.inkColor, paperColor: viewModel.settings.paperColor)
                    },
                    onSelect: { style in viewModel.update { $0.frameStyle = style } })
            }

            Section("Background") {
                CardPickerGrid(
                    items: PomoppiSettings.backgroundIDs,
                    selected: viewModel.settings.background,
                    // Wider/shorter than the frame-edge cards above: this
                    // preview crops to the top half of the frame, full
                    // width (see PixelPreviews.backgroundPatternCard), so
                    // its aspect ratio is ~110:62 rather than ~55:62.
                    cardSize: CGSize(width: 74, height: 42),
                    label: { $0.capitalized },
                    image: { background in
                        PixelPreviews.backgroundPatternCard(
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
    // Applies to both the grid's own column alignment and each button's
    // inner VStack — the two must move together. `.center` (the default):
    // each button's VStack is only as wide as its widest child, and the
    // label text below often outgrows the fixed-size image above it by a
    // different amount per item, so centering both the grid column and the
    // VStack keeps every image on the same axis regardless of label width.
    // `.leading` pins both the grid column and the VStack's children to the
    // same edge instead, so image and label share one left edge per item —
    // mixing the two (grid `.leading` with VStack `.center`, or vice versa)
    // is what causes the zigzag, since the image would then be centred
    // inside a variable-width, edge-anchored button.
    var alignment: HorizontalAlignment = .center
    let label: (ID) -> String
    let image: (ID) -> NSImage?
    let onSelect: (ID) -> Void

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: max(cardSize.width, 56) + 8), spacing: 12)]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: alignment, spacing: 12) {
            ForEach(items, id: \.self) { item in
                let isSelected = item == selected
                Button {
                    onSelect(item)
                } label: {
                    VStack(alignment: alignment, spacing: 6) {
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
    ThemePreset(name: "Sakura", ink: "#5D2A42", paper: "#FFD6EC"),
    ThemePreset(name: "Lavender", ink: "#372856", paper: "#E8DDFF"),
    ThemePreset(name: "Mint", ink: "#1F473E", paper: "#D5F2E6"),
    ThemePreset(name: "Peach", ink: "#683525", paper: "#FFE1CF"),
]

private struct ThemePresetPicker: View {
    @ObservedObject var viewModel: SettingsViewModel

    private let columns = [GridItem(.adaptive(minimum: 56), spacing: 10)]

    var body: some View {
        // Same fix as CardPickerGrid: centre each item on its column so the
        // swatch aligns the same way regardless of preset-name width.
        LazyVGrid(columns: columns, alignment: .center, spacing: 10) {
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

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showingResetConfirmation = false

    var body: some View {
        Form {
            Section("Color scheme") {
                Picker("Color scheme", selection: viewModel.binding(\.colorScheme)) {
                    Text("Auto").tag("auto")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Section("Widget") {
                Toggle("Keep the widget on top of other windows", isOn: viewModel.binding(\.alwaysOnTop))
                Toggle("Pop to the front when a session ends", isOn: viewModel.binding(\.raiseOnEnd))
            }
            Section {
                Toggle("Swap the menu bar icon's left and right clicks", isOn: viewModel.binding(\.reverseTrayClick))
            } footer: {
                Text(viewModel.settings.reverseTrayClick
                    ? "Left-click opens the menu, right-click raises the widget."
                    : "Left-click raises the widget, right-click opens the menu.")
            }
            Section {
                Toggle("Open Pomoppi when I log in", isOn: viewModel.binding(\.launchAtLogin))
                Toggle("Start without showing the widget", isOn: viewModel.binding(\.startHidden))
            } header: {
                Text("Startup")
            } footer: {
                Text("Launch at login only registers when Pomoppi is running as an installed app. “Start hidden” applies the next time Pomoppi launches.")
            }
            Section {
                Toggle("Automatically check for updates", isOn: viewModel.binding(\.checkForUpdates))
                UpdateStatusRow(updateChecker: viewModel.updateChecker)
            } header: {
                Text("Updates")
            } footer: {
                Text("Checks lucabessiaristei/Pomoppi on GitHub roughly once a day.")
            }
            Section {
                Button("Reset Pomoppi…", role: .destructive) {
                    showingResetConfirmation = true
                }
            } header: {
                Text("Reset")
            } footer: {
                Text("Erases every setting and your whole session history, and puts Pomoppi back to how it shipped.")
            }
        }
        .settingsForm()
        .confirmationDialog(
            "Reset Pomoppi to defaults?",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset to Defaults", role: .destructive) {
                viewModel.resetToDefaults()
            }
        } message: {
            Text("This erases all settings and session history.")
        }
    }
}

// The General tab's Updates section own version/check-for-updates row
// (release/update plan, phase R6a; moved off the page-wide footer into
// here). `@ObservedObject` on updateChecker itself, not just viewModel: a
// background check that resolves while the window is already open (or a
// manual check firing while this tab isn't the visible one) both need to
// redraw this without the user touching anything.
private struct UpdateStatusRow: View {
    @ObservedObject var updateChecker: AppUpdateChecker
    @State private var manualState: ManualCheckState = .idle
    @State private var resetToIdleTask: DispatchWorkItem?

    private enum ManualCheckState {
        case idle, checking, upToDate, failed
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("Pomoppi \(pomoppiVersion)")
            Text("·")
            actionView
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var actionView: some View {
        // An update found in the background takes priority over whatever
        // the manual-check state machine below is doing, except mid-check
        // (so a click doesn't flash straight past "Checking…").
        if case .updateAvailable(let tag, let pageURL) = updateChecker.latestResult, manualState != .checking {
            Button("Update available: \(tag) — Download") {
                NSWorkspace.shared.open(pageURL)
            }
            .buttonStyle(.link)
        } else {
            switch manualState {
            case .checking:
                Text("Checking…")
            case .upToDate:
                Text("Up to date")
            case .failed:
                Button("Couldn't check — try again", action: checkNow)
                    .buttonStyle(.link)
            case .idle:
                Button("Check for updates", action: checkNow)
                    .buttonStyle(.link)
            }
        }
    }

    private func checkNow() {
        resetToIdleTask?.cancel()
        manualState = .checking
        updateChecker.checkExplicitly { result in
            switch result {
            case .success(.updateAvailable):
                manualState = .idle
            case .success(.noUpdate):
                manualState = .upToDate
                let task = DispatchWorkItem { manualState = .idle }
                resetToIdleTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: task)
            case .failure:
                manualState = .failed
            }
        }
    }
}

// MARK: - Sound

private struct SoundTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Toggle("Play a chime when a session ends", isOn: viewModel.binding(\.soundEnabled))
                LabeledContent("Chime") {
                    Picker("Chime", selection: viewModel.binding(\.chime)) {
                        ForEach(PomoppiSettings.chimeIDs, id: \.self) { id in
                            Text(id.capitalized).tag(id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    // Selecting a chime previews it immediately — "tap it,
                    // hear it". No separate Play/replay control: a
                    // segmented Picker's selection binding doesn't fire on
                    // a reselect of the already-selected segment, so
                    // re-hearing the current chime means picking another
                    // option and back, same as any other segmented control
                    // here.
                    .onChange(of: viewModel.settings.chime) {
                        viewModel.chimePlayer.play(chime: viewModel.settings.chime, focusEnd: true)
                    }
                }
                Stepper(
                    ringLabel,
                    value: viewModel.binding(\.ringSeconds), in: 0...60, step: 5)
            } footer: {
                Text("Selecting a chime plays it.")
            }
        }
        .settingsForm()
    }

    // ringSeconds governs the visual ring only, never audio (SPEC.md §4),
    // so this stays enabled regardless of soundEnabled.
    private var ringLabel: String {
        let seconds = Int(viewModel.settings.ringSeconds)
        return seconds == 0 ? "Don't ring" : "Keep ringing for \(seconds) seconds"
    }
}

// MARK: - Diary

// Merged Log into Diary (2026-09-20 redesign, SPEC.md §8/§8b): one tab,
// three sections top to bottom — Session history (moved verbatim from the
// old Log tab), Export (now a `.zip` of per-day files, the same shape Sync
// writes), Sync to folder (idempotent, no cursor — Erase below no longer
// touches one either).
private struct DiaryTab: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var historySizeBytes: Int64 = 0
    @State private var showingEraseConfirmation = false
    @State private var sessionCount = 0
    @State private var exportStatus: String?
    @State private var syncStatus: String?

    var body: some View {
        Form {
            Section {
                Toggle("Record every session", isOn: viewModel.binding(\.loggingEnabled))
                LabeledContent("History size", value: Self.formattedSize(historySizeBytes))
                Button("Erase History…", role: .destructive) {
                    showingEraseConfirmation = true
                }
            } header: {
                Text("Session history")
            } footer: {
                Text("Pomoppi's own record of every session, kept on this computer. Erasing it can't be undone.")
            }
            Section("Export") {
                LabeledContent("Sessions recorded", value: "\(sessionCount)")
                Button("Export Diary…") { exportDiary() }
                if let exportStatus {
                    Text(exportStatus).foregroundStyle(.secondary)
                }
            }
            Section("Sync to folder") {
                LabeledContent("Diary folder") {
                    Text(folderDisplayPath)
                        .foregroundStyle(viewModel.settings.diaryFolderPath.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Button("Choose…") { chooseFolder() }
                Button("Sync Now") { syncNow() }
                    .disabled(viewModel.settings.diaryFolderPath.isEmpty)
                if let syncStatus {
                    Text(syncStatus).foregroundStyle(.secondary)
                }
            }
        }
        .settingsForm()
        .task {
            await refreshHistorySize()
            refreshCount()
        }
        .confirmationDialog(
            "Erase all session history?",
            isPresented: $showingEraseConfirmation,
            titleVisibility: .visible
        ) {
            Button("Erase History", role: .destructive) {
                Task {
                    await viewModel.sessionLogger.eraseAll()
                    await refreshHistorySize()
                    refreshCount()
                }
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    private func refreshHistorySize() async {
        historySizeBytes = viewModel.sessionLogger.fileSizeBytes()
    }

    private static func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var folderDisplayPath: String {
        viewModel.settings.diaryFolderPath.isEmpty ? "Not set" : viewModel.settings.diaryFolderPath
    }

    private func refreshCount() {
        sessionCount = viewModel.sessionLogger.allSessionsSync().count
    }

    private func exportDiary() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Pomoppi Diary.zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let zipData = DiaryExporter.exportZip(sessions: viewModel.sessionLogger.allSessionsSync())
        do {
            try zipData.write(to: url, options: .atomic)
            exportStatus = "Exported to \(url.lastPathComponent)."
        } catch {
            exportStatus = "Export failed."
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.update { $0.diaryFolderPath = url.path }
        syncStatus = nil
    }

    private func syncNow() {
        let allSessions = viewModel.sessionLogger.allSessionsSync()
        let folderURL = URL(fileURLWithPath: viewModel.settings.diaryFolderPath)
        do {
            let written = try DiaryExporter.syncToFolder(folderURL, sessions: allSessions)
            syncStatus = written == 0 ? "Up to date." : "Added \(written) session\(written == 1 ? "" : "s")."
        } catch {
            syncStatus = "Sync failed."
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
                Button("Restore Default Shortcuts") {
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
