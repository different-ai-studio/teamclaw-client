import SwiftUI
import SwiftData
import AMUXCore

struct SidebarView: View {
    @Binding var selection: SidebarItem?
    let members: [Member]
    let mqtt: MQTTService?
    let deviceId: String
    let peerId: String

    @Query(sort: \CollabSession.lastMessageAt, order: .reverse)
    private var sessions: [CollabSession]

    @Query(filter: #Predicate<WorkItem> { $0.status != "done" })
    private var openTasks: [WorkItem]

    @Query private var allMessages: [SessionMessage]

    @Query(sort: \Workspace.displayName)
    private var workspaces: [Workspace]

    @State private var showAddWorkspace = false

    var body: some View {
        List(selection: $selection) {
            Section("Functions") {
                FunctionRow(function: .sessions, count: sessions.count)
                    .tag(SidebarItem.function(.sessions))

                FunctionRow(function: .tasks, count: openTasks.count)
                    .tag(SidebarItem.function(.tasks))
            }

            Section {
                ForEach(workspaces, id: \.workspaceId) { workspace in
                    WorkspaceRow(workspace: workspace)
                        .contextMenu {
                            if mqtt != nil {
                                Button(role: .destructive) {
                                    removeWorkspace(workspace.workspaceId)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                }
            } header: {
                HStack(spacing: 4) {
                    Text("Workspaces")
                    Spacer()
                    Button {
                        showAddWorkspace = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(mqtt == nil)
                    .help(mqtt == nil ? "Connect to daemon to add workspaces" : "Add workspace")
                    .popover(isPresented: $showAddWorkspace, arrowEdge: .trailing) {
                        if let mqtt {
                            AddWorkspacePopover(
                                mqtt: mqtt,
                                deviceId: deviceId,
                                peerId: peerId,
                                isPresented: $showAddWorkspace
                            )
                        }
                    }
                }
            }

            Section("Members") {
                ForEach(MemberGrouping.grouped(members)) { group in
                    DisclosureGroup {
                        ForEach(group.members) { member in
                            MemberRow(
                                member: member,
                                sessionCount: MemberGrouping.coSessionCount(
                                    for: member,
                                    sessionSenders: sessionSenders
                                )
                            )
                            .tag(SidebarItem.member(memberId: member.memberId))
                        }
                    } label: {
                        Label(group.department, systemImage: "folder")
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// Derives a [sessionId: Set<senderActorId>] map from all loaded messages.
    private var sessionSenders: [String: Set<String>] {
        var map: [String: Set<String>] = [:]
        for message in allMessages where !message.senderActorId.isEmpty {
            map[message.sessionId, default: []].insert(message.senderActorId)
        }
        return map
    }

    private func removeWorkspace(_ workspaceId: String) {
        guard let mqtt else { return }
        Task {
            var envelope = Amux_DeviceCommandEnvelope()
            envelope.deviceID = deviceId
            envelope.peerID = peerId
            envelope.commandID = UUID().uuidString
            envelope.timestamp = Int64(Date().timeIntervalSince1970)
            var remove = Amux_RemoveWorkspace()
            remove.workspaceID = workspaceId
            var cmd = Amux_DeviceCollabCommand()
            cmd.command = .removeWorkspace(remove)
            envelope.command = cmd

            if let data = try? ProtoMQTTCoder.encode(envelope) {
                try? await mqtt.publish(topic: "amux/\(deviceId)/collab", payload: data)
            }
        }
    }
}

private struct FunctionRow: View {
    let function: SidebarFunction
    let count: Int

    var body: some View {
        HStack {
            Label(function.title, systemImage: function.systemImage)
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

private struct WorkspaceRow: View {
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.displayName)
                    .font(.body)
                if !workspace.path.isEmpty {
                    Text(workspace.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct MemberRow: View {
    let member: Member
    let sessionCount: Int

    var body: some View {
        HStack(spacing: 8) {
            AvatarCircle(seed: member.memberId, initial: initial)
                .frame(width: 18, height: 18)
            Text(member.displayName)
            Spacer()
            if sessionCount > 0 {
                Text("\(sessionCount)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var initial: String {
        member.displayName.first.map { String($0).uppercased() } ?? "?"
    }
}

/// Small color-hashed avatar circle. Used by sidebar members and (later) list rows.
struct AvatarCircle: View {
    let seed: String
    let initial: String

    var body: some View {
        Circle()
            .fill(LinearGradient(
                colors: gradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .overlay(
                Text(initial)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }

    private var gradientColors: [Color] {
        let hash = abs(seed.hashValue)
        let hue = Double(hash % 360) / 360.0
        return [
            Color(hue: hue, saturation: 0.6, brightness: 0.85),
            Color(hue: hue, saturation: 0.7, brightness: 0.55),
        ]
    }
}

// MARK: - Add Workspace Popover

private struct AddWorkspacePopover: View {
    let mqtt: MQTTService
    let deviceId: String
    let peerId: String
    @Binding var isPresented: Bool

    @State private var newPath = ""
    @State private var errorMessage: String?
    @State private var isAdding = false
    @FocusState private var isPathFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Workspace")
                .font(.headline)

            TextField("Directory path (e.g. /Users/me/project)", text: $newPath)
                .textFieldStyle(.roundedBorder)
                .focused($isPathFocused)
                .onSubmit { addWorkspace() }
                .frame(minWidth: 320)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button(isAdding ? "Adding\u{2026}" : "Add") {
                    addWorkspace()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isAdding || newPath.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .onAppear { isPathFocused = true }
    }

    private func addWorkspace() {
        let path = newPath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return }

        isAdding = true
        errorMessage = nil

        Task {
            var envelope = Amux_DeviceCommandEnvelope()
            envelope.deviceID = deviceId
            envelope.peerID = peerId
            envelope.commandID = UUID().uuidString
            envelope.timestamp = Int64(Date().timeIntervalSince1970)
            var add = Amux_AddWorkspace()
            add.path = path
            var cmd = Amux_DeviceCollabCommand()
            cmd.command = .addWorkspace(add)
            envelope.command = cmd

            do {
                let data = try ProtoMQTTCoder.encode(envelope)
                try await mqtt.publish(topic: "amux/\(deviceId)/collab", payload: data)
            } catch {
                await MainActor.run {
                    isAdding = false
                    errorMessage = "Failed to send: \(error.localizedDescription)"
                }
                return
            }

            let stream = mqtt.messages()
            let collabTopic = "amux/\(deviceId)/collab"
            let deadline = Date().addingTimeInterval(10)
            for await msg in stream {
                if Date() > deadline { break }
                if msg.topic == collabTopic,
                   let dce = try? ProtoMQTTCoder.decode(Amux_DeviceCollabEvent.self, from: msg.payload),
                   case .workspaceResult(let result) = dce.event,
                   result.commandID == envelope.commandID {
                    await MainActor.run {
                        isAdding = false
                        if result.success {
                            newPath = ""
                            errorMessage = nil
                            isPresented = false
                        } else {
                            errorMessage = result.error
                        }
                    }
                    return
                }
            }

            await MainActor.run {
                isAdding = false
                errorMessage = "Timed out waiting for response"
            }
        }
    }
}
