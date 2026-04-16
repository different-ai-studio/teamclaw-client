import SwiftUI
import SwiftData
import AMUXCore

// MARK: - SessionListView (NetNewsWire-style)

public struct SessionListView: View {
    let mqtt: MQTTService
    let pairing: PairingManager
    let connectionMonitor: ConnectionMonitor

    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = SessionListViewModel()

    @State private var showSettings = false
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

    public init(mqtt: MQTTService, pairing: PairingManager, connectionMonitor: ConnectionMonitor) {
        self.mqtt = mqtt
        self.pairing = pairing
        self.connectionMonitor = connectionMonitor
    }

    public var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                // Connection banner
                if mqtt.connectionState == .reconnecting {
                    ConnectionBanner(icon: "arrow.triangle.2.circlepath", text: "Reconnecting…", color: .yellow)
                } else if mqtt.connectionState == .disconnected {
                    ConnectionBanner(icon: "bolt.slash.fill", text: "Not Connected", color: .red)
                } else if !connectionMonitor.daemonOnline {
                    ConnectionBanner(icon: "desktopcomputer", text: "Daemon Offline", color: .orange)
                }

                // Session list content
                SessionListContent(
                    viewModel: viewModel,
                    navigationPath: $navigationPath,
                    isEditing: $isEditing,
                    selectedIDs: $selectedIDs
                )
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                // Left: Settings
                ToolbarItem(placement: .navigationBarLeading) {
                    GlassCircleButton(icon: "gearshape") { showSettings = true }
                }
                // Right: Workspaces
                ToolbarItem(placement: .navigationBarTrailing) {
                    GlassCircleButton(icon: "folder") { showWorkspaces = true }
                }
                // Right: Members
                ToolbarItem(placement: .navigationBarTrailing) {
                    GlassCircleButton(icon: "person.2.fill") { showMembers = true }
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
            .navigationDestination(for: String.self) { agentId in
                if let agent = viewModel.agents.first(where: { $0.agentId == agentId }) {
                    AgentDetailView(agent: agent, mqtt: mqtt, deviceId: pairing.deviceId,
                                    peerId: "ios-\(pairing.authToken.prefix(6))",
                                    allAgentIds: viewModel.agents.map(\.agentId),
                                    navigationPath: $navigationPath)
                } else {
                    Text("Agent not found")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(pairing: pairing, connectionMonitor: connectionMonitor)
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
        }
    }
}

// MARK: - SessionListContent

private struct SessionListContent: View {
    @Bindable var viewModel: SessionListViewModel
    @Binding var navigationPath: [String]
    @Binding var isEditing: Bool
    @Binding var selectedIDs: Set<String>

    var body: some View {
        Group {
            if viewModel.filteredAgents.isEmpty && viewModel.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading sessions…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.filteredAgents.isEmpty {
                ContentUnavailableView("No Agents", systemImage: "cpu",
                    description: Text("Start a new agent session to begin"))
            } else {
                List {
                    ForEach(viewModel.groupedFilteredAgents) { group in
                        Section {
                            ForEach(group.agents, id: \.agentId) { agent in
                                agentRow(agent)
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
    private func agentRow(_ agent: Agent) -> some View {
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
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                // archive / stop agent
            } label: {
                Label("Stop", systemImage: "stop.circle")
            }
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

    private var displayTitle: String {
        if !agent.sessionTitle.isEmpty { return agent.sessionTitle }
        if agent.worktree.isEmpty { return agent.agentId }
        let last = agent.worktree.split(separator: "/").last.map(String.init) ?? agent.worktree
        return last == "." ? workspaceName.split(separator: "/").last.map(String.init) ?? workspaceName : last
    }

    private var isUnread: Bool { agent.isActive }

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

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Left: unread dot + avatar
            HStack(spacing: 6) {
                Circle()
                    .fill(isUnread ? Color.blue : Color.clear)
                    .frame(width: 8, height: 8)

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

                // Row 3: workspace + agent name (left) + time (right)
                HStack {
                    if !workspaceName.isEmpty {
                        Text(workspaceName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("\u{00B7}")
                            .font(.subheadline)
                            .foregroundStyle(.quaternary)
                    }
                    Text(agent.agentTypeLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    if let time = agent.lastEventTime {
                        Text(time, style: .relative)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Just now")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
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
        HStack(spacing: 12) {
            // Left: filter/select button — hides when search active
            if !isActive {
                GlassCircleButton(
                    icon: isEditing ? "checkmark.circle.fill" : "line.3.horizontal.decrease"
                ) {
                    withAnimation(.spring(duration: 0.25)) {
                        isEditing.toggle()
                        if !isEditing { selectedIDs.removeAll() }
                    }
                }
                .transition(.scale.combined(with: .opacity))
            }

            // Center: search capsule
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.primary)
                    .font(.subheadline)
                TextField("Search", text: $searchText)
                    .font(.subheadline)
                    .focused(isSearchFocused)
                    .onChange(of: searchText) { onSearchChanged(searchText) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .liquidGlass(in: Capsule(), interactive: true)

            // Right: compose OR close
            if isActive {
                GlassCircleButton(icon: "xmark.circle.fill") {
                    searchText = ""
                    isSearchFocused.wrappedValue = false
                }
                .transition(.scale.combined(with: .opacity))
            } else {
                GlassCircleButton(icon: "square.and.pencil") {
                    showNewSession = true
                }
                .modifier(MatchedTransitionSourceModifier(sourceID: "newSession", namespace: sheetTransition))
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .animation(.spring(duration: 0.3), value: isActive)
    }
}

// MARK: - GlassCircleButton

struct GlassCircleButton: View {
    let icon: String
    var size: CGFloat = 40
    var iconFont: Font = .body
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(iconFont)
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .liquidGlass(in: Circle())
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
