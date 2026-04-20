import SwiftUI
import SwiftData
import AMUXCore
import AMUXSharedUI

struct ComposerView: View {
    let teamclawService: TeamclawService
    let sessionId: String
    let actorId: String
    let agent: Agent?
    /// When non-nil, prompts are routed through ACP (Amux_AcpSendPrompt) via
    /// the shared AgentDetailViewModel so the daemon and agent receive them
    /// as real prompts. When nil (collab-only sessions), prompts fall back
    /// to TeamclawService.sendMessage which only broadcasts a chat bubble.
    let agentVM: AgentDetailViewModel?

    @Environment(\.modelContext) private var modelContext
    @State private var text: String = ""
    @State private var isSending = false
    @State private var voice = VoiceRecorder()
    @State private var selectedModelId: String?
    @FocusState private var inputFocused: Bool
    @State private var slashCandidates: [SlashCommand] = []
    @State private var showSlashPopup: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 8) {
                TextField("Reply…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($inputFocused)
                    .lineLimit(1...12)
                    .font(.system(size: 14))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(in: Capsule())
                    .onSubmit { send() }
                    .onChange(of: text) { _, newValue in
                        updateSlashCandidates(from: newValue)
                    }
                    .popover(isPresented: $showSlashPopup, arrowEdge: .top) {
                        SlashCommandsPopup(candidates: slashCandidates) { cmd in
                            insertCommand(cmd)
                        }
                        .padding(6)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)

                HStack(spacing: 8) {
                    ModelPicker(agent: agent, selectedModelId: $selectedModelId)
                    Spacer()
                    Button(action: micTapped) {
                        Image(systemName: voice.state == .recording ? "mic.fill" : "mic")
                            .font(.system(size: 14))
                            .foregroundStyle(voice.state == .recording ? .red : .primary)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(in: Capsule())
                    .help(voice.state == .recording ? "Stop recording (Esc to cancel)" : "Voice input")

                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(canSend ? Color.white : .secondary)
                            .frame(width: 30, height: 30)
                            .background(canSend ? Color.accentColor : Color.secondary.opacity(0.2), in: Capsule())
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
        let model = selectedModelId ?? agent?.currentModel
        text = ""
        if let agentVM {
            // Agent session - route through ACP so the daemon actually
            // delivers the prompt to the agent process. Mirrors iOS
            // AgentDetailView's ReplySheet onSend handler.
            let ctx = modelContext
            Task {
                defer { Task { @MainActor in isSending = false } }
                try? await agentVM.sendPrompt(trimmed, modelId: model, modelContext: ctx)
            }
        } else {
            // Collab-only session - broadcast a chat bubble via Teamclaw.
            teamclawService.sendMessage(sessionId: sessionId, content: trimmed, actorId: actorId, modelId: model)
            isSending = false
        }
    }

    private func micTapped() {
        voice.toggle()
    }

    private func updateSlashCandidates(from text: String) {
        guard let prefix = Self.slashPrefix(in: text) else {
            slashCandidates = []
            showSlashPopup = false
            return
        }
        let all = agentVM?.availableCommands ?? []
        slashCandidates = prefix.isEmpty ? all : all.filter { $0.name.hasPrefix(prefix) }
        showSlashPopup = !slashCandidates.isEmpty
    }

    private static func slashPrefix(in text: String) -> String? {
        guard text.hasPrefix("/") else { return nil }
        let body = text.dropFirst()
        if body.contains(" ") { return nil }   // space closes the popup
        return String(body)
    }

    private func insertCommand(_ cmd: SlashCommand) {
        text = "/\(cmd.name) "
        showSlashPopup = false
    }
}
