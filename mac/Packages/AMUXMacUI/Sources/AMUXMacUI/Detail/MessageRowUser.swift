import SwiftUI
import AMUXCore

struct MessageRowUser: View {
    let message: SessionMessage
    let senderName: String

    var body: some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 4) {
                Text(senderName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(message.content)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor, in: BubbleShape())
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .textSelection(.enabled)

                Text(timeLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 460, alignment: .trailing)
        }
        .padding(.horizontal, 22)
    }

    private var timeLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: message.createdAt)
    }
}

private struct BubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let path = UnevenRoundedRectangle(cornerRadii: .init(
            topLeading: 18, bottomLeading: 18, bottomTrailing: 6, topTrailing: 18
        ))
        return path.path(in: rect)
    }
}
