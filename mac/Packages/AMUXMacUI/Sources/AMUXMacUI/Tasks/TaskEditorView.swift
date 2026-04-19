import SwiftUI
import SwiftData
import AMUXCore

/// Editor sheet hosted by `TaskEditorWindowScene`. Handles both "new task"
/// (input.workItemId == nil) and "edit existing" modes.
struct TaskEditorView: View {
    let input: TaskEditorInput
    let teamclawService: TeamclawService
    let onDone: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query private var allItems: [WorkItem]

    @State private var title: String = ""
    @State private var descriptionText: String = ""
    @State private var status: String = "open"
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var isDirty = false
    @State private var showDiscardAlert = false

    private var isNew: Bool { input.workItemId == nil }

    private var editingItem: WorkItem? {
        guard let id = input.workItemId else { return nil }
        return allItems.first(where: { $0.workItemId == id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New Task" : "Edit Task").font(.title3.weight(.semibold))
            Form {
                TextField("Title", text: $title)
                    .onChange(of: title) { _, _ in isDirty = true }
                TextField("Description", text: $descriptionText, axis: .vertical)
                    .lineLimit(4...8)
                    .onChange(of: descriptionText) { _, _ in isDirty = true }
                Picker("Status", selection: $status) {
                    Text("Open").tag("open")
                    Text("In Progress").tag("in_progress")
                    Text("Done").tag("done")
                }
                .onChange(of: status) { _, _ in isDirty = true }
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    if isDirty { showDiscardAlert = true } else { onDone() }
                }
                .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear(perform: hydrate)
        .alert("Discard changes?", isPresented: $showDiscardAlert) {
            Button("Discard", role: .destructive) { onDone() }
            Button("Keep Editing", role: .cancel) {}
        }
    }

    private func hydrate() {
        guard let item = editingItem else { return }
        title = item.title
        descriptionText = item.itemDescription
        status = item.status.isEmpty ? "open" : item.status
        isDirty = false
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { return }
        isBusy = true
        errorMessage = nil

        if let existing = editingItem {
            existing.title = trimmedTitle
            existing.itemDescription = descriptionText
            existing.status = status
            try? modelContext.save()
            let id = existing.workItemId
            let sid = existing.sessionId
            let newTitle = trimmedTitle
            let newDescription = descriptionText
            let desiredStatus = status
            Task {
                await teamclawService.updateWorkItem(
                    workItemId: id,
                    sessionId: sid,
                    title: newTitle,
                    description: newDescription,
                    status: desiredStatus
                )
                await MainActor.run { isBusy = false; onDone() }
            }
        } else {
            let payload = descriptionText.isEmpty ? trimmedTitle : "\(trimmedTitle)\n\n\(descriptionText)"
            Task {
                let ok = await teamclawService.createWorkItem(description: payload)
                await MainActor.run {
                    isBusy = false
                    if ok { onDone() } else { errorMessage = "Failed to create task. Check daemon connection." }
                }
            }
        }
    }
}
