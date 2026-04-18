import SwiftUI
import SwiftData
import AMUXCore

public struct WorkItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let pairing: PairingManager
    let connectionMonitor: ConnectionMonitor
    let teamclawService: TeamclawService?

    @Binding var showSettings: Bool

    // SwiftData-driven list; any mutation from syncWorkItemEvent refreshes
    // the UI without manual reloads.
    @Query(filter: #Predicate<WorkItem> { !$0.archived },
           sort: \WorkItem.createdAt, order: .reverse)
    private var workItems: [WorkItem]

    // Count of archived items for the "Archived (N)" footer row.
    @Query(filter: #Predicate<WorkItem> { $0.archived })
    private var archivedItems: [WorkItem]

    @State private var showCreate = false
    @State private var showArchived = false

    public init(pairing: PairingManager, connectionMonitor: ConnectionMonitor, teamclawService: TeamclawService? = nil, showSettings: Binding<Bool>) {
        self.pairing = pairing
        self.connectionMonitor = connectionMonitor
        self.teamclawService = teamclawService
        self._showSettings = showSettings
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if workItems.isEmpty {
                    ContentUnavailableView("No Work Items", systemImage: "checklist",
                        description: Text("Tap + to create a work item"))
                } else {
                    List {
                        ForEach(workItems, id: \.workItemId) { item in
                            WorkItemRow(item: item)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button {
                                        archiveTapped(item)
                                    } label: {
                                        Label("Archive", systemImage: "archivebox.fill")
                                    }
                                    .tint(.gray)
                                }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Work Items")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showCreate = true } label: {
                        Image(systemName: "plus").font(.title3)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.title3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    if !archivedItems.isEmpty {
                        Button {
                            showArchived = true
                        } label: {
                            HStack {
                                Image(systemName: "archivebox")
                                Text("Archived (\(archivedItems.count))")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .font(.body)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                    Button {
                        dismiss()
                        showSettings = true
                    } label: {
                        HStack {
                            Image(systemName: "gearshape")
                            Text("Settings")
                        }
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                }
            }
            .sheet(isPresented: $showCreate) {
                CreateWorkItemSheet(teamclawService: teamclawService) { }
            }
            .sheet(isPresented: $showArchived) {
                ArchivedWorkItemsView(teamclawService: teamclawService)
            }
        }
    }

    private func archiveTapped(_ item: WorkItem) {
        // Optimistic flip — @Query animates the row out immediately.
        item.archived = true
        try? modelContext.save()
        let id = item.workItemId
        let sessionId = item.sessionId
        Task { await teamclawService?.archiveWorkItem(workItemId: id, sessionId: sessionId, archived: true) }
    }
}

// MARK: - CreateWorkItemSheet

struct CreateWorkItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    let teamclawService: TeamclawService?
    let onCreated: () -> Void

    @State private var text = ""
    @State private var isSending = false
    @FocusState private var isFocused: Bool

    @State private var voiceRecorder = VoiceRecorder(contextualStrings: [
        "AMUX", "agent", "workitem", "claude", "tool", "MQTT", "daemon"
    ])

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    private var isRecording: Bool { voiceRecorder.state == .recording }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .focused($isFocused)
                        .disabled(isRecording)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty && !isRecording {
                                Text("Describe the work item…")
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 21)
                                    .padding(.top, 20)
                                    .allowsHitTesting(false)
                            }
                        }

                    if isRecording {
                        voiceBanner
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        toggleRecording()
                    } label: {
                        Image(systemName: isRecording ? "mic.fill" : "mic")
                            .font(.body)
                            .foregroundStyle(isRecording ? .red : .primary)
                            .frame(width: 40, height: 40)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .liquidGlass(in: Circle())

                    Spacer()

                    Button {
                        send()
                    } label: {
                        if isSending {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 40, height: 40)
                                .contentShape(Circle())
                        }
                    }
                    .buttonStyle(.plain)
                    .liquidGlass(in: Circle())
                    .disabled(!canSend)
                    .opacity(canSend ? 1 : 0.4)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .navigationTitle("New Work Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.title3).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .onAppear { isFocused = true }
        }
    }

    private var voiceBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
                Text("Listening…")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(voiceRecorder.transcript.isEmpty ? "Speak now" : voiceRecorder.transcript)
                .font(.body)
                .foregroundStyle(voiceRecorder.transcript.isEmpty ? .tertiary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private func toggleRecording() {
        switch voiceRecorder.state {
        case .recording:
            voiceRecorder.toggle()   // stops; leaves transcript in place
            let t = voiceRecorder.transcript
            if !t.isEmpty {
                if !text.isEmpty && !text.hasSuffix(" ") && !text.hasSuffix("\n") {
                    text += " "
                }
                text += t
            }
            voiceRecorder.cancel()   // clears transcript, returns to .idle
            isFocused = true
        case .idle, .done, .denied, .error:
            isFocused = false
            voiceRecorder.toggle()
        }
    }

    private func send() {
        let desc = text.trimmingCharacters(in: .whitespacesAndNewlines)
        isSending = true
        Task {
            let ok = await teamclawService?.createWorkItem(description: desc) ?? false
            isSending = false
            if ok {
                onCreated()
                dismiss()
            }
        }
    }
}

// MARK: - WorkItemRow

struct WorkItemRow: View {
    let item: WorkItem

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(item.isDone ? .green : item.isInProgress ? Color.orange : Color.blue)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(2)

                Text(item.statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(item.createdAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
