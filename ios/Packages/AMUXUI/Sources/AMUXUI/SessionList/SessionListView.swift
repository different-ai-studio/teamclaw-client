import SwiftUI
import SwiftData
import AMUXCore

// MARK: - SessionListView (NetNewsWire-style)

public struct SessionListView: View {
    let mqtt: MQTTService
    let pairing: PairingManager
    let connectionMonitor: ConnectionMonitor
    var onReconnect: (() -> Void)?
    let teamclawService: TeamclawService?

    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = SessionListViewModel()

    @State private var showSettings = false
    @State private var showWorkItems = false
    @State private var showMembers = false
    @State private var showWorkspaces = false
    @State private var showNewSession = false

    @State private var navigationPath: [String] = []
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    @Namespace private var sheetTransition

    // Edit mode
    @State private var isEditing = false
    @State private var selectedIDs: Set<String> = []

    public init(mqtt: MQTTService, pairing: PairingManager, connectionMonitor: ConnectionMonitor, teamclawService: TeamclawService? = nil, onReconnect: (() -> Void)? = nil) {
        self.mqtt = mqtt
        self.pairing = pairing
        self.connectionMonitor = connectionMonitor
        self.teamclawService = teamclawService
        self.onReconnect = onReconnect
    }

    public var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                // Connection banner
                if mqtt.connectionState == .reconnecting {
                    ConnectionBanner(icon: "arrow.triangle.2.circlepath", text: "Reconnecting…", color: .yellow)
                } else if mqtt.connectionState == .disconnected {
                    Button {
                        onReconnect?()
                    } label: {
                        ConnectionBanner(icon: "bolt.slash.fill", text: "Not Connected · Tap to reconnect", color: .red)
                    }
                    .buttonStyle(.plain)
                } else if !connectionMonitor.daemonOnline {
                    ConnectionBanner(icon: "desktopcomputer", text: "Daemon Offline", color: .orange)
                }

                // Session list content
                SessionListContent(
                    viewModel: viewModel,
                    navigationPath: $navigationPath,
                    isEditing: $isEditing,
                    selectedIDs: $selectedIDs,
                    teamclawService: teamclawService,
                    actorId: "ios-\(pairing.authToken.prefix(6))"
                )
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                // Left: Settings + Work Items as a native toolbar group.
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape").font(.title3).foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    Button { showWorkItems = true } label: {
                        Image(systemName: "checklist").font(.title3).foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
                // Right: Workspaces
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showWorkspaces = true } label: {
                        Image(systemName: "folder").font(.title3).foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
                // Right: Members
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showMembers = true } label: {
                        Image(systemName: "person.2.fill").font(.title3).foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            // Bottom bar: iOS Mail style with animated search expansion
            .safeAreaInset(edge: .bottom) {
                MailStyleBottomBar(
                    searchText: $searchText,
                    isSearchFocused: $isSearchFocused,
                    isEditing: $isEditing,
                    selectedIDs: $selectedIDs,
                    showNewSession: $showNewSession,
                    sheetTransition: sheetTransition,
                    onSearchChanged: { viewModel.searchText = $0 }
                )
            }
            .toolbar(.hidden, for: .bottomBar)
            .navigationDestination(for: String.self) { id in
                if id.hasPrefix("collab:") {
                    let sessionId = String(id.dropFirst("collab:".count))
                    let descriptor = FetchDescriptor<CollabSession>(
                        predicate: #Predicate { $0.sessionId == sessionId }
                    )
                    if let session = (try? modelContext.fetch(descriptor))?.first {
                        AgentDetailView(collabSession: session, mqtt: mqtt,
                                        deviceId: pairing.deviceId,
                                        peerId: "ios-\(pairing.authToken.prefix(6))",
                                        teamclawService: teamclawService,
                                        navigationPath: $navigationPath)
                    } else {
                        Text("Collab session not found")
                    }
                } else if let agent = viewModel.agents.first(where: { $0.agentId == id }) {
                    AgentDetailView(agent: agent, mqtt: mqtt, deviceId: pairing.deviceId,
                                    peerId: "ios-\(pairing.authToken.prefix(6))",
                                    allAgentIds: viewModel.agents.map(\.agentId),
                                    navigationPath: $navigationPath)
                } else {
                    Text("Agent not found")
                }
            }
            .sheet(isPresented: $showWorkItems) {
                WorkItemSheet(pairing: pairing, connectionMonitor: connectionMonitor, teamclawService: teamclawService)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(pairing: pairing,
                             connectionMonitor: connectionMonitor,
                             mqtt: mqtt,
                             sessionViewModel: viewModel)
            }
            .sheet(isPresented: $showWorkspaces) {
                WorkspaceSheet(mqtt: mqtt, deviceId: pairing.deviceId,
                               peerId: "ios-\(pairing.authToken.prefix(6))",
                               viewModel: viewModel)
            }
            .sheet(isPresented: $showMembers) {
                MemberListView(mqtt: mqtt, deviceId: pairing.deviceId,
                              peerId: "ios-\(pairing.authToken.prefix(6))")
            }
            .sheet(isPresented: $showNewSession) {
                NewSessionSheet(mqtt: mqtt, deviceId: pairing.deviceId,
                               peerId: "ios-\(pairing.authToken.prefix(6))",
                               viewModel: viewModel) { agentId in
                    navigationPath.append(agentId)
                }
                .modifier(ZoomTransitionModifier(sourceID: "newSession", namespace: sheetTransition))
            }
            .task {
                viewModel.start(mqtt: mqtt, deviceId: pairing.deviceId, modelContext: modelContext)
            }
            .onChange(of: teamclawService?.sessions.count) {
                viewModel.reloadCollabSessions(modelContext: modelContext)
            }
        }
    }
}

