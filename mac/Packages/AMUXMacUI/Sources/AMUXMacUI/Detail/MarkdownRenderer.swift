import SwiftUI

/// Foundation-backed Markdown renderer. Mirrors the iOS MarkdownRenderer but
/// without the (unused) swift-markdown import — `AttributedString(markdown:)`
/// covers inline emphasis, links, code spans, and lists, which is all the
/// assistant feed actually needs today.
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
