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
        ZStack(alignment: .bottomLeading) {
            TextField("Reply…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .font(.system(size: 13))
                .lineLimit(2...6)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 46)
                .padding(.trailing, 88)
                .frame(maxWidth: .infinity, alignment: .leading)
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

            HStack(alignment: .bottom, spacing: 10) {
                HStack(spacing: 8) {
                    attachmentButton
                    ModelPicker(agent: agent, selectedModelId: $selectedModelId)
                }

                Spacer()

                HStack(spacing: 10) {
                    voiceButton
                    sendButton
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .frame(minHeight: 96, maxHeight: 186)
        .glassEffect(in: Rectangle())
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

    private var isAgentActive: Bool {
        agentVM?.isActive == true
    }

    private func primaryButtonTapped() {
        if isAgentActive {
            guard let agentVM else { return }
            Task { try? await agentVM.cancelTask() }
        } else {
            send()
        }
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
            // Shared session - broadcast a chat bubble via Teamclaw.
            teamclawService.sendMessage(sessionId: sessionId, content: trimmed, modelId: model)
            isSending = false
        }
    }

    private func micTapped() {
        voice.toggle()
    }

    private var attachmentButton: some View {
        Button(action: {}) {
            Image(systemName: "paperclip")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .glassEffect(in: Circle())
        .disabled(true)
        .help("Attachments are not available yet")
    }

    private var voiceButton: some View {
        Button(action: micTapped) {
            Image(systemName: voice.state == .recording ? "mic.fill" : "mic")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(voice.state == .recording ? .red : .primary)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .glassEffect(in: Circle())
        .help(voice.state == .recording ? "Stop recording (Esc to cancel)" : "Voice input")
    }

    private var sendButton: some View {
        Button(action: primaryButtonTapped) {
            if isAgentActive {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 34, height: 34)
                    .background(Color.red, in: Circle())
            } else {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(canSend ? Color.white : .secondary)
                    .frame(width: 34, height: 34)
                    .background(canSend ? Color.accentColor : Color.white.opacity(0.42), in: Circle())
            }
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!isAgentActive && !canSend)
        .help(isAgentActive ? "Stop agent" : "Send")
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
