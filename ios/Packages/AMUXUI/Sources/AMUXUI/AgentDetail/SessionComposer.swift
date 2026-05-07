import SwiftUI
import AMUXCore
import AMUXSharedUI

struct SessionComposer: View {
    @Binding var promptText: String
    @Binding var selectedModelId: String?
    @Binding var attachments: [URL]

    let voiceRecorder: VoiceRecorder
    let runtime: Runtime?
    let isAgentActive: Bool
    let availableCommands: [SlashCommand]

    let onSend: () -> Void
    let onCancelTask: () -> Void

    @State private var showDrawer = false
    @State private var slashCandidates: [SlashCommand] = []
    @State private var hasPendingSlashCommand = false
    @FocusState private var inputFocused: Bool

    private var hasText: Bool {
        !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var rightButton: ComposerRightButton {
        ComposerState.rightButton(
            isAgentActive: isAgentActive,
            hasText: hasText,
            voiceState: voiceRecorder.state
        )
    }

    private var inputMode: ComposerInputMode {
        ComposerState.inputMode(voiceState: voiceRecorder.state)
    }

    private var slashPrefix: String? {
        guard let first = promptText.first, first == "/" else { return nil }
        let rest = promptText.dropFirst()
        guard rest.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            return nil
        }
        return String(rest)
    }

    private var matchesKnownCommand: Bool {
        guard promptText.hasPrefix("/") else { return false }
        let after = promptText.dropFirst()
        let head = after.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? String(after)
        guard !head.isEmpty else { return false }
        return availableCommands.contains(where: { $0.name == head })
    }

    var body: some View {
        VStack(spacing: 6) {
            if !slashCandidates.isEmpty {
                SlashCommandsPopup(
                    candidates: slashCandidates,
                    onTap: { cmd in
                        promptText = "/\(cmd.name) "
                        slashCandidates = []
                        hasPendingSlashCommand = true
                    }
                )
                .padding(.horizontal, 16)
                .animation(.easeInOut(duration: 0.15), value: slashCandidates)
            }

            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments, id: \.self) { url in
                            HStack(spacing: 4) {
                                Image(systemName: "doc").font(.caption)
                                Text(url.lastPathComponent)
                                    .font(.caption)
                                    .lineLimit(1)
                                Button {
                                    attachments.removeAll { $0 == url }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .liquidGlass(in: Capsule(), interactive: false)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                Text("attachments coming soon")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
            }

            HStack(spacing: 10) {
                Button { showDrawer = true } label: {
                    Image(systemName: "plus")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .liquidGlass(in: Circle())
                .accessibilityIdentifier("composer.plusButton")

                pill
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .onChange(of: promptText) { _, _ in recomputeSlashCandidates() }
        .onChange(of: availableCommands) { _, _ in recomputeSlashCandidates() }
        .onChange(of: voiceRecorder.state) { _, newState in
            if newState == .done {
                let text = voiceRecorder.transcribedText ?? ""
                if !text.isEmpty {
                    promptText = text
                }
                voiceRecorder.reset()
            }
        }
        .sheet(isPresented: $showDrawer) {
            AttachmentDrawerSheet(
                attachments: $attachments,
                selectedModelId: $selectedModelId,
                runtime: runtime
            )
            .presentationDetents([.fraction(0.4), .medium])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var pill: some View {
        HStack(spacing: 6) {
            Group {
                switch inputMode {
                case .textField:
                    TextField("Send a message…", text: $promptText, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($inputFocused)
                        .submitLabel(.return)
                        .accessibilityIdentifier("composer.textField")
                case .waveform:
                    RecordingWaveform(level: voiceRecorder.audioLevel)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.leading, 14)
            .padding(.vertical, 8)

            rightButtonView
                .padding(.trailing, 6)
        }
        .liquidGlass(in: Capsule())
    }

    @ViewBuilder
    private var rightButtonView: some View {
        switch rightButton {
        case .stop:
            Button {
                onCancelTask()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.amux.cinnabarDeep)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("composer.stopButton")

        case .stopRecording:
            Button {
                voiceRecorder.stopRecording()
            } label: {
                Image(systemName: "mic.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.amux.cinnabarDeep)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("composer.stopRecordingButton")

        case .send:
            Button {
                onSend()
                hasPendingSlashCommand = false
            } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(hasPendingSlashCommand ? Color.amux.mist : Color.amux.onyx)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .modifier(SendButtonGlassModifier(emphasized: hasPendingSlashCommand))
            .accessibilityIdentifier("composer.sendButton")

        case .mic:
            Button {
                voiceRecorder.startRecording()
            } label: {
                Image(systemName: "mic")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("composer.micButton")
        }
    }

    private func recomputeSlashCandidates() {
        if let prefix = slashPrefix {
            let lower = prefix.lowercased()
            slashCandidates = Array(
                availableCommands
                    .filter { $0.name.lowercased().hasPrefix(lower) }
                    .prefix(5)
            )
        } else {
            slashCandidates = []
        }
        hasPendingSlashCommand = matchesKnownCommand
    }
}

private struct SendButtonGlassModifier: ViewModifier {
    let emphasized: Bool
    func body(content: Content) -> some View {
        if emphasized {
            content.liquidGlass(in: Circle(), tint: .accentColor)
        } else {
            content.liquidGlass(in: Circle())
        }
    }
}
