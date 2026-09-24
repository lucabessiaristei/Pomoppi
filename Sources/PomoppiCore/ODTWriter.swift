// ODTWriter.swift — a minimal OpenDocument text (.odt) writer for the
// Diary's export (SPEC.md §8b). No dependency: an .odt is a zip of a few
// XML files, and ZipWriter already writes stored zips. The package rules
// that matter: `mimetype` is the first entry, stored, with no trailing
// newline; `META-INF/manifest.xml` lists the other parts.
import Foundation

// One structural piece of an exported document. DiaryExporter builds a
// list of these once and renders it as Markdown, plain text or ODT, so the
// three formats can't drift apart.
public enum DocumentBlock: Equatable {
    case title(String)
    case heading(String, level: Int)  // 1 = a day, 2 = a pomodoro
    case paragraph(String)
    case item(String)
}

public enum ODTWriter {
    static let mimeType = "application/vnd.oasis.opendocument.text"

    public static func document(_ blocks: [DocumentBlock], date: Date = Date()) -> Data {
        ZipWriter.zip([
            ZipWriter.Entry(name: "mimetype", data: Data(mimeType.utf8)),
            ZipWriter.Entry(name: "META-INF/manifest.xml", data: Data(manifest.utf8)),
            ZipWriter.Entry(name: "content.xml", data: Data(content(blocks).utf8)),
            ZipWriter.Entry(name: "styles.xml", data: Data(styles.utf8)),
        ], date: date)
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }
        return out
    }

    private static let namespaces = """
        xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
        xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" \
        xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" \
        xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" \
        office:version="1.2"
        """

    private static let manifest = """
        <?xml version="1.0" encoding="UTF-8"?>
        <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">
         <manifest:file-entry manifest:full-path="/" manifest:version="1.2" manifest:media-type="\(mimeType)"/>
         <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>
         <manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/>
        </manifest:manifest>

        """

    private static func content(_ blocks: [DocumentBlock]) -> String {
        let body = blocks.map { block -> String in
            switch block {
            case .title(let text):
                return "<text:p text:style-name=\"Title\">\(escape(text))</text:p>"
            case .heading(let text, let level):
                return "<text:h text:style-name=\"Heading_20_\(level)\" text:outline-level=\"\(level)\">\(escape(text))</text:h>"
            case .paragraph(let text):
                return "<text:p text:style-name=\"Standard\">\(escape(text))</text:p>"
            case .item(let text):
                return "<text:p text:style-name=\"Entry\">• \(escape(text))</text:p>"
            }
        }.joined(separator: "\n")
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <office:document-content \(namespaces)>
            <office:body><office:text>
            \(body)
            </office:text></office:body>
            </office:document-content>

            """
    }

    private static let styles = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-styles \(namespaces)>
        <office:styles>
         <style:style style:name="Standard" style:family="paragraph">
          <style:paragraph-properties fo:margin-top="0cm" fo:margin-bottom="0.15cm"/>
          <style:text-properties fo:font-size="11pt"/>
         </style:style>
         <style:style style:name="Title" style:family="paragraph" style:parent-style-name="Standard">
          <style:paragraph-properties fo:margin-bottom="0.3cm"/>
          <style:text-properties fo:font-size="20pt" fo:font-weight="bold"/>
         </style:style>
         <style:style style:name="Heading_20_1" style:display-name="Heading 1" style:family="paragraph" style:parent-style-name="Standard" style:default-outline-level="1">
          <style:paragraph-properties fo:margin-top="0.5cm" fo:margin-bottom="0.2cm"/>
          <style:text-properties fo:font-size="16pt" fo:font-weight="bold"/>
         </style:style>
         <style:style style:name="Heading_20_2" style:display-name="Heading 2" style:family="paragraph" style:parent-style-name="Standard" style:default-outline-level="2">
          <style:paragraph-properties fo:margin-top="0.35cm" fo:margin-bottom="0.1cm"/>
          <style:text-properties fo:font-size="13pt" fo:font-weight="bold"/>
         </style:style>
         <style:style style:name="Entry" style:family="paragraph" style:parent-style-name="Standard">
          <style:paragraph-properties fo:margin-left="0.5cm" fo:margin-bottom="0cm"/>
         </style:style>
        </office:styles>
        </office:document-styles>

        """
}