// MARK: - SessionListContent

private struct SessionListContent: View {
    @Bindable var viewModel: SessionListViewModel
    @Binding var navigationPath: [String]
    @Binding var isEditing: Bool
    @Binding var selectedIDs: Set<String>
    let teamclawService: TeamclawService?
    let actorId: String

    private var hasContent: Bool {
        !viewModel.groupedSessions.isEmpty
    }

    var body: some View {
        Group {
            if !hasContent && viewModel.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading sessions…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !hasContent {
                ContentUnavailableView("No Sessions", systemImage: "cpu",
                    description: Text("Start a new session to begin"))
            } else {
                List {
                    ForEach(viewModel.groupedSessions) { group in
                        Section {
                            ForEach(group.items) { item in
                                sessionRow(item)
                            }
                        } header: {
                            Text(group.title)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .textCase(nil)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ item: SessionItem) -> some View {
        switch item {
        case .agent(let agent):
            HStack(spacing: 10) {
                if isEditing {
                    Image(systemName: selectedIDs.contains(agent.agentId) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selectedIDs.contains(agent.agentId) ? .blue : .secondary)
                        .font(.title3)
                        .onTapGesture { toggleSelection(agent.agentId) }
                }
                AgentRowView(agent: agent, workspaceName: workspaceName(for: agent))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isEditing {
                    toggleSelection(agent.agentId)
                } else {
                    navigationPath.append(agent.agentId)
                }
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

        case .collab(let session):
            SessionRowView(session: session)
                .contentShape(Rectangle())
                .onTapGesture {
                    navigationPath.append("collab:\(session.sessionId)")
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        }
    }

    private func workspaceName(for agent: Agent) -> String {
        viewModel.workspaces.first(where: { $0.workspaceId == agent.workspaceId })?.displayName ?? ""
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) }
        else { selectedIDs.insert(id) }
    }
}

// MARK: - AgentRowView (NetNewsWire article row style)

struct AgentRowView: View {
    let agent: Agent
    let workspaceName: String

    @State private var breathe = false

    private var displayTitle: String {
        if !agent.sessionTitle.isEmpty { return agent.sessionTitle }
        return "Untitled Session"
    }

    private var isUnread: Bool { agent.hasUnread }
    private var isRunning: Bool { agent.status == 2 }

    private var avatarInitial: String {
        let name = agent.worktree.isEmpty ? agent.agentId : agent.worktree
        let lastComponent = name.split(separator: "/").last.map(String.init) ?? name
        return String(lastComponent.prefix(1)).uppercased()
    }

    private var avatarColor: Color {
        let colors: [Color] = [.blue, .purple, .orange, .green, .pink, .teal, .indigo, .mint]
        let hash = agent.agentId.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return colors[abs(hash) % colors.count]
    }

    /// Asset name for the agent type logo
    private var agentLogoName: String {
        switch agent.agentType {
        case 1: "ClaudeLogo"
        case 2: "OpenCodeLogo"
        case 3: "CodexLogo"
        default: "ClaudeLogo"
        }
    }

    private func formatTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        if seconds < 604800 { return "\(seconds / 86400)d" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd"
        return formatter.string(from: date)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Left: status dot + avatar
            HStack(spacing: 6) {
                Circle()
                    .fill(isRunning ? Color.red : isUnread ? Color.blue : Color.clear)
                    .frame(width: 8, height: 8)
                    .opacity(isRunning ? (breathe ? 0.3 : 1.0) : 1.0)
                    .animation(
                        isRunning
                            ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                            : .default,
                        value: breathe
                    )
                    .onAppear { breathe = true }

                ZStack {
                    Circle()
                        .fill(avatarColor.gradient)
                        .frame(width: 40, height: 40)
                    Text(avatarInitial)
                        .font(.callout)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                }
            }

            // Right: 3 rows
            VStack(alignment: .leading, spacing: 3) {
                // Row 1: session title (last path component only)
                Text(displayTitle)
                    .font(.body)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                // Row 2: last message (2 lines max)
                if !agent.currentPrompt.isEmpty {
                    Text(agent.currentPrompt)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                // Row 3: agent logo + workspace name (left) + time (right)
                HStack(spacing: 4) {
                    Image(agentLogoName, bundle: .module)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)

                    if !workspaceName.isEmpty {
                        Text(workspaceName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    Text(formatTime(agent.lastEventTime ?? agent.startedAt))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - SessionRowView (collab sessions, same style as AgentRowView)

struct SessionRowView: View {
    let session: CollabSession

    private func formatTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        if seconds < 604800 { return "\(seconds / 86400)d" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd"
        return formatter.string(from: date)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Left: empty dot space + group avatar (same layout as AgentRowView)
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.clear)
                    .frame(width: 8, height: 8)

                ZStack {
                    Circle()
                        .fill(Color.indigo.gradient)
                        .frame(width: 40, height: 40)
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                }
            }

            // Right: 3 rows (same structure as AgentRowView)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title.isEmpty ? "Collab Session" : session.title)
                    .font(.body)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                if !session.lastMessagePreview.isEmpty {
                    Text(session.lastMessagePreview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 4) {
                    Image(systemName: "person.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(session.participantCount)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    Text(formatTime(session.lastMessageAt ?? session.createdAt))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - ConnectionBanner

struct ConnectionBanner: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption)
            Text(text).font(.caption).fontWeight(.medium)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .liquidGlass(in: Capsule())
        .padding(.vertical, 4)
    }
}

// MARK: - StatusBadge

public struct StatusBadge: View {
    let status: Int
    public init(status: Int) { self.status = status }
    public var body: some View {
        Text(label).font(.caption2).fontWeight(.medium)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(color)
            .liquidGlass(in: Capsule(), interactive: false)
    }
    private var label: String {
        switch status { case 1: "Starting"; case 2: "Active"; case 3: "Idle"; case 4: "Error"; case 5: "Stopped"; default: "Unknown" }
    }
    private var color: Color {
        switch status { case 1: .orange; case 2: .green; case 3: .secondary; case 4: .red; default: .secondary }
    }
}

// MARK: - MailStyleBottomBar

private struct MailStyleBottomBar: View {
    @Binding var searchText: String
    var isSearchFocused: FocusState<Bool>.Binding
    @Binding var isEditing: Bool
    @Binding var selectedIDs: Set<String>
    @Binding var showNewSession: Bool
    var sheetTransition: Namespace.ID
    var onSearchChanged: (String) -> Void

    private var isActive: Bool { isSearchFocused.wrappedValue || !searchText.isEmpty }

    var body: some View {
        HStack(spacing: 10) {
            // Left: filter/select button with glass capsule
            if !isActive {
                Button {
                    withAnimation(.spring(duration: 0.25)) {
                        isEditing.toggle()
                        if !isEditing { selectedIDs.removeAll() }
                    }
                } label: {
                    Image(systemName: isEditing ? "checkmark.circle.fill" : "line.3.horizontal.decrease")
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .liquidGlass(in: Circle())
                .transition(.scale.combined(with: .opacity))
            }

            // Center: search capsule
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                TextField("Search", text: $searchText)
                    .font(.subheadline)
                    .focused(isSearchFocused)
                    .onChange(of: searchText) { onSearchChanged(searchText) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .liquidGlass(in: Capsule(), interactive: true)

            // Right: compose OR close with glass capsule
            if isActive {
                Button {
                    searchText = ""
                    isSearchFocused.wrappedValue = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .liquidGlass(in: Circle())
                .transition(.scale.combined(with: .opacity))
            } else {
                Button {
                    showNewSession = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .liquidGlass(in: Circle())
                .modifier(MatchedTransitionSourceModifier(sourceID: "newSession", namespace: sheetTransition))
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .animation(.spring(duration: 0.3), value: isActive)
    }
}

// MARK: - Transition Modifiers

private struct ZoomTransitionModifier: ViewModifier {
    let sourceID: String
    let namespace: Namespace.ID
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else { content }
    }
}

private struct MatchedTransitionSourceModifier: ViewModifier {
    let sourceID: String
    let namespace: Namespace.ID
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.matchedTransitionSource(id: sourceID, in: namespace)
        } else { content }
    }
}
