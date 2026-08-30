import SwiftUI
import AnLuongMeetingCore

struct MarkdownDocumentView: View {
    let markdown: String
    var corrections: [NoteCorrection] = []
    var onCorrectionTap: ((NoteCorrection) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(Markdown.parse(markdown).enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, corrections: corrections)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "anluong-correction", let id = url.host,
                  let correction = corrections.first(where: { $0.id == id }) else { return .discarded }
            onCorrectionTap?(correction)
            return .handled
        })
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    var corrections: [NoteCorrection] = []

    var body: some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text).font(level == 1 ? .title.bold() : level == 2 ? .title2.bold() : .headline)
        case .paragraph(let text):
            inlineText(text).font(.body).fixedSize(horizontal: false, vertical: true)
        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 8) { ForEach(items, id: \.self) { inlineText("•  \($0)") } }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 8) { ForEach(Array(items.enumerated()), id: \.offset) { index, text in inlineText("\(index + 1).  \(text)") } }
        case .quote(let text):
            inlineText(text).italic().padding(.leading, 14).overlay(alignment: .leading) { Rectangle().fill(.secondary).frame(width: 3) }
        case .code(let text):
            Text(text).font(.system(.footnote, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        case .divider:
            Divider()
        }
    }

    private func inlineText(_ text: String) -> Text {
        let highlighted = wrapCorrectionsAsLinks(in: text, corrections: corrections)
        guard let attributed = try? AttributedString(markdown: highlighted) else { return Text(text) }
        return Text(attributed)
    }
}
