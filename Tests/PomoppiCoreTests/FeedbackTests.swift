import XCTest
@testable import PomoppiCore

final class FeedbackTests: XCTestCase {
    private let line = FeedbackVersionLine(version: "0.6.3", system: "Windows 11 24H2", architecture: "ARM64, running as x64")

    private let templates: [Feedback.Template] = [
        .init(happened: "What happened, or what you'd like:", expected: "What you expected:", deleteHint: "(you can delete this line)"),
        .init(happened: "Cosa è successo, o cosa vorresti:", expected: "Cosa ti aspettavi:", deleteHint: "(puoi cancellare questa riga)"),
        .init(happened: "Ce qui s’est passé, ou ce que vous aimeriez :", expected: "Ce que vous attendiez :", deleteHint: "(vous pouvez supprimer cette ligne)"),
        .init(happened: "Garçon: ça ne démarre pas & c’est lent + bizarre", expected: "Was hast du erwartet:", deleteHint: "(du kannst diese Zeile löschen)"),
        .init(happened: "Qué pasó, o qué te gustaría:", expected: "Qué esperabas:", deleteHint: "(puedes borrar esta línea)"),
    ]

    private func decoded(_ url: URL) -> (subject: String?, body: String?) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return (items.first { $0.name == "subject" }?.value, items.first { $0.name == "body" }?.value)
    }

    func testURLDecodesBackToSubjectAndBody() {
        let t = templates[0]
        let url = Feedback.mailtoURL(template: t, line: line)
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        XCTAssertEqual(c?.scheme, "mailto")
        XCTAssertEqual(c?.path, Feedback.address)
        let d = decoded(url)
        XCTAssertEqual(d.subject, Feedback.subject)
        XCTAssertEqual(d.body, Feedback.body(template: t, line: line).replacingOccurrences(of: "\n", with: "\r\n"))
    }

    func testTemplatesRoundTripWithAccentsAndPunctuation() {
        for t in templates {
            let url = Feedback.mailtoURL(template: t, line: line)
            let raw = url.absoluteString
            XCTAssertFalse(raw.contains("+"), "spaces must be %20, and a literal + must be %2B")
            XCTAssertTrue(raw.contains("%0D%0A"))
            XCTAssertEqual(decoded(url).body, Feedback.body(template: t, line: line).replacingOccurrences(of: "\n", with: "\r\n"))
        }
    }

    func testBodyIsTemplateAndLineOnly() {
        let t = templates[1]
        XCTAssertEqual(
            Feedback.body(template: t, line: line),
            t.happened + "\n\n\n" + t.expected + "\n\n\n" + "— " + line.text + " " + t.deleteHint
        )
    }

    func testVersionLineShape() {
        XCTAssertEqual(line.text, "Pomoppi 0.6.3 · Windows 11 24H2 · ARM64, running as x64")
        XCTAssertNotNil(line.text.range(of: #"^Pomoppi \S+ · .+ · .+$"#, options: .regularExpression))
    }
}
