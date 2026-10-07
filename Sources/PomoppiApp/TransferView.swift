import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PomoppiCore
import PomoppiRender
import PomoppiSprites
import PomoppiStrings

// The Transfer window's content (SPEC.md §16): Send builds a code from a
// snapshot of the settings and log taken when the window opens; Receive reads
// one from an image, the clipboard or a file and previews it before anything
// is applied. The middle scrolls (with edge fades); the bottom bar is pinned.
struct TransferView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var mode = Mode.send
    @State private var canScrollUp = false
    @State private var canScrollDown = false
    @State private var viewportHeight: CGFloat = 0

    // Send
    @State private var settings: PomoppiSettings
    @State private var sessions: [SessionLogEntry]
    @State private var options = TransferOptions()
    @State private var encoded: Encoded?
    @State private var revision = 0
    @State private var encodeFailed = false
    @State private var fileFailed = false
    @State private var copied = false

    // Receive
    @State private var payload: TransferPayload?
    @State private var errorKey: String?
    @State private var applySettings = false
    @State private var applyLog = false
    @State private var doneLines: [String]?
    @State private var targeted = false
    @State private var reading = false
    @State private var shakes = 0

    private enum Mode { case send, receive }

    private struct Encoded {
        let data: Data
        let size: TransferSize
        let qr: QRCode?
        let image: NSImage?
        let points: CGFloat
    }

    private let fadeHeight: CGFloat = 24

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
        _settings = State(initialValue: viewModel.settings)
        _sessions = State(initialValue: viewModel.sessionLogger.allSessionsSync())
    }

    // Spring that collapses to a plain fade-less snap under Reduce Motion.
    private var spring: Animation? { reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.2) }
    private var fade: Animation { .easeInOut(duration: 0.2) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode.animation(spring ?? fade)) {
                Text(L.t("transfer.mode.send")).tag(Mode.send)
                Text(L.t("transfer.mode.receive")).tag(Mode.receive)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            scrollArea
            bottomBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: reencode)
        .onChange(of: options) { reencode() }
        // Send re-reads the settings and log each time it's shown, so an
        // import (or a Settings change) since the window opened is in its code.
        .onChange(of: mode) { _, newMode in
            guard newMode == .send else { return }
            settings = viewModel.settings
            sessions = viewModel.sessionLogger.allSessionsSync()
            reencode()
        }
        .onDrop(of: [.fileURL, .plainText], isTargeted: $targeted.animation(spring), perform: handleDrop)
    }

    // MARK: Scroll area

    private var scrollArea: some View {
        ScrollView {
            Group {
                switch mode {
                case .send: sendContent.transition(slide(-1))
                case .receive: receiveContent.transition(slide(1))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
        .onScrollGeometryChange(for: ScrollEdges.self) { geometry in
            let maxOffset = geometry.contentSize.height - geometry.containerSize.height
            return ScrollEdges(
                up: geometry.contentOffset.y > 1, down: geometry.contentOffset.y < maxOffset - 1,
                height: geometry.containerSize.height)
        } action: { _, edges in
            canScrollUp = edges.up
            canScrollDown = edges.down
            viewportHeight = edges.height
        }
        // An edge only fades while there's more content past it; otherwise
        // it stays fully opaque, so nothing is cut off at rest. The scroller's
        // strip on the right is never masked.
        .mask {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    LinearGradient(colors: [canScrollUp ? .clear : .black, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: fadeHeight)
                    Color.black
                    LinearGradient(colors: [.black, canScrollDown ? .clear : .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: fadeHeight)
                }
                Color.black.frame(width: 16)
            }
            .animation(fade, value: canScrollUp)
            .animation(fade, value: canScrollDown)
        }
    }

    private struct ScrollEdges: Equatable {
        let up: Bool
        let down: Bool
        let height: CGFloat
    }

    private func slide(_ direction: CGFloat) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(x: 24 * direction))
    }

    // MARK: Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        if mode == .send || payload != nil {
            VStack(spacing: 10) {
                Divider()
                if mode == .send { sendBar } else { previewBar }
            }
            .padding(.bottom, 14)
            .transition(.opacity)
        }
    }

    // MARK: - Send

    private var nothingSelected: Bool { !options.settings && !options.log }
    private var lossy: Bool { options.log && !(options.titles && options.subMinuteSkips && options.details) }

    private var sendContent: some View {
        VStack(spacing: 14) {
            qrCard
            Text(L.t("transfer.send.hint"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            includeBox
            if fileFailed {
                Text(L.t("transfer.error.file")).font(.callout).foregroundStyle(.red)
            }
        }
    }

    private var qrCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white)
            if nothingSelected {
                cardMessage(L.t("transfer.nothingSelected"))
            } else if encodeFailed {
                cardMessage(L.t("transfer.error.encode"))
            } else if let encoded {
                if let image = encoded.image {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: encoded.points, height: encoded.points)
                        .id(revision)
                        .transition(.opacity)
                } else {
                    cardMessage(L.t("transfer.tooBig.message"))
                        .id(revision)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: 300 + 0, height: 300)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .accessibilityLabel(L.t("transfer.mode.send"))
    }

    private func cardMessage(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(Color.black.opacity(0.6))
            .multilineTextAlignment(.center)
            .padding(24)
    }

    private var includeBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.t("transfer.include.header")).font(.headline)
            Toggle(L.t("transfer.include.settings"), isOn: $options.settings)
            Toggle(L.t("transfer.include.log"), isOn: $options.log)
            if options.log {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(L.t("transfer.include.titles"), isOn: $options.titles)
                    Toggle(L.t("transfer.include.subMinute"), isOn: $options.subMinuteSkips)
                    Toggle(L.t("transfer.include.details"), isOn: $options.details)
                }
                .padding(.leading, 20)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
            if lossy {
                Text(L.t("transfer.lossyNote"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .toggleStyle(.checkbox)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))
        .clipped()
        .animation(spring ?? fade, value: options.log)
        .animation(fade, value: lossy)
    }

    private var sendBar: some View {
        VStack(spacing: 10) {
            if let encoded {
                Text(weightLine(encoded))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(fade, value: weightLine(encoded))
            }
            HStack {
                Button(action: copyCode) {
                    if copied {
                        Label(L.t("transfer.copied"), systemImage: "checkmark")
                            .symbolEffect(.bounce, value: copied)
                    } else {
                        Text(L.t("transfer.copyCode"))
                    }
                }
                Button(L.t("transfer.saveImage"), action: saveImage)
                    .disabled(encoded?.qr == nil)
                Button(L.t("transfer.saveFile"), action: saveFile)
            }
            .disabled(encoded == nil)
        }
        .padding(.horizontal, 20)
    }

    private func reencode() {
        fileFailed = false
        encodeFailed = false
        var next: Encoded?
        if !nothingSelected {
            if let data = try? TransferCodec.encode(settings: settings, sessions: sessions, options: options) {
                let qr = QRCode.encode(data)
                let module = qr.map(Self.moduleScale) ?? 0
                let image = qr.flatMap { PixelCanvas.qrCanvas($0, scale: module * 2).makeImage() }
                    .map { NSImage(cgImage: $0, size: NSSize(width: $0.width / 2, height: $0.height / 2)) }
                let points = qr.map { CGFloat(($0.size + 2 * PixelCanvas.qrQuietZone) * module) } ?? 0
                next = Encoded(data: data, size: TransferCodec.size(of: data), qr: qr, image: image, points: points)
            } else {
                encodeFailed = true
            }
        }
        withAnimation(fade) {
            revision += 1
            encoded = next
        }
    }

    // Points per module, 2...8, as large as fits the 300 pt card minus its
    // margin: a whole number, so the modules stay crisp (the canvas is
    // rendered at twice that, for Retina).
    private static func moduleScale(_ code: QRCode) -> Int {
        min(8, max(2, 276 / (code.size + 2 * PixelCanvas.qrQuietZone)))
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

    // The text code, not the raw bytes: a .pomoppi file is the same string
    // Copy code puts on the clipboard.
    private func saveFile() {
        guard let encoded else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        save(Data(TransferCodec.textCode(encoded.data).utf8),
             name: "transfer-\(formatter.string(from: Date())).\(TransferCodec.fileExtension)",
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

    // MARK: - Receive

    private var preview: (total: Int, new: Int)? {
        payload?.sessions.map {
            let p = viewModel.sessionLogger.previewImport($0)
            return (p.totalPomodoros, p.newPomodoros)
        }
    }

    private var differing: Int? {
        payload?.settings.map { TransferCodec.differingSettingsCount($0, viewModel.settings) }
    }

    private var receiveContent: some View {
        VStack(spacing: 14) {
            if let doneLines {
                successCard(doneLines)
                    .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.92)))
            }
            if payload != nil {
                previewCard
                    .transition(.opacity)
            } else {
                dropZone
                    .modifier(Shake(travel: reduceMotion ? 0 : 8, animatableData: CGFloat(shakes)))
                    .transition(.opacity)
                if let errorKey {
                    VStack(spacing: 2) {
                        Text(L.t(errorKey)).foregroundStyle(.red)
                        Text(L.t("transfer.error.nothingChanged")).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
                }
            }
        }
        // Fills the visible height (minus the scroll area's vertical
        // padding) so the drop zone stretches with the window.
        .frame(minHeight: max(0, viewportHeight - 24), alignment: .top)
        .animation(spring ?? fade, value: payload != nil)
        .animation(fade, value: errorKey)
        .animation(fade, value: doneLines)
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            dropIcon
                .offset(y: targeted && !reduceMotion ? -6 : 0)
                .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.5), value: targeted)
            Text(L.t("transfer.drop.title")).font(.title3.weight(.semibold))
            Text(L.t("transfer.drop.hint"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if reading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L.t("transfer.reading")).foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            } else {
                Text(L.t("transfer.drop.or")).font(.callout).foregroundStyle(.tertiary)
                HStack {
                    Button(L.t("transfer.openFile"), action: openFile)
                    Button(L.t("transfer.pasteCode"), action: pasteCode)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(targeted ? Color.accentColor.opacity(0.08) : Color.clear))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.5),
                              style: StrokeStyle(lineWidth: targeted ? 2.5 : 1.5, dash: [7, 5])))
        .scaleEffect(targeted && !reduceMotion ? 1.02 : 1)
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.3), value: targeted)
        .disabled(reading)
    }

    // Gemuppin's line art alone (no theme colours, no backdrop), in the
    // system's secondary gray, idling through its frames.
    @ViewBuilder
    private var dropIcon: some View {
        let frames = DropCritter.frames
        if frames.isEmpty {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
        } else {
            TimelineView(.periodic(from: .now, by: 0.6)) { context in
                let index = reduceMotion ? 0 : Int(context.date.timeIntervalSinceReferenceDate / 0.6) % frames.count
                Image(nsImage: frames[index])
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func successCard(_ lines: [String]) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: lines)
            ForEach(lines, id: \.self) { Text($0).contentTransition(.numericText()) }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.green.opacity(0.1)))
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.t("transfer.preview.header")).font(.headline)
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
            // Nothing new: no checkbox, "N pomodoros (0 new)" already says it.
            if let preview, preview.new > 0 {
                Toggle(L.t("transfer.apply.log"), isOn: $applyLog)
            }
        }
        .toggleStyle(.checkbox)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))
    }

    private var previewBar: some View {
        HStack {
            Spacer()
            Button(L.t("common.cancel")) { clear() }
                .keyboardShortcut(.cancelAction)
            Button(L.t("transfer.import"), action: importPayload)
                .disabled(!applySettings && !applyLog)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
    }

    // MARK: Sources

    private func clear() {
        payload = nil
        errorKey = nil
        doneLines = nil
    }

    private func fail(_ key: String) {
        errorKey = key
        if !reduceMotion {
            withAnimation(.linear(duration: 0.35)) { shakes += 1 }
        }
    }

    private func pasteCode() {
        clear()
        guard let text = NSPasteboard.general.string(forType: .string) else {
            fail("transfer.error.notACode")
            return
        }
        receive(text)
    }

    // One button for both: a QR image goes to the image reader, anything
    // else (a .pomoppi file) is read as a code.
    private func openFile() {
        let panel = NSOpenPanel()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        readAny(url)
    }

    private func readAny(_ url: URL) {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
            readImage(url)
        } else {
            readFile(url)
        }
    }

    // Decoding a photo can take a moment (Vision, then the fallback decoder),
    // so it runs off the main thread with a spinner in the drop zone.
    private func readImage(_ url: URL) {
        clear()
        reading = true
        Task {
            let result = await Task.detached { () -> Result<Data, TransferImageReader.ReadError> in
                do {
                    return .success(try TransferImageReader.payload(fromImageAt: url))
                } catch let error as TransferImageReader.ReadError {
                    return .failure(error)
                } catch {
                    return .failure(.file)
                }
            }.value
            reading = false
            switch result {
            case .success(let data): show(data)
            case .failure(.noQR): fail("transfer.error.noQR")
            case .failure(.unreadable): fail("transfer.error.unreadableQR")
            case .failure(.file): fail("transfer.error.file")
            }
        }
    }

    // UTF-8 text starting with the code prefix is a text code (what Save file
    // writes); anything else is the raw payload.
    private func readFile(_ url: URL) {
        clear()
        guard let data = try? Data(contentsOf: url) else {
            fail("transfer.error.file")
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
            fail("transfer.error.notACode")
        }
    }

    private func show(_ data: Data) {
        do {
            let decoded = try TransferCodec.decode(data)
            payload = decoded
            applySettings = decoded.settings.map { TransferCodec.differingSettingsCount($0, viewModel.settings) > 0 } ?? false
            applyLog = decoded.sessions.map { viewModel.sessionLogger.previewImport($0).newPomodoros > 0 } ?? false
        } catch TransferError.unsupportedVersion, TransferError.multipart {
            fail("transfer.error.newerVersion")
        } catch TransferError.notACode {
            fail("transfer.error.notACode")
        } catch {
            fail("transfer.error.damaged")
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard mode == .receive, !reading, let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { readAny(url) }
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

// A short horizontal wobble: `animatableData` counts shakes, each whole step
// is one sine period.
private struct Shake: GeometryEffect {
    var travel: CGFloat
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(animatableData * 2 * .pi * 2), y: 0))
    }
}

// The drop zone's critter: Gemuppin's "#" pixels only, as template images
// (the view tints them), 2 pt per sprite pixel.
private enum DropCritter {
    static let frames: [NSImage] = (GeneratedSprites.friendFrames["gemuppin"] ?? []).compactMap { grid in
        let canvas = PixelCanvas(width: GeneratedSprites.friendWidth, height: GeneratedSprites.friendHeight)
        canvas.drawGrid(grid, 0, 0, colorMap: ["#": "#000000"])
        guard let cgImage = canvas.makeImage() else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: canvas.width * 2, height: canvas.height * 2))
        image.isTemplate = true
        return image
    }
}
