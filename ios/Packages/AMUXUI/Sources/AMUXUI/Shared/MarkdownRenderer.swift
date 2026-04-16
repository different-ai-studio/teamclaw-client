import SwiftUI
import Markdown

struct MarkdownRenderer: View {
    let content: String

    var body: some View {
        Text(attributedContent)
            .font(.subheadline)
            .textSelection(.enabled)
    }

    private var attributedContent: AttributedString {
        do {
            return try AttributedString(markdown: content, options: .init(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            ))
        } catch {
            return AttributedString(content)
        }
    }
}
