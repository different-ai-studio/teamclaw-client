import SwiftUI
import AMUXCore

/// Inline autocomplete popup for ACP slash commands. Rendered by the
/// composer whenever the user's in-progress text matches `/<prefix>`
/// and at least one known command starts with that prefix.
///
/// Stateless: the parent owns `candidates` and the `onTap` handler that
/// inserts `/<name> ` into the composer.
struct SlashCommandsPopup: View {
    let candidates: [SlashCommand]
    let onTap: (SlashCommand) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(candidates) { cmd in
                Button {
                    onTap(cmd)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("/\(cmd.name)")
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(cmd.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("slash \(cmd.name). \(cmd.description)"))
                .accessibilityHint(Text("Inserts this command into the message"))

                if cmd.id != candidates.last?.id {
                    Divider().padding(.leading, 14)
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .frame(maxWidth: 320)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

#Preview {
    SlashCommandsPopup(
        candidates: [
            SlashCommand(name: "clear", description: "Clear conversation history", inputHint: ""),
            SlashCommand(name: "compact", description: "Compact the context window", inputHint: ""),
            SlashCommand(name: "rename", description: "Rename this session", inputHint: "new name"),
        ],
        onTap: { _ in }
    )
    .padding()
}
