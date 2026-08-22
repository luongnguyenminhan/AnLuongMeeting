import SwiftUI
import AnLuongMeetingCore

struct MarkdownDocumentView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(Markdown.parse(markdown).enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(text).font(level == 1 ? .title.bold() : level == 2 ? .title2.bold() : .headline)
        case .paragraph(let text):
            Text(text).font(.body).fixedSize(horizontal: false, vertical: true)
        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 8) { ForEach(items, id: \.self) { Text("•  \($0)") } }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 8) { ForEach(Array(items.enumerated()), id: \.offset) { index, text in Text("\(index + 1).  \(text)") } }
        case .quote(let text):
            Text(text).italic().padding(.leading, 14).overlay(alignment: .leading) { Rectangle().fill(.secondary).frame(width: 3) }
        case .code(let text):
            Text(text).font(.system(.footnote, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        case .divider:
            Divider()
        }
    }
}
