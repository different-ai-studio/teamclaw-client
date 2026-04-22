import SwiftUI
import SwiftData
import AMUXCore

public struct TaskDetailView: View {
    let taskID: String
    @Bindable var taskStore: TaskStore
    let sessionViewModel: SessionListViewModel
    let teamclawService: TeamclawService?
    let mqtt: MQTTService
    let deviceId: String
    let peerId: String
    @Binding var navigationPath: [String]

    @Query(filter: #Predicate<CachedActor> { $0.actorType == "member" },
           sort: \CachedActor.displayName)
    private var members: [CachedActor]

    @State private var showNewSession = false
    @State private var showEdit = false

    public init(
        taskID: String,
        taskStore: TaskStore,
        sessionViewModel: SessionListViewModel,
        teamclawService: TeamclawService?,
        mqtt: MQTTService,
        deviceId: String,
        peerId: String,
        navigationPath: Binding<[String]>
    ) {
        self.taskID = taskID
        self.taskStore = taskStore
        self.sessionViewModel = sessionViewModel
        self.teamclawService = teamclawService
        self.mqtt = mqtt
        self.deviceId = deviceId
        self.peerId = peerId
        self._navigationPath = navigationPath
    }

    private var item: TaskRecord? {
        taskStore.task(id: taskID)
    }

    private var creatorLabel: String {
        guard let item else { return "—" }
        guard !item.createdByActorID.isEmpty else { return "—" }
        if let member = members.first(where: { $0.actorId == item.createdByActorID }) {
            return member.displayName
        }
        return "Unknown"
    }

    public var body: some View {
        Group {
            if let item {
                List {
                    Section {
                        Text(item.displayTitle)
                            .font(.title2.weight(.semibold))
                            .textSelection(.enabled)
                    }

                    Section("Status") {
                        HStack(spacing: 8) {
                            statusPill("Open", value: "open", item: item)
                            statusPill("In Progress", value: "in_progress", item: item)
                            statusPill("Done", value: "done", item: item)
                        }
                        .padding(.vertical, 4)
                    }

                    if !item.description.isEmpty {
                        Section("Description") {
                            Text(item.description)
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    Section("Info") {
                        LabeledContent("Created by", value: creatorLabel)
                        LabeledContent("Created", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .navigationTitle("Task")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .tabBar)
                .toolbar {
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Button {
                            showEdit = true
                        } label: {
                            Image(systemName: "pencil")
                                .font(.title3)
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Edit task")

                        Button {
                            showNewSession = true
                        } label: {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.title3)
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Create session")
                    }
                }
                .sheet(isPresented: $showEdit) {
                    EditTaskSheet(taskStore: taskStore, task: item)
                }
                .sheet(isPresented: $showNewSession) {
                    NewSessionSheet(
                        mqtt: mqtt,
                        deviceId: deviceId,
                        peerId: peerId,
                        teamclawService: teamclawService,
                        viewModel: sessionViewModel,
                        preselectedTaskId: item.id,
                        onSessionCreated: { sessionKey in
                            showNewSession = false
                            navigationPath.append(sessionKey)
                        }
                    )
                }
            } else {
                ContentUnavailableView("Task Not Found", systemImage: "checklist")
            }
        }
    }

    private func statusPill(_ label: String, value: String, item: TaskRecord) -> some View {
        let selected = item.status == value
        return Button {
            Task {
                await taskStore.updateTask(
                    taskID: item.id,
                    title: item.title,
                    description: item.description,
                    status: value,
                    workspaceID: item.workspaceID
                )
            }
        } label: {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : Color.clear)
                .clipShape(Capsule())
                .overlay(
                    Capsule().strokeBorder(selected ? Color.clear : Color.secondary.opacity(0.4), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
