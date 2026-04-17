import SwiftUI
import AMUXCore

struct SessionRow: View {
    let session: CollabSession
    let participantSummary: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // 8pt unread dot (always blank in v1; tracked in a future plan)
            Circle()
                .fill(Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 8)

            // 36pt rounded square avatar (color-hashed by sessionId, initial from title)
            AvatarSquare(seed: session.sessionId, initial: initial)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.title.isEmpty ? "(untitled)" : session.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(3)
                    .foregroundStyle(.primary)

                HStack {
                    Text(participantSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text(timeLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var initial: String {
        let trimmed = session.title.trimmingCharacters(in: .whitespaces)
        return trimmed.first.map { String($0).uppercased() } ?? "?"
    }

    private var timeLabel: String {
        let date = session.lastMessageAt ?? session.createdAt
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}

/// Rounded-square sibling of AvatarCircle, used by 36pt list-row icons.
struct AvatarSquare: View {
    let seed: String
    let initial: String

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(LinearGradient(
                colors: gradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .overlay(
                Text(initial)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }

    private var gradientColors: [Color] {
        let hash = abs(seed.hashValue)
        let hue = Double(hash % 360) / 360.0
        return [
            Color(hue: hue, saturation: 0.6, brightness: 0.85),
            Color(hue: hue, saturation: 0.7, brightness: 0.55),
        ]
    }
}
