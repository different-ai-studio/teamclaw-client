import SwiftUI
import SwiftData
import AMUXCore
import PhotosUI

public struct WorkItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let pairing: PairingManager
    let connectionMonitor: ConnectionMonitor
    let teamclawService: TeamclawService?

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

    public init(pairing: PairingManager, connectionMonitor: ConnectionMonitor, teamclawService: TeamclawService? = nil) {
        self.pairing = pairing
        self.connectionMonitor = connectionMonitor
        self.teamclawService = teamclawService
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

private struct AttachedImage: Identifiable {
    let id = UUID()
    let image: UIImage
    let fileName: String
}

/// Downscales a picked image to a preview size suitable for the chip strip.
/// The original bytes are discarded when the sheet dismisses; storing only
/// a thumbnail keeps peak memory ≪ 1 MB per chip instead of tens of MB.
private func downscaleForChip(_ image: UIImage) -> UIImage {
    let maxDim: CGFloat = 256
    let size = image.size
    let scale = min(maxDim / size.width, maxDim / size.height, 1)
    if scale >= 1 { return image }
    let newSize = CGSize(width: size.width * scale, height: size.height * scale)
    let renderer = UIGraphicsImageRenderer(size: newSize)
    return renderer.image { _ in
        image.draw(in: CGRect(origin: .zero, size: newSize))
    }
}

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

    @State private var attachedImages: [AttachedImage] = []
    @State private var photoPickerItems: [PhotosPickerItem] = []

    private var canSend: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || !attachedImages.isEmpty) && !isSending
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

                if !attachedImages.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(attachedImages) { chip in
                                imageChip(chip)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .frame(height: 76)
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

                    PhotosPicker(selection: $photoPickerItems, maxSelectionCount: 5, matching: .images) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.body)
                            .foregroundStyle(.primary)
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
            .onChange(of: photoPickerItems) { _, newItems in
                Task {
                    // Load all selections into a local buffer, then append
                    // atomically on the main actor. Prevents out-of-order
                    // interleaving if the picker is reopened rapidly.
                    var loaded: [AttachedImage] = []
                    for item in newItems {
                        guard let data = try? await item.loadTransferable(type: Data.self),
                              let img = UIImage(data: data) else { continue }
                        let thumb = downscaleForChip(img)
                        let name = "img-\(UUID().uuidString.prefix(6).lowercased()).png"
                        loaded.append(AttachedImage(image: thumb, fileName: name))
                    }
                    await MainActor.run {
                        attachedImages.append(contentsOf: loaded)
                        photoPickerItems.removeAll()
                    }
                }
            }
        }
    }

    private func imageChip(_ chip: AttachedImage) -> some View {
        Image(uiImage: chip.image)
            .resizable()
            .scaledToFill()
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topTrailing) {
                Button {
                    attachedImages.removeAll { $0.id == chip.id }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.white, .black.opacity(0.7))
                        .padding(4)
                }
                .buttonStyle(.plain)
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
        var finalDesc = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !attachedImages.isEmpty {
            let refs = attachedImages.map { "![\($0.fileName)](placeholder://\($0.fileName))" }
            if !finalDesc.isEmpty { finalDesc += "\n\n" }
            finalDesc += refs.joined(separator: "\n")
        }
        isSending = true
        Task {
            let ok = await teamclawService?.createWorkItem(description: finalDesc) ?? false
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
