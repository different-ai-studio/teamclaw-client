import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AMUXCore

// MARK: - AgentDetailView (NetNewsWire Article-style)

public struct AgentDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: AgentDetailViewModel
    @State private var promptText = ""
    @State private var showReplySheet = false
    @State private var showSettings = false
    @State private var showMembers = false
    @State private var collaborators: [Member] = []
    @State private var voiceRecorder = VoiceRecorder(contextualStrings: [
        "Claude", "Claude Code", "Sonnet", "Opus", "Haiku",
        "MQTT", "protobuf", "SwiftUI", "SwiftData",
        "agent", "daemon", "worktree", "workspace",
        "commit", "push", "merge", "pull request",
        "API", "JSON", "YAML", "REST", "gRPC",
    ])

    let allAgentIds: [String]
    @Binding var navigationPath: [String]

    public init(agent: Agent, mqtt: MQTTService, deviceId: String, peerId: String,
                allAgentIds: [String], navigationPath: Binding<[String]>) {
        _viewModel = State(initialValue: AgentDetailViewModel(
            agent: agent, mqtt: mqtt, deviceId: deviceId, peerId: peerId))
        self.allAgentIds = allAgentIds
        self._navigationPath = navigationPath
    }

    public init(collabSession: CollabSession, mqtt: MQTTService, deviceId: String, peerId: String,
                teamclawService: TeamclawService?, navigationPath: Binding<[String]>) {
        _viewModel = State(initialValue: AgentDetailViewModel(
            agent: nil, mqtt: mqtt, deviceId: deviceId, peerId: peerId, collabSession: collabSession, teamclawService: teamclawService))
        self.allAgentIds = []
        self._navigationPath = navigationPath
    }

    private var agentLogoName: String {
        switch viewModel.agent?.agentType {
        case 1: "ClaudeLogo"
        case 2: "OpenCodeLogo"
        case 3: "CodexLogo"
        default: "ClaudeLogo"
        }
    }

    private var memberBadgeCount: Int {
        let collab = viewModel.participantCount
        return collab > 0 ? collab : collaborators.count
    }

    private var currentIndex: Int? {
        guard let agentId = viewModel.agent?.agentId else { return nil }
        return allAgentIds.firstIndex(of: agentId)
    }
    private var canGoUp: Bool { (currentIndex ?? 0) > 0 }
    private var canGoDown: Bool { (currentIndex ?? allAgentIds.count) < allAgentIds.count - 1 }

    private func goUp() {
        guard let idx = currentIndex, idx > 0 else { return }
        navigationPath = [allAgentIds[idx - 1]]
    }
    private func goDown() {
        guard let idx = currentIndex, idx < allAgentIds.count - 1 else { return }
        navigationPath = [allAgentIds[idx + 1]]
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !viewModel.isDaemonOnline {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.slash").font(.caption)
                    Text("Daemon offline").font(.caption).fontWeight(.medium)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .liquidGlass(in: Capsule(), tint: .orange, interactive: false)
                .padding(.vertical, 4)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if viewModel.events.isEmpty && !viewModel.isStreaming {
                            VStack(spacing: 12) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.quaternary)
                                Text("No messages yet")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 60)
                        }

                        ForEach(viewModel.groupedEvents) { item in
                            switch item {
                            case .single(let event):
                                EventBubbleView(
                                    event: event,
                                    agent: viewModel.agent,
                                    onGrant: { id in Task { try? await viewModel.grantPermission(requestId: id) } },
                                    onDeny: { id in Task { try? await viewModel.denyPermission(requestId: id) } }
                                ).id(event.id)
                            case .toolRun(let id, let events):
                                ToolRunSummaryBar(events: events)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 2)
                                    .id(id)
                            }
                        }

                        if viewModel.isStreaming {
                            StreamingTextView(content: viewModel.streamingText)
                                .id("streaming")
                        }

                        if viewModel.isActive {
                            TypingIndicatorView()
                                .id("typing")
                        }

                        Color.clear.frame(height: 8).id("bottom")
                    }
                    .padding(.top, 8)
                }
                .onAppear {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: viewModel.events.count) {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: viewModel.streamingText) {
                    if viewModel.isStreaming {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
        }
        .navigationTitle(viewModel.sessionTitle)
        .navigationBarTitleDisplayMode(.inline)
        // Top right: prev/next (NetNewsWire ▲▼)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { goUp() } label: { Image(systemName: "chevron.up").font(.title3) }
                    .disabled(!canGoUp)
                Button { goDown() } label: { Image(systemName: "chevron.down").font(.title3) }
                    .disabled(!canGoDown)
            }
        }
        .toolbar(.hidden, for: .bottomBar)
        .toolbar(.hidden, for: .tabBar)
        // Bottom: voice result bubble + toolbar
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                // Transcribed text bubble
                if let text = voiceRecorder.transcribedText, !text.isEmpty,
                   voiceRecorder.state == .done {
                    VStack(spacing: 8) {
                        Text(text)
                            .font(.subheadline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .liquidGlass(in: RoundedRectangle(cornerRadius: 16), interactive: false)

                        HStack(spacing: 12) {
                            Spacer()
                            Button {
                                promptText = text
                                voiceRecorder.reset()
                                showReplySheet = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "pencil")
                                        .font(.subheadline.weight(.semibold))
                                    Text("Edit")
                                        .font(.subheadline).fontWeight(.medium)
                                }
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .liquidGlass(in: Capsule())
                            }
                            .buttonStyle(.plain)

                            Button {
                                let t = text
                                voiceRecorder.reset()
                                Task { try? await viewModel.sendPrompt(t, modelContext: modelContext) }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.up")
                                        .font(.subheadline.weight(.semibold))
                                    Text("Send")
                                        .font(.subheadline).fontWeight(.medium)
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .background(.green.gradient, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }

                // Toolbar: 3 independent glass capsules
                HStack {
                    // Left group: pin + members
                    HStack(spacing: 14) {
                        Button {} label: { Image(systemName: "pin").font(.title3) }
                        Button { showMembers = true } label: {
                            Image(systemName: "person.2").font(.title3)
                                .overlay(alignment: .topTrailing) {
                                    if memberBadgeCount > 0 {
                                        Text("\(memberBadgeCount)")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(.blue, in: Capsule())
                                            .offset(x: 8, y: -8)
                                    }
                                }
                        }
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .liquidGlass(in: Capsule())

                    Spacer()

                    // Center: mic
                    RecordButton(voiceRecorder: voiceRecorder)
                        .disabled(viewModel.isActive)

                    Spacer()

                    // Right group: agent avatar + action
                    HStack(spacing: 14) {
                        if viewModel.hasAgent {
                            Button { showSettings = true } label: {
                                Image(agentLogoName, bundle: .module)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 22, height: 22)
                            }
                        }
                        if viewModel.isActive {
                            Button { Task { try? await viewModel.cancelTask() } } label: { Image(systemName: "stop.fill").font(.title3) }
                        } else {
                            Button { showReplySheet = true } label: { Image(systemName: "arrowshape.turn.up.left").font(.title3) }
                        }
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .liquidGlass(in: Capsule())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .sheet(isPresented: $showReplySheet) {
            ReplySheet(text: $promptText,
                       isDisabled: !viewModel.isIdle,
                       isStreaming: viewModel.isStreaming,
                       hasAgent: viewModel.hasAgent,
                       agent: viewModel.agent,
                       availableCommands: viewModel.availableCommands,
                       onSend: { modelId in
                           let t = promptText; promptText = ""
                           Task { try? await viewModel.sendPrompt(t, modelId: modelId, modelContext: modelContext) }
                       },
                       onCancel: { Task { try? await viewModel.cancelTask() } })
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showSettings) {
            if let agent = viewModel.agent {
                AgentSettingsSheet(
                    agent: agent,
                    onSync: { Task { try? await viewModel.requestIncrementalSync(modelContext: modelContext) } },
                    isSyncing: viewModel.isSyncing
                )
                .presentationDetents([.medium])
            }
        }
        .sheet(isPresented: $showMembers) {
            MemberListView(mqtt: viewModel.mqttRef, deviceId: viewModel.deviceIdRef, peerId: viewModel.peerIdRef,
                           selected: Set(collaborators.map(\.memberId))) { selected in
                collaborators = selected
                if !selected.isEmpty {
                    forkToCollab(members: selected)
                }
            }
        }
        .task { viewModel.start(modelContext: modelContext) }
        .onDisappear { viewModel.stop() }
    }

    private func forkToCollab(members: [Member]) {
        guard let agent = viewModel.agent else { return }
        // Use last output summary or session title as handoff context
        let summary = agent.lastOutputSummary.isEmpty
            ? "Forked from agent session: \(agent.sessionTitle.isEmpty ? agent.agentId : agent.sessionTitle)"
            : agent.lastOutputSummary

        var createReq = Teamclaw_CreateSessionRequest()
        createReq.sessionType = .collab
        createReq.teamID = viewModel.deviceIdRef  // v1: use deviceId as teamId
        createReq.title = agent.sessionTitle.isEmpty ? "Collab: \(agent.worktree.split(separator: "/").last.map(String.init) ?? agent.agentId)" : "Collab: \(agent.sessionTitle)"
        createReq.summary = summary
        createReq.inviteActorIds = members.map(\.memberId)

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = viewModel.deviceIdRef
        rpcReq.method = .createSession(createReq)

        let deviceId = viewModel.deviceIdRef
        let topic = "teamclaw/\(deviceId)/rpc/\(deviceId)/\(rpcReq.requestID)/req"
        Task {
            if let data = try? rpcReq.serializedData() {
                try? await viewModel.mqttRef.publish(topic: topic, payload: data, retain: false)
            }
        }
    }
}

// MARK: - ReplySheet

private struct ReplySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String
    let isDisabled: Bool
    let isStreaming: Bool
    let hasAgent: Bool
    let agent: Agent?
    let availableCommands: [SlashCommand]
    let onSend: (String?) -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool
    @State private var showFilePicker = false
    @State private var selectedModelId: String?
    @State private var attachedFiles: [String] = []
    @State private var slashCandidates: [SlashCommand] = []
    @State private var hasPendingSlashCommand: Bool = false

    private var resolvedModelId: String? {
        if let selectedModelId, !selectedModelId.isEmpty { return selectedModelId }
        if let current = agent?.currentModel, !current.isEmpty { return current }
        return nil
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isDisabled && !isStreaming
    }

    /// If `text` is `/<word>` and nothing else, returns the prefix after `/`.
    /// Returns nil when the text does not match.
    private var slashPrefixInProgress: String? {
        let trimmed = text
        guard let first = trimmed.first, first == "/" else { return nil }
        let rest = trimmed.dropFirst()
        guard rest.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            return nil
        }
        return String(rest)
    }

    /// True when the composer currently holds `/<knownName>` (optionally
    /// followed by a space + argument). Drives the send-button emphasis.
    private var textMatchesKnownCommand: Bool {
        guard text.hasPrefix("/") else { return false }
        let afterSlash = text.dropFirst()
        let head = afterSlash.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? String(afterSlash)
        guard !head.isEmpty else { return false }
        return availableCommands.contains(where: { $0.name == head })
    }

    /// Hint to display below the composer once a command with an input
    /// hint has been inserted but the user hasn't typed the argument yet.
    private var activeInputHint: String? {
        guard hasPendingSlashCommand, text.hasPrefix("/") else { return nil }
        for cmd in availableCommands {
            let prefix = "/\(cmd.name) "
            if text == prefix, !cmd.inputHint.isEmpty {
                return cmd.inputHint
            }
        }
        return nil
    }

    private func recomputeSlashCandidates() {
        if let prefix = slashPrefixInProgress {
            let lower = prefix.lowercased()
            slashCandidates = availableCommands
                .filter { $0.name.lowercased().hasPrefix(lower) }
        } else {
            slashCandidates = []
        }
        hasPendingSlashCommand = textMatchesKnownCommand
    }

    var body: some View {
        VStack(spacing: 0) {
            if isStreaming {
                Spacer()
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Agent is working…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: { onCancel(); dismiss() }) {
                    Label("Stop Agent", systemImage: "stop.fill")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .liquidGlass(in: Capsule(), tint: .red)
                }
                .buttonStyle(.plain)
                .padding()
            } else {
                // Immersive text editor — no title, just write
                ZStack(alignment: .bottom) {
                    TextEditor(text: $text)
                        .focused($isFocused)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("Send a message…")
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 21)
                                    .padding(.top, 20)
                                    .allowsHitTesting(false)
                            }
                        }
                        .onChange(of: text) { _, _ in
                            recomputeSlashCandidates()
                        }
                        .onChange(of: availableCommands) { _, _ in
                            recomputeSlashCandidates()
                        }

                    if !slashCandidates.isEmpty {
                        SlashCommandsPopup(
                            candidates: slashCandidates,
                            onTap: { cmd in
                                text = "/\(cmd.name) "
                                slashCandidates = []
                                hasPendingSlashCommand = true
                            }
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .animation(.easeInOut(duration: 0.15), value: slashCandidates)
                    }
                }

                if let hint = activeInputHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 2)
                }

                // Attached files
                if !attachedFiles.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(attachedFiles, id: \.self) { file in
                                HStack(spacing: 4) {
                                    Image(systemName: "doc").font(.caption)
                                    Text(file.split(separator: "/").last.map(String.init) ?? file)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Button { attachedFiles.removeAll { $0 == file } } label: {
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
                    .padding(.bottom, 4)
                }

                // Bottom toolbar
                HStack(spacing: 12) {
                    Button { dismiss() } label: { Image(systemName: "chevron.down").font(.title3) }

                    Spacer()

                    Button { showFilePicker = true } label: { Image(systemName: "paperclip").font(.title3) }

                    if hasAgent, let agent, !agent.availableModels.isEmpty {
                        let models = agent.availableModels
                        let pickerLabel = models.first(where: { $0.id == resolvedModelId })?.displayName ?? "Default"
                        Menu {
                            ForEach(models) { model in
                                Button {
                                    selectedModelId = model.id
                                } label: {
                                    if model.id == resolvedModelId {
                                        Label(model.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(model.displayName)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "cpu")
                                    .font(.caption)
                                Text(pickerLabel)
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .liquidGlass(in: Capsule())
                        }
                    }

                    Button {
                        onSend(resolvedModelId)
                        hasPendingSlashCommand = false
                        dismiss()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(hasPendingSlashCommand && canSend ? Color.white : Color.primary)
                            .frame(width: 40, height: 40)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .modifier(SendButtonGlassModifier(emphasized: hasPendingSlashCommand && canSend))
                    .disabled(!canSend)
                    .opacity(canSend ? 1 : 0.4)
                    .animation(.easeInOut(duration: 0.15), value: hasPendingSlashCommand)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .onAppear { isFocused = true }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls {
                    let name = url.lastPathComponent
                    if !attachedFiles.contains(name) { attachedFiles.append(name) }
                }
            }
        }
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

// MARK: - AgentSettingsSheet

private struct AgentSettingsSheet: View {
    let agent: Agent
    let onSync: () -> Void
    var isSyncing: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Agent") {
                    LabeledContent("ID", value: agent.agentId)
                    LabeledContent("Type", value: agent.agentTypeLabel)
                    HStack { Text("Status"); Spacer(); StatusBadge(status: agent.status) }
                    LabeledContent("Worktree", value: agent.worktree)
                }
                if !agent.branch.isEmpty {
                    Section("Git") {
                        LabeledContent("Branch", value: agent.branch)
                    }
                }
                Section {
                    Button {
                        onSync()
                    } label: {
                        HStack {
                            Label("Sync History", systemImage: "arrow.clockwise")
                            Spacer()
                            if isSyncing {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isSyncing)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - RecordButton

private struct RecordButton: View {
    let voiceRecorder: VoiceRecorder
    @State private var spinning = false

    private var isRecording: Bool { voiceRecorder.state == .recording }

    var body: some View {
        Button {
            switch voiceRecorder.state {
            case .recording: voiceRecorder.stopRecording()
            // idle / done / denied / error all kick off a fresh recording.
            case .idle, .done, .denied, .error: voiceRecorder.startRecording()
            }
        } label: {
            ZStack {
                // Spinning ring when recording
                if isRecording {
                    Circle()
                        .trim(from: 0, to: 0.7)
                        .stroke(Color.red, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: 46, height: 46)
                        .rotationEffect(.degrees(spinning ? 360 : 0))
                        .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
                        .onAppear { spinning = true }
                        .onDisappear { spinning = false }
                }

                Image(systemName: isRecording ? "mic.fill" : "mic")
                    .font(.body)
                    .foregroundStyle(isRecording ? .red : .primary)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
        .liquidGlass(in: Circle())
        .animation(.easeInOut(duration: 0.2), value: isRecording)
    }
}

