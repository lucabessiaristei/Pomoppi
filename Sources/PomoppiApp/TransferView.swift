import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PomoppiCore
import PomoppiRender
import PomoppiStrings

// The Pomoppi tab's Transfer sheet (SPEC.md §16): Send builds a code from a
// snapshot of the settings and log taken when the sheet opens; Receive reads
// one from an image, the clipboard or a file and previews it before
// anything is applied.
struct TransferView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode = Mode.send

    private enum Mode { case send, receive }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                Text(L.t("transfer.mode.send")).tag(Mode.send)
                Text(L.t("transfer.mode.receive")).tag(Mode.receive)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 20)
            switch mode {
            case .send: TransferSendPane(viewModel: viewModel)
            case .receive: TransferReceivePane(viewModel: viewModel)
            }
            HStack {
                Spacer()
                Button(L.t("common.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
        .frame(minHeight: 590)
    }
}

// MARK: - Send

private struct TransferSendPane: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var settings: PomoppiSettings
    @State private var sessions: [SessionLogEntry]
    @State private var options = TransferOptions()
    @State private var encoded: Encoded?
    @State private var encodeFailed = false
    @State private var fileFailed = false
    @State private var copied = false

    private struct Encoded {
        let data: Data
        let size: TransferSize
        let qr: QRCode?
        let image: NSImage?
        let points: CGFloat
    }

    // Points per module, 2...8, as large as fits 420 pt: a whole number, so
    // the modules stay crisp (the canvas is rendered at twice that, for Retina).
    private static func moduleScale(_ code: QRCode) -> Int {
        min(8, max(2, 420 / (code.size + 2 * PixelCanvas.qrQuietZone)))
    }

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
        _settings = State(initialValue: viewModel.settings)
        _sessions = State(initialValue: viewModel.sessionLogger.allSessionsSync())
    }

    private var nothingSelected: Bool { !options.settings && !options.log }
    private var lossy: Bool { options.log && !(options.titles && options.subMinuteSkips && options.details) }

    var body: some View {
        Form {
            Section {
                Toggle(L.t("transfer.include.settings"), isOn: $options.settings)
                Toggle(L.t("transfer.include.log"), isOn: $options.log)
                Group {
                    Toggle(L.t("transfer.include.titles"), isOn: $options.titles)
                    Toggle(L.t("transfer.include.subMinute"), isOn: $options.subMinuteSkips)
                    Toggle(L.t("transfer.include.details"), isOn: $options.details)
                }
                .padding(.leading, 20)
                .disabled(!options.log)
                if lossy {
                    Text(L.t("transfer.lossyNote"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(L.t("transfer.include.header"))
            }
            Section {
                if nothingSelected {
                    Text(L.t("transfer.nothingSelected")).foregroundStyle(.secondary)
                } else if encodeFailed {
                    Text(L.t("transfer.error.encode")).foregroundStyle(.secondary)
                } else if let encoded {
                    VStack(spacing: 8) {
                        Group {
                            if let image = encoded.image {
                                Image(nsImage: image)
                                    .interpolation(.none)
                                    .resizable()
                                    .frame(width: encoded.points, height: encoded.points)
                            } else {
                                Text(L.t("transfer.tooBig.message"))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 260, height: 260)
                            }
                        }
                        Text(weightLine(encoded))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                if fileFailed {
                    Text(L.t("transfer.error.file")).foregroundStyle(.secondary)
                }
                HStack {
                    Button(copied ? L.t("transfer.copied") : L.t("transfer.copyCode"), action: copyCode)
                    Button(L.t("transfer.saveImage"), action: saveImage)
                        .disabled(encoded?.qr == nil)
                    Button(L.t("transfer.saveFile"), action: saveFile)
                }
                .disabled(encoded == nil)
                .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reencode)
        .onChange(of: options) { reencode() }
    }

    private func reencode() {
        fileFailed = false
        encoded = nil
        encodeFailed = false
        guard !nothingSelected else { return }
        guard let data = try? TransferCodec.encode(settings: settings, sessions: sessions, options: options) else {
            encodeFailed = true
            return
        }
        let qr = QRCode.encode(data)
        let module = qr.map(Self.moduleScale) ?? 0
        let image = qr.flatMap { PixelCanvas.qrCanvas($0, scale: module * 2).makeImage() }
            .map { NSImage(cgImage: $0, size: NSSize(width: $0.width / 2, height: $0.height / 2)) }
        let points = qr.map { CGFloat(($0.size + 2 * PixelCanvas.qrQuietZone) * module) } ?? 260
        encoded = Encoded(data: data, size: TransferCodec.size(of: data), qr: qr, image: image, points: points)
    }

    private func weightLine(_ encoded: Encoded) -> String {
        let bytes = "≈ " + ByteCountFormatter.string(fromByteCount: Int64(encoded.size.bytes), countStyle: .file)
        let qr = encoded.size.qrSide.map { L.t("transfer.weight.qr", $0) } ?? L.t("transfer.weight.tooBig")
        let characters = L.t("transfer.weight.characters", encoded.size.textCodeLength.formatted(.number))
        return [bytes, qr, characters].joined(separator: " · ")
    }

    private func copyCode() {
        guard let encoded else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(TransferCodec.textCode(encoded.data), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func saveImage() {
        guard let qr = encoded?.qr, let cgImage = PixelCanvas.qrCanvas(qr, scale: 8).makeImage(),
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        else { return }
        save(png, name: "Pomoppi Transfer.png", type: .png)
    }

    private func saveFile() {
        guard let encoded else { return }
        save(encoded.data, name: "Pomoppi Transfer.\(TransferCodec.fileExtension)",
             type: UTType(filenameExtension: TransferCodec.fileExtension) ?? .data)
    }

    private func save(_ data: Data, name: String, type: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            fileFailed = false
        } catch {
            fileFailed = true
        }
    }
}

// MARK: - Receive

private struct TransferReceivePane: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var payload: TransferPayload?
    @State private var errorKey: String?
    @State private var applySettings = false
    @State private var applyLog = false
    @State private var doneLines: [String]?
    @State private var targeted = false

    private var preview: (total: Int, new: Int)? {
        payload?.sessions.map {
            let p = viewModel.sessionLogger.previewImport($0)
            return (p.totalPomodoros, p.newPomodoros)
        }
    }

    private var differing: Int? {
        payload?.settings.map { TransferCodec.differingSettingsCount($0, viewModel.settings) }
    }

    var body: some View {
        Form {
            if payload != nil {
                previewSection
            } else {
                startSection
            }
        }
        .formStyle(.grouped)
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2).padding(8)
            }
        }
        .onDrop(of: [.fileURL, .plainText], isTargeted: $targeted, perform: handleDrop)
    }

    private var startSection: some View {
        Section {
            Text(L.t("transfer.receive.hint")).foregroundStyle(.secondary)
            HStack {
                Button(L.t("transfer.openImage"), action: openImage)
                Button(L.t("transfer.pasteCode"), action: pasteCode)
                Button(L.t("transfer.openFile"), action: openFile)
            }
            .frame(maxWidth: .infinity)
            if let errorKey {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.t(errorKey))
                    Text(L.t("transfer.error.nothingChanged")).foregroundStyle(.secondary)
                }
            }
            if let doneLines {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(doneLines, id: \.self) { Text($0) }
                }
            }
        }
    }

    private var previewSection: some View {
        Section {
            if let preview {
                Text(preview.total == 1
                     ? L.t("transfer.preview.pomodoros.one", preview.new)
                     : L.t("transfer.preview.pomodoros.other", preview.total, preview.new))
            } else {
                Text(L.t("transfer.preview.noLog"))
            }
            if let differing {
                Text(differing == 0 ? L.t("transfer.preview.settingsSame")
                     : differing == 1 ? L.t("transfer.preview.settings.one")
                     : L.t("transfer.preview.settings.other", differing))
            } else {
                Text(L.t("transfer.preview.noSettings"))
            }
            if let payload, payload.sessions != nil {
                if !payload.titlesIncluded {
                    Text(L.t("transfer.preview.noTitles")).font(.caption).foregroundStyle(.secondary)
                }
                if !payload.detailsIncluded {
                    Text(L.t("transfer.preview.noDetails")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if differing != nil {
                Toggle(L.t("transfer.apply.settings"), isOn: $applySettings)
            }
            if let preview {
                Toggle(L.t("transfer.apply.log"), isOn: $applyLog)
                    .disabled(preview.new == 0)
            }
            HStack {
                Button(L.t("common.cancel")) { clear() }
                Button(L.t("transfer.import"), action: importPayload)
                    .disabled(!applySettings && !applyLog)
                    .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } header: {
            Text(L.t("transfer.preview.header"))
        }
    }

    // MARK: Sources

    private func clear() {
        payload = nil
        errorKey = nil
        doneLines = nil
    }

    private func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        readImage(url)
    }

    private func pasteCode() {
        clear()
        guard let text = NSPasteboard.general.string(forType: .string) else {
            errorKey = "transfer.error.notACode"
            return
        }
        receive(text)
    }

    private func openFile() {
        let panel = NSOpenPanel()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        readFile(url)
    }

    private func readImage(_ url: URL) {
        clear()
        do {
            show(try TransferImageReader.payload(fromImageAt: url))
        } catch TransferImageReader.ReadError.noQR {
            errorKey = "transfer.error.noQR"
        } catch TransferImageReader.ReadError.unreadable {
            errorKey = "transfer.error.unreadableQR"
        } catch {
            errorKey = "transfer.error.file"
        }
    }

    // UTF-8 text starting with the code prefix is a text code (a .pomoppi
    // file someone saved from the clipboard); anything else is the raw payload.
    private func readFile(_ url: URL) {
        clear()
        guard let data = try? Data(contentsOf: url) else {
            errorKey = "transfer.error.file"
            return
        }
        if let text = String(data: data, encoding: .utf8),
           text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(TransferCodec.textPrefix) {
            receive(text)
        } else {
            show(data)
        }
    }

    private func receive(_ text: String) {
        do {
            show(try TransferCodec.data(fromTextCode: text))
        } catch {
            errorKey = "transfer.error.notACode"
        }
    }

    private func show(_ data: Data) {
        do {
            let decoded = try TransferCodec.decode(data)
            payload = decoded
            applySettings = decoded.settings.map { TransferCodec.differingSettingsCount($0, viewModel.settings) > 0 } ?? false
            applyLog = decoded.sessions.map { viewModel.sessionLogger.previewImport($0).newPomodoros > 0 } ?? false
        } catch TransferError.unsupportedVersion, TransferError.multipart {
            errorKey = "transfer.error.newerVersion"
        } catch TransferError.notACode {
            errorKey = "transfer.error.notACode"
        } catch {
            errorKey = "transfer.error.damaged"
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
                        readImage(url)
                    } else {
                        readFile(url)
                    }
                }
            }
            return true
        }
        _ = provider.loadObject(ofClass: String.self) { text, _ in
            guard let text else { return }
            DispatchQueue.main.async {
                clear()
                receive(text)
            }
        }
        return true
    }

    // MARK: Import

    private func importPayload() {
        guard let payload else { return }
        let sentSettings = applySettings ? payload.settings : nil
        let sentSessions = applyLog ? payload.sessions : nil
        Task {
            var lines: [String] = []
            if let sentSessions {
                let added = await viewModel.sessionLogger.mergeImported(sentSessions).addedPomodoros
                if added > 0 {
                    lines.append(added == 1 ? L.t("transfer.done.pomodoros.one") : L.t("transfer.done.pomodoros.other", added))
                    viewModel.onLogImported()
                }
            }
            if let sentSettings {
                viewModel.update { $0 = TransferCodec.applying(sentSettings, to: $0) }
                lines.append(L.t("transfer.done.settings"))
            }
            clear()
            doneLines = lines.isEmpty ? [L.t("transfer.done.nothing")] : lines
        }
    }
}
