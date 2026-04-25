import SwiftUI
import UIKit
import AMUXCore
import AMUXSharedUI

public struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    /// Injected by AMUXApp's `ContentView` via `.environment(onboarding)`.
    /// Read at this scope to gate the anonymous-upgrade banner. Marked
    /// optional so the (unused) macOS shell or any host that forgets to
    /// inject still compiles cleanly.
    @Environment(AppOnboardingCoordinator.self) private var onboarding: AppOnboardingCoordinator?
    let pairing: PairingManager
    let connectedAgentsStore: ConnectedAgentsStore?
    let activeTeam: TeamSummary?
    let onReconnect: (() -> Void)?
    let onSignOut: (() -> Void)?

    @State private var mqttHost: String = ""
    @State private var daemonDeviceID: String = ""
    @State private var saveError: String?

    @State private var supaURL: String = ""
    @State private var supaKey: String = ""
    @State private var supaSaved: Bool = false

    @State private var teamDetails: TeamDetails?
    @State private var teamLoadError: String?

    @State private var showSignOutConfirm = false
    @State private var showUpgradeSheet = false

    public init(pairing: PairingManager,
                connectedAgentsStore: ConnectedAgentsStore?,
                activeTeam: TeamSummary? = nil,
                onReconnect: (() -> Void)? = nil,
                onSignOut: (() -> Void)? = nil) {
        self.pairing = pairing
        self.connectedAgentsStore = connectedAgentsStore
        self.activeTeam = activeTeam
        self.onReconnect = onReconnect
        self.onSignOut = onSignOut
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    private var hasMQTTChanges: Bool {
        mqttHost != pairing.brokerHost ||
        daemonDeviceID != pairing.deviceId
    }

    private var hasSupabaseChanges: Bool {
        supaURL != SupabaseServerStore.currentURL() ||
        supaKey != SupabaseServerStore.currentKey()
    }

    public var body: some View {
        NavigationStack {
            List {
                if let onboarding, onboarding.isAnonymous {
                    Section {
                        Button {
                            showUpgradeSheet = true
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "person.badge.shield.checkmark")
                                    .font(.title2)
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Upgrade your account")
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text("You're signed in anonymously. Attach an email or Apple ID to keep this workspace.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                        }
                        .accessibilityIdentifier("settings.upgradeAccountButton")
                    }
                }

                Section("Team") {
                    if let details = teamDetails {
                        LabeledContent("Name", value: details.name)
                        LabeledContent("Owner", value: details.ownerDisplayName ?? "—")
                        LabeledContent(
                            "Created",
                            value: details.createdAt.formatted(date: .abbreviated, time: .shortened)
                        )
                        HStack {
                            Text("ID")
                            Spacer()
                            Text(details.id)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    } else if activeTeam == nil {
                        Text("No team selected.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if let err = teamLoadError {
                        Text(err).font(.footnote).foregroundStyle(.red)
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }

                Section("MQTT Server") {
                    LabeledField(label: "Host", text: $mqttHost, placeholder: "ai.ucar.cc")
                    LabeledField(label: "Daemon ID", text: $daemonDeviceID, placeholder: "mac-mini-4")

                    if let err = saveError {
                        Text(err).font(.footnote).foregroundStyle(.red)
                    }

                    Button {
                        save()
                    } label: {
                        Text("Save & Reconnect")
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasMQTTChanges || mqttHost.isEmpty)
                }

                Section {
                    LabeledField(label: "URL", text: $supaURL,
                                 placeholder: "https://<ref>.supabase.co")
                    LabeledSecureField(label: "Key", text: $supaKey)

                    if supaSaved {
                        Text("Saved. Relaunch the app to apply.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        SupabaseServerStore.save(url: supaURL, key: supaKey)
                        supaSaved = true
                    } label: {
                        Text("Save")
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!hasSupabaseChanges || supaURL.isEmpty || supaKey.isEmpty)
                } header: {
                    Text("Supabase Server")
                }

                Section("Connected Agents") {
                    if let store = connectedAgentsStore {
                        if store.agents.isEmpty && !store.isLoading {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("No agents connected to you yet.")
                                    .font(.body.weight(.medium))
                                Text("Ask a teammate with admin access to authorize one, or invite a new daemon from the Actors tab.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        } else {
                            ForEach(store.agents) { agent in
                                AgentRow(agent: agent)
                            }
                        }
                        if let err = store.errorMessage {
                            Text(err).font(.footnote).foregroundStyle(.red)
                        }
                    } else {
                        Text("Agent list unavailable.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("\(appVersion) (\(buildNumber))")
                            .foregroundStyle(.secondary)
                            .font(.caption.monospaced())
                    }
                }

                if onSignOut != nil {
                    Section {
                        Button(role: .destructive) {
                            showSignOutConfirm = true
                        } label: {
                            Text("Sign Out")
                                .font(.body.weight(.medium))
                                .frame(maxWidth: .infinity)
                        }
                        .accessibilityIdentifier("settings.signOutButton")
                    }
                }
            }
            .confirmationDialog(
                "Sign out of AMUX?",
                isPresented: $showSignOutConfirm,
                titleVisibility: .visible
            ) {
                Button("Sign Out", role: .destructive) {
                    let action = onSignOut
                    dismiss()
                    action?()
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showUpgradeSheet) {
                if let onboarding {
                    UpgradeAccountSheet(coordinator: onboarding)
                }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.large)
            .task {
                mqttHost = pairing.brokerHost
                daemonDeviceID = pairing.deviceId
                supaURL = SupabaseServerStore.currentURL()
                supaKey = SupabaseServerStore.currentKey()
                await loadTeam()
                await connectedAgentsStore?.reload()
            }
            .refreshable { await connectedAgentsStore?.reload() }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func save() {
        do {
            try pairing.updateMQTTServer(host: mqttHost)
            try pairing.updateDaemonDeviceID(daemonDeviceID)
            saveError = nil
            onReconnect?()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func loadTeam() async {
        guard let team = activeTeam else { return }
        do {
            let repo = try SupabaseTeamRepository()
            teamDetails = try await repo.loadDetails(teamID: team.id)
            teamLoadError = nil
        } catch {
            teamLoadError = error.localizedDescription
        }
    }
}

private struct LabeledField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""

    var body: some View {
        HStack {
            Text(label).frame(width: 80, alignment: .leading)
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct LabeledSecureField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        HStack {
            Text(label).frame(width: 80, alignment: .leading)
            SecureField("", text: $text)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct AgentRow: View {
    let agent: ConnectedAgent

    private var statusColor: Color { agent.isOnline ? .green : .secondary }
    private var statusText: String { agent.isOnline ? "Online" : "Offline" }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.displayName).font(.body.weight(.medium))
                HStack(spacing: 6) {
                    if !agent.agentKind.isEmpty {
                        Text(agent.agentKind)
                    }
                    Text("\u{00B7}")
                    Text(agent.permissionLevel)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(statusText)
                .font(.caption)
                .foregroundStyle(statusColor)
        }
    }
}
