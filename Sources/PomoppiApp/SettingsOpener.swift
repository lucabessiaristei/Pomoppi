import SwiftUI

// macOS 14+ silently broke the old
// `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)`
// trick for opening a SwiftUI `Settings` scene from AppKit: the call still
// finds a responder and returns true, but no window ever opens. The only
// supported way now is the `openSettings` environment action, which only
// exists inside a SwiftUI view — so this bridges an AppKit call (tray
// click, in-widget gear) into one via a permanently invisible, zero-size
// hosting view that reacts to a published counter.
final class SettingsOpenerModel: ObservableObject {
    @Published private(set) var requestCount = 0
    func requestOpen() { requestCount += 1 }
}

struct SettingsOpenerView: View {
    @ObservedObject var model: SettingsOpenerModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: model.requestCount) { openSettings() }
    }
}
