import SwiftUI

public struct StreamingTextView: View {
    public let content: String
    @State private var cursorVisible = true

    public init(content: String) {
        self.content = content
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Text(content)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("▊")
                .font(.subheadline)
                .opacity(cursorVisible ? 1 : 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 18), interactive: false)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .transaction { t in t.animation = nil }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                cursorVisible.toggle()
            }
        }
    }
}
