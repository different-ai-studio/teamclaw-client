import SwiftUI
import SwiftData
import AMUXCore
import AMUXSharedUI

// MARK: - RuntimeDetailView (iMessage-style chat detail)

public struct RuntimeDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: RuntimeDetailViewModel
    @State private var promptText = ""
    @State private var selectedModelId: String?
    @State private var attachments: [URL] = []
    @State private var showSettings = false
    @State private var showMembers = false
    @State private var collaborators: [CachedActor] = []
    @State private var voiceRecorder = VoiceRecorder(contextualStrings: [
        "Claude", "Claude Code", "Sonnet", "Opus", "Haiku",
        "MQTT", "protobuf", "SwiftUI", "SwiftData",
        "agent", "daemon", "worktree", "workspace",
        "commit", "push", "merge", "pull request",
        "API", "JSON", "YAML", "REST", "gRPC",
    ])

    let connectedAgentsStore: ConnectedAgentsStore?

    public init(runtime: Runtime, mqtt: MQTTService, peerId: String,
                connectedAgentsStore: ConnectedAgentsStore? = nil) {
        _viewModel = State(initialValue: RuntimeDetailViewModel(
            runtime: runtime, mqtt: mqtt, peerId: peerId,
            connectedAgentsStore: connectedAgentsStore))
        self.connectedAgentsStore = connectedAgentsStore
    }

    public init(session: Session, mqtt: MQTTService, peerId: String,
                teamclawService: TeamclawService?,
                connectedAgentsStore: ConnectedAgentsStore? = nil) {
        _viewModel = State(initialValue: RuntimeDetailViewModel(
            runtime: nil, mqtt: mqtt, teamID: session.teamId,
            peerId: peerId, session: session,
            teamclawService: teamclawService,
            connectedAgentsStore: connectedAgentsStore))
        self.connectedAgentsStore = connectedAgentsStore
    }

    private var agentLogoName: String {
        switch viewModel.runtime?.agentType {
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
            if let sendError = viewModel.sendErrorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption)
                    Text(sendError).font(.caption).fontWeight(.medium)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .liquidGlass(in: Capsule(), tint: .red, interactive: false)
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
                                    runtime: viewModel.runtime,
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
                // Any scroll on the chat surface dismisses the keyboard.
                // .interactively (iMessage-style finger-tracks-keyboard)
                // got swallowed by the composer's nested TextField scroll
                // and the SafeAreaInset hosting it; .immediately is more
                // robust and matches the user's expectation that pulling
                // the chat reveals more chat.
                .scrollDismissesKeyboard(.immediately)
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
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { showMembers = true } label: {
                    Image(systemName: "person.2")
                        .font(.title3)
                        .padding(.top, 6)
                        .padding(.trailing, 6)
                        .overlay(alignment: .topTrailing) {
                            if memberBadgeCount > 0 {
                                Text("\(memberBadgeCount)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(.blue, in: Capsule())
                            }
                        }
                }
                .accessibilityIdentifier("runtime.membersButton")

                if viewModel.hasRuntime {
                    Button { showSettings = true } label: {
                        Image(agentLogoName, bundle: .module)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                    }
                    .accessibilityIdentifier("runtime.agentSettingsButton")
                }
            }
        }
        .toolbar(.hidden, for: .bottomBar)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom) {
            SessionComposer(
                promptText: $promptText,
                selectedModelId: $selectedModelId,
                attachments: $attachments,
                voiceRecorder: voiceRecorder,
                runtime: viewModel.runtime,
                // Codex doesn't always flip runtime.status to Active while
                // streaming output, so OR with isStreaming so the stop
                // button still surfaces during the response.
                isAgentActive: viewModel.isActive || viewModel.isStreaming,
                availableCommands: viewModel.availableCommands,
                onSend: {
                    let text = promptText
                    let modelId = resolvedModelId
                    promptText = ""
                    attachments = []
                    Task {
                        try? await viewModel.sendPrompt(text, modelId: modelId, modelContext: modelContext)
                    }
                },
                onCancelTask: {
                    Task { try? await viewModel.cancelTask() }
                }
            )
        }
        .sheet(isPresented: $showSettings) {
            if let runtime = viewModel.runtime {
                RuntimeSettingsSheet(
                    runtime: runtime,
                    onSync: {
                        // Manual Sync History: refresh from both sources.
                        // Supabase fills in finalized turns; daemon catches
                        // anything past the last persisted message id.
                        Task {
                            await viewModel.seedFromSupabaseMessages(modelContext: modelContext)
                            try? await viewModel.requestIncrementalSync(modelContext: modelContext)
                        }
                    },
                    isSyncing: viewModel.isSyncing
                )
                .presentationDetents([.medium])
            }
        }
        .sheet(isPresented: $showMembers) {
            let accessible: Set<String> = {
                var s = Set(connectedAgentsStore?.agents.map(\.id) ?? [])
                if let current = viewModel.runtime?.runtimeId { s.insert(current) }
                return s
            }()
            MemberListView(
                selected: Set(collaborators.map(\.actorId)),
                accessibleAgentIDs: accessible,
                currentPrimaryAgentID: viewModel.runtime?.runtimeId
            ) { selected in
                collaborators = selected
                if !selected.isEmpty {
                    forkToCollab(members: selected)
                }
            }
            .task { await connectedAgentsStore?.reload() }
        }
        .task { viewModel.start(modelContext: modelContext) }
        .onDisappear { viewModel.stop() }
    }

    private var resolvedModelId: String? {
        if let selectedModelId, !selectedModelId.isEmpty { return selectedModelId }
        if let current = viewModel.runtime?.currentModel, !current.isEmpty { return current }
        return nil
    }

    private func forkToCollab(members: [CachedActor]) {
        guard let runtime = viewModel.runtime else { return }
        let daemonDeviceId = viewModel.daemonDeviceIdRef
        guard !daemonDeviceId.isEmpty else { return }
        let summary = runtime.lastOutputSummary.isEmpty
            ? "Forked from agent session: \(runtime.sessionTitle.isEmpty ? runtime.runtimeId : runtime.sessionTitle)"
            : runtime.lastOutputSummary

        var createReq = Teamclaw_CreateSessionRequest()
        createReq.teamID = viewModel.session?.teamId ?? ""
        createReq.title = runtime.sessionTitle.isEmpty
            ? "Collab: \(runtime.worktree.split(separator: "/").last.map(String.init) ?? runtime.runtimeId)"
            : "Collab: \(runtime.sessionTitle)"
        createReq.summary = summary
        createReq.inviteActorIds = members.map(\.actorId)

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = daemonDeviceId
        rpcReq.method = .createSession(createReq)

        let topic = MQTTTopics.deviceRpcRequest(
            teamID: viewModel.session?.teamId ?? "",
            deviceID: daemonDeviceId
        )
        Task {
            if let data = try? rpcReq.serializedData() {
                try? await viewModel.mqttRef.publish(topic: topic, payload: data, retain: false)
            }
        }
    }

    // MARK: - RuntimeSettingsSheet

    private struct RuntimeSettingsSheet: View {
        let runtime: Runtime
        let onSync: () -> Void
        var isSyncing: Bool
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                List {
                    Section("Agent") {
                        LabeledContent("ID", value: runtime.runtimeId)
                        LabeledContent("Type", value: runtime.agentTypeLabel)
                        HStack { Text("Status"); Spacer(); StatusBadge(status: runtime.status) }
                        LabeledContent("Worktree", value: runtime.worktree)
                    }
                    if !runtime.branch.isEmpty {
                        Section("Git") {
                            LabeledContent("Branch", value: runtime.branch)
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
}
