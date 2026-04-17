import SwiftUI
import AMUXCore

struct MessageRowSystem: View {
    let message: SessionMessage

    private var severity: SystemReminderSeverity {
        SystemReminderSeverity.from(content: message.content)
    }

    var body: some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: severity == .urgent ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    Text(severity.label.uppercased())
                        .tracking(0.5)
                }
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(severity.color)

                Text(message.content)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.18), in: SystemBubbleShape())
            .frame(maxWidth: 460, alignment: .leading)
        }
        .padding(.horizontal, 22)
    }
}

private struct SystemBubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let path = UnevenRoundedRectangle(cornerRadii: .init(
            topLeading: 18, bottomLeading: 18, bottomTrailing: 6, topTrailing: 18
        ))
        return path.path(in: rect)
    }
}
