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

    let allAgentIds: [String]
    @Binding var navigationPath: [String]

    public init(agent: Agent, mqtt: MQTTService, deviceId: String, peerId: String,
                allAgentIds: [String], navigationPath: Binding<[String]>) {
        _viewModel = State(initialValue: AgentDetailViewModel(
            agent: agent, mqtt: mqtt, deviceId: deviceId, peerId: peerId))
        self.allAgentIds = allAgentIds
        self._navigationPath = navigationPath
    }

    private var currentIndex: Int? {
        allAgentIds.firstIndex(of: viewModel.agent.agentId)
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
                    Text("Daemon offline").font(.caption)
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .liquidGlass(in: Rectangle(), interactive: false)
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

                        ForEach(viewModel.events, id: \.id) { event in
                            EventBubbleView(
                                event: event,
                                onGrant: { id in Task { try? await viewModel.grantPermission(requestId: id) } },
                                onDeny: { id in Task { try? await viewModel.denyPermission(requestId: id) } }
                            ).id(event.id)
                        }

                        if viewModel.isStreaming {
                            StreamingTextView(content: viewModel.streamingText)
                                .id("streaming")
                        }

                        if viewModel.agent.isActive {
                            TypingIndicatorView()
                                .id("typing")
                        }

                        Color.clear.frame(height: 8).id("bottom")
                    }
                    .padding(.top, 8)
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
        .navigationTitle({
            if !viewModel.agent.sessionTitle.isEmpty { return viewModel.agent.sessionTitle }
            let wt = viewModel.agent.worktree
            if wt.isEmpty { return viewModel.agent.agentId }
            let last = wt.split(separator: "/").last.map(String.init) ?? wt
            return last == "." ? viewModel.agent.agentId : last
        }())
        .navigationBarTitleDisplayMode(.inline)
        // Top right: prev/next (NetNewsWire ▲▼)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button(action: goUp) { Image(systemName: "chevron.up") }.disabled(!canGoUp)
                Button(action: goDown) { Image(systemName: "chevron.down") }.disabled(!canGoDown)
            }
        }
        // Bottom: [Pin][Collab] ··· [Voice] ··· [Settings][Reply/Stop]
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {} label: { Image(systemName: "pin") }
                Button { showMembers = true } label: { Image(systemName: "person.2") }
                Spacer()
                Button {} label: { Image(systemName: "mic") }
                    .disabled(viewModel.agent.isActive)
                Spacer()
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                if viewModel.agent.isActive {
                    Button { Task { try? await viewModel.cancelTask() } } label: {
                        Image(systemName: "stop.fill")
                            .foregroundStyle(.primary)
                    }
                } else {
                    Button { showReplySheet = true } label: {
                        Image(systemName: "arrowshape.turn.up.left")
                    }
                }
            }
        }
        .sheet(isPresented: $showReplySheet) {
            ReplySheet(text: $promptText,
                       isDisabled: !viewModel.agent.isIdle,
                       isStreaming: viewModel.isStreaming,
                       onSend: {
                           let t = promptText; promptText = ""
                           Task { try? await viewModel.sendPrompt(t) }
                       },
                       onCancel: { Task { try? await viewModel.cancelTask() } })
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showSettings) {
            AgentSettingsSheet(
                agent: viewModel.agent,
                onSync: { Task { try? await viewModel.requestFullSync(modelContext: modelContext) } },
                isSyncing: viewModel.isSyncing
            )
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showMembers) {
            MemberListView(mqtt: viewModel.mqttRef, deviceId: viewModel.deviceIdRef, peerId: viewModel.peerIdRef,
                           selected: Set(collaborators.map(\.memberId))) { selected in
                collaborators = selected
            }
        }
        .tint(.primary)
        .task { viewModel.start(modelContext: modelContext) }
        .onDisappear { viewModel.stop() }
    }
}

// MARK: - ReplySheet

private struct ReplySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String
    let isDisabled: Bool
    let isStreaming: Bool
    let onSend: () -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool
    @State private var showFilePicker = false
    @State private var selectedModel = "Sonnet"
    @State private var attachedFiles: [String] = []

    private let models = ["Haiku", "Sonnet", "Opus"]

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isDisabled && !isStreaming
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
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.red, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding()
            } else {
                // Immersive text editor — no title, just write
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
                HStack(spacing: 16) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.body)
                    }

                    Spacer()

                    Button { showFilePicker = true } label: {
                        Image(systemName: "paperclip")
                            .font(.body)
                    }

                    Menu {
                        ForEach(models, id: \.self) { model in
                            Button {
                                selectedModel = model
                            } label: {
                                Label(model, systemImage: selectedModel == model ? "checkmark" : "")
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "cpu")
                                .font(.caption)
                            Text(selectedModel)
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                    }

                    Button {
                        onSend()
                        dismiss()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(canSend ? .primary : Color(.systemGray4))
                    }
                    .disabled(!canSend)
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
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
