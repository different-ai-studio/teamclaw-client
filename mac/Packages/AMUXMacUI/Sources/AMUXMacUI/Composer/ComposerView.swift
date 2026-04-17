import SwiftUI
import AMUXCore

struct ComposerView: View {
    let teamclawService: TeamclawService
    let sessionId: String
    let actorId: String

    @State private var text: String = ""
    @State private var isSending = false
    @State private var voice = VoiceRecorder()
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 8) {
                TextField("Reply…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($inputFocused)
                    .lineLimit(1...12)
                    .font(.system(size: 14))
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .onSubmit { send() }

                HStack(spacing: 8) {
                    ModelPicker(sessionId: sessionId)
                    Spacer()
                    Button(action: micTapped) {
                        Image(systemName: voice.state == .recording ? "mic.fill" : "mic")
                            .font(.system(size: 16))
                            .foregroundStyle(voice.state == .recording ? .red : .primary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help(voice.state == .recording ? "Stop recording (Esc to cancel)" : "Voice input")

                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(canSend ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
            .background(.regularMaterial)
        }
        .onChange(of: voice.transcript) { _, newValue in
            if voice.state == .recording, !newValue.isEmpty {
                text = newValue
            }
        }
        .onKeyPress(.escape) {
            if voice.state == .recording {
                voice.cancel()
                return .handled
            }
            return .ignored
        }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        isSending = true
        teamclawService.sendMessage(sessionId: sessionId, content: trimmed, actorId: actorId)
        text = ""
        isSending = false
    }

    private func micTapped() {
        voice.toggle()
    }
}
