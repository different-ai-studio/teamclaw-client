import SwiftUI
import SwiftData
import AMUXCore

public struct WorkItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let pairing: PairingManager
    let connectionMonitor: ConnectionMonitor
    let teamclawService: TeamclawService?

    @State private var workItems: [WorkItem] = []
    @State private var showCreate = false

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
            .task { loadWorkItems() }
            .sheet(isPresented: $showCreate) {
                CreateWorkItemSheet(teamclawService: teamclawService) {
                    loadWorkItems()
                }
            }
        }
    }

    private func loadWorkItems() {
        let descriptor = FetchDescriptor<WorkItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        workItems = (try? modelContext.fetch(descriptor)) ?? []
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

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $text)
                    .focused($isFocused)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Describe the work item…")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 21)
                                .padding(.top, 20)
                                .allowsHitTesting(false)
                        }
                    }

                HStack {
                    Spacer()
                    Button {
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
