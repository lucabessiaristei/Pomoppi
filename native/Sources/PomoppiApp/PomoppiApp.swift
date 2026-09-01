import SwiftUI

// SwiftUI `App` entry so Settings can be a real `Settings` scene — that's
// what gives the macOS toolbar of icon+label tabs (Safari, Mail, Xcode).
// A TabView hosted in a leftover AppKit window never gets that chrome.
//
// Widget window layering still needs AppKit (SPEC.md §9b), so the rest of
// the lifecycle stays on AppDelegate via NSApplicationDelegateAdaptor;
// this file only owns the scene graph.
@main
struct PomoppiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsRootView()
                .environmentObject(appDelegate)
        }
    }
}

private struct SettingsRootView: View {
    @EnvironmentObject private var appDelegate: AppDelegate

    var body: some View {
        if let viewModel = appDelegate.settingsViewModel {
            SettingsView(viewModel: viewModel)
        } else {
            ProgressView()
                .frame(minWidth: 520, minHeight: 360)
        }
    }
}
