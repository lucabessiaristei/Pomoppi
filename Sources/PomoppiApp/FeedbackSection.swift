import AppKit
import SwiftUI
import PomoppiCore
import PomoppiStrings

// The Pomoppi tab's Feedback section (`SPEC.md`/`FEEDBACK_PLAN.md`): the
// address, a mailto: button, and the in-app "how this email is handled" sheet.
struct FeedbackSection: View {
    @State private var copied = false
    @State private var hasMailApp = true
    @State private var showingHandled = false

    private var line: FeedbackVersionLine {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var system = "macOS \(v.majorVersion).\(v.minorVersion)"
        if v.patchVersion > 0 { system += ".\(v.patchVersion)" }
        #if arch(arm64)
        let architecture = "Apple silicon"
        #else
        let architecture = "Intel"
        #endif
        return FeedbackVersionLine(version: pomoppiVersion, system: system, architecture: architecture)
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(L.t("feedback.title"))
                Text(Feedback.address)
                    .font(.title3)
                    .textSelection(.enabled)
            }
            HStack {
                if hasMailApp {
                    Button(L.t("feedback.write"), action: writeEmail)
                }
                Button(action: copyAddress) {
                    if copied {
                        Label(L.t("transfer.copied"), systemImage: "checkmark")
                            .symbolEffect(.bounce, value: copied)
                    } else {
                        Text(L.t("feedback.copyAddress"))
                    }
                }
            }
            if !hasMailApp {
                Text(L.t("feedback.noMailApp"))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L.t("feedback.lineNotice"))
                    .foregroundStyle(.secondary)
                Text(line.text)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Button(L.t("feedback.handled.link")) { showingHandled = true }
                .buttonStyle(.link)
        } header: {
            Text(L.t("feedback.header"))
        } footer: {
            Text(L.t("feedback.footer"))
        }
        .onAppear {
            hasMailApp = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "mailto:")!) != nil
        }
        .sheet(isPresented: $showingHandled) {
            FeedbackHandledSheet()
        }
    }

    private func writeEmail() {
        let template = Feedback.Template(
            happened: L.t("feedback.template.happened"),
            expected: L.t("feedback.template.expected"),
            deleteHint: L.t("feedback.template.deleteHint")
        )
        NSWorkspace.shared.open(Feedback.mailtoURL(template: template, line: line))
    }

    private func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Feedback.address, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

private struct FeedbackHandledSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.t("feedback.handled.link"))
                .font(.headline)
            Text(L.t("feedback.handled.1"))
            Text(L.t("feedback.handled.2"))
            Text(L.t("feedback.handled.3"))
            Text(L.t("feedback.handled.4"))
            Text(L.t("feedback.handled.signature"))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L.t("common.close")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .frame(width: 380)
    }
}
