import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Speech
import AVFoundation
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
    @State private var voiceRecorder = VoiceRecorder()

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
                GlassCircleButton(icon: "chevron.up", size: 32, iconFont: .caption) { goUp() }
                    .disabled(!canGoUp)
                GlassCircleButton(icon: "chevron.down", size: 32, iconFont: .caption) { goDown() }
                    .disabled(!canGoDown)
            }
        }
        .toolbar(.hidden, for: .bottomBar)
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

                // Toolbar
                HStack(spacing: 12) {
                    GlassCircleButton(icon: "pin") {}
                    GlassCircleButton(icon: "person.2") { showMembers = true }
                    Spacer()
                    // Mic button
                    RecordButton(voiceRecorder: voiceRecorder)
                        .disabled(viewModel.agent.isActive)
                    Spacer()
                    GlassCircleButton(icon: "gearshape") { showSettings = true }
                    if viewModel.agent.isActive {
                        GlassCircleButton(icon: "stop.fill") { Task { try? await viewModel.cancelTask() } }
                    } else {
                        GlassCircleButton(icon: "arrowshape.turn.up.left") { showReplySheet = true }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .sheet(isPresented: $showReplySheet) {
            ReplySheet(text: $promptText,
                       isDisabled: !viewModel.agent.isIdle,
                       isStreaming: viewModel.isStreaming,
                       onSend: {
                           let t = promptText; promptText = ""
                           Task { try? await viewModel.sendPrompt(t, modelContext: modelContext) }
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
    @AppStorage("selectedModel") private var selectedModel = "Sonnet"
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
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .liquidGlass(in: Capsule(), tint: .red)
                }
                .buttonStyle(.plain)
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
                HStack(spacing: 12) {
                    GlassCircleButton(icon: "chevron.down") { dismiss() }

                    Spacer()

                    GlassCircleButton(icon: "paperclip") { showFilePicker = true }

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
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .liquidGlass(in: Capsule())
                    }

                    Button {
                        onSend()
                        dismiss()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                            .frame(width: 40, height: 40)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .liquidGlass(in: Circle())
                    .disabled(!canSend)
                    .opacity(canSend ? 1 : 0.4)
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
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - RecordButton

private struct RecordButton: View {
    let voiceRecorder: VoiceRecorder
    @State private var wavePhase: CGFloat = 0

    private var isRecording: Bool { voiceRecorder.state == .recording }

    var body: some View {
        Button {
            switch voiceRecorder.state {
            case .idle: voiceRecorder.startRecording()
            case .recording: voiceRecorder.stopRecording()
            case .done: voiceRecorder.startRecording()
            }
        } label: {
            ZStack {
                if isRecording {
                    // Waveform rings
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .stroke(Color.red.opacity(0.3 - Double(i) * 0.08), lineWidth: 2)
                            .frame(
                                width: 40 + CGFloat(i) * 12 * CGFloat(voiceRecorder.audioLevel + 0.3),
                                height: 40 + CGFloat(i) * 12 * CGFloat(voiceRecorder.audioLevel + 0.3)
                            )
                            .animation(.easeOut(duration: 0.15), value: voiceRecorder.audioLevel)
                    }
                }
                Image(systemName: isRecording ? "mic.fill" : "mic")
                    .font(.body)
                    .foregroundStyle(isRecording ? .white : .primary)
                    .frame(width: 40, height: 40)
                    .background(isRecording ? AnyShapeStyle(Color.red) : AnyShapeStyle(.clear), in: Circle())
                    .contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
        .liquidGlass(in: Circle())
        .animation(.easeInOut(duration: 0.2), value: isRecording)
    }
}

// MARK: - VoiceRecorder

@Observable @MainActor
final class VoiceRecorder {
    enum State { case idle, recording, done }

    private(set) var state: State = .idle
    private(set) var transcribedText: String?
    private(set) var audioLevel: Float = 0

    private var audioEngine: AVAudioEngine?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?

    func startRecording() {
        transcribedText = nil
        state = .recording

        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            Task { @MainActor in
                guard authStatus == .authorized else {
                    self?.state = .idle
                    return
                }
                self?.beginAudioSession()
            }
        }
    }

    private func beginAudioSession() {
        let recognizer = SFSpeechRecognizer(locale: Locale.current)
        guard let recognizer, recognizer.isAvailable else { state = .idle; return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.recognitionRequest = request

        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            // Calculate audio level for waveform visualization
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frameLength { sum += abs(channelData[i]) }
            let avg = sum / Float(max(frameLength, 1))
            let level = min(max(avg * 5, 0), 1) // normalize to 0...1
            Task { @MainActor in self?.audioLevel = level }
        }

        audioEngine.prepare()
        try? audioEngine.start()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                if let result {
                    self?.transcribedText = result.bestTranscription.formattedString
                }
                if error != nil || (result?.isFinal == true) {
                    self?.finishAudio()
                }
            }
        }
    }

    func stopRecording() {
        recognitionRequest?.endAudio()
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        // State transitions to .done when recognition finishes via the callback
        // But set a fallback in case recognition is instant
        if state == .recording {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                if state == .recording { state = .done }
            }
        }
    }

    func reset() {
        finishAudio()
        transcribedText = nil
        state = .idle
    }

    private func finishAudio() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()
        audioEngine = nil
        recognitionTask = nil
        recognitionRequest = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if state == .recording { state = .done }
    }
}
