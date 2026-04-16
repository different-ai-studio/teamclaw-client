import SwiftUI

public struct StreamingTextView: View {
    public let content: String
    @State private var cursorVisible = true

    public init(content: String) {
        self.content = content
    }

    public var body: some View {
        Text(content + (cursorVisible ? " ▊" : ""))
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .animation(nil, value: content) // prevent text change animation
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    cursorVisible.toggle()
                }
            }
    }
}
