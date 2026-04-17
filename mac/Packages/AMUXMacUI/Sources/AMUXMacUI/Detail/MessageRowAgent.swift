import SwiftUI
import AMUXCore

struct MessageRowAgent: View {
    let message: SessionMessage
    let senderName: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarCircleAgent(seed: message.senderActorId)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(senderName)
                        .font(.system(size: 12, weight: .semibold))
                    Text(timeLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                BlockMarkdownView(source: message.content)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 22)
    }

    private var timeLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: message.createdAt)
    }
}

struct AvatarCircleAgent: View {
    let seed: String

    var body: some View {
        Circle()
            .fill(Color(.windowBackgroundColor))
            .overlay(
                Circle().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 0.5)
            )
            .overlay(
                Image(systemName: "diamond.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
            )
    }
}
