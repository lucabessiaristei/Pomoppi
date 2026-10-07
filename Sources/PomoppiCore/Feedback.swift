// Feedback.swift — the "Write to Luca" email: address, subject, body and the
// mailto: URL that carries them. No UI and no mail-app detection here (each
// platform's settings code does that); this file only builds the text and
// encodes it. The body holds the template plus one version line and nothing
// else, so there is nothing hidden in what gets sent.
//
// The template text is localized, so it comes in through `Feedback.Template`
// rather than this file importing PomoppiStrings (same pattern as
// `DiaryText` for the Diary export). The subject stays fixed English: it's
// what Luca's inbox filters on, whatever language the sender uses.
import Foundation

// The one line appended to the email: app version, OS, CPU architecture.
// Exactly these three fields, so the line can't grow into anything else.
public struct FeedbackVersionLine: Equatable {
    public let version: String       // pomoppiVersion
    public let system: String        // "macOS 26.0" / "Windows 11 24H2"
    public let architecture: String  // "Apple silicon" / "ARM64, running as x64"

    public init(version: String, system: String, architecture: String) {
        self.version = version
        self.system = system
        self.architecture = architecture
    }

    public var text: String { "Pomoppi \(version) · \(system) · \(architecture)" }
}

public enum Feedback {
    public static let address = "pomoppi@lucabessiaristei.it"
    public static let subject = "Pomoppi feedback"

    // Localized pieces of the body, supplied by the caller.
    public struct Template {
        public let happened: String
        public let expected: String
        public let deleteHint: String

        public init(happened: String, expected: String, deleteHint: String) {
            self.happened = happened
            self.expected = expected
            self.deleteHint = deleteHint
        }
    }

    public static func body(template: Template, line: FeedbackVersionLine) -> String {
        template.happened + "\n\n\n" + template.expected + "\n\n\n" + "— " + line.text + " " + template.deleteHint
    }

    // RFC 6068: percent-encoded UTF-8, spaces as %20 (never "+"), line breaks
    // as CRLF. Built by hand because URLComponents leaves "+" and "&" alone
    // in query values.
    public static func mailtoURL(template: Template, line: FeedbackVersionLine) -> URL {
        let crlf = body(template: template, line: line).replacingOccurrences(of: "\n", with: "\r\n")
        return URL(string: "mailto:" + address + "?subject=" + encode(subject) + "&body=" + encode(crlf))!
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved)!
    }
}
