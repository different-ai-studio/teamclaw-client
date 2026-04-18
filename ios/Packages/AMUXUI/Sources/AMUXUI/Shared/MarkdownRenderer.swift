import SwiftUI
import Foundation

struct MarkdownRenderer: View {
    let content: String

    var body: some View {
        Text(MarkdownCache.shared.parse(content))
            .font(.subheadline)
            .textSelection(.enabled)
    }
}

/// Thread-safe FIFO-bounded cache for parsed markdown. Streaming renders
/// invalidate `body` on every delta; the same completed assistant bubble
/// would otherwise re-parse its full markdown on every frame. Caching by
/// the raw content string lets each stable bubble pay the parse cost once.
private final class MarkdownCache: @unchecked Sendable {
    static let shared = MarkdownCache()

    private let lock = NSLock()
    private var storage: [String: AttributedString] = [:]
    private var order: [String] = []
    private let capacity = 256

    func parse(_ content: String) -> AttributedString {
        lock.lock()
        if let hit = storage[content] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let parsed: AttributedString
        if let attr = try? AttributedString(markdown: content, options: .init(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )) {
            parsed = attr
        } else {
            parsed = AttributedString(content)
        }

        lock.lock()
        if storage[content] == nil {
            storage[content] = parsed
            order.append(content)
            while order.count > capacity {
                let evict = order.removeFirst()
                storage.removeValue(forKey: evict)
            }
        }
        lock.unlock()
        return parsed
    }
}
