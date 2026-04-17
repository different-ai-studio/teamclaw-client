import SwiftUI
import AMUXCore

struct DetailHeaderView: View {
    let session: CollabSession
    let participantSummary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(session.title.isEmpty ? "(untitled)" : session.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 12)
                .padding(.horizontal, 22)

            Text(participantSummary)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)
                .padding(.horizontal, 22)

            Divider().padding(.horizontal, 22)

            Text(session.title.isEmpty ? "(untitled)" : session.title)
                .font(.system(size: 26, weight: .bold))
                .padding(.top, 18)
                .padding(.horizontal, 22)
                .padding(.bottom, 4)

            Text(timeLabel.uppercased())
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .tracking(0.4)
                .padding(.horizontal, 22)
                .padding(.bottom, 14)
        }
    }

    private var timeLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return formatter.string(from: session.lastMessageAt ?? session.createdAt)
    }
}
