import SwiftUI
import SwiftData
import AMUXCore

// MARK: - MemberPickerSheet (macOS)
//
// macOS-flavored analog of the iOS MemberListView selection mode. Presented
// as a modal sheet that lets the user multi-select Members to invite into a
// shared session. Unlike the iOS view this is selection-only — browsing and
// invite flows live elsewhere on macOS.
//
// We reuse AMUXCore's MemberListViewModel so the member list stays in sync
// with the retained amux/{deviceId}/members topic the same way iOS does.

struct MemberPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let mqtt: MQTTService
    let deviceId: String

    @State private var viewModel = MemberListViewModel()
    @State private var selectedIDs: Set<String>
    private let onConfirm: ([Member]) -> Void

    init(mqtt: MQTTService, deviceId: String, selected: Set<String>, onConfirm: @escaping ([Member]) -> Void) {
        self.mqtt = mqtt
        self.deviceId = deviceId
        self._selectedIDs = State(initialValue: selected)
        self.onConfirm = onConfirm
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if viewModel.members.isEmpty {
                ContentUnavailableView(
                    "No members yet",
                    systemImage: "person.2",
                    description: Text("Invite teammates from the Members panel to see them here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(viewModel.members, id: \.memberId) { member in
                        selectionRow(member)
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            footer
        }
        .frame(minWidth: 420, idealWidth: 460, minHeight: 360, idealHeight: 440)
        .background(Color(NSColor.windowBackgroundColor))
        .task { viewModel.start(mqtt: mqtt, deviceId: deviceId, modelContext: modelContext) }
    }

    private var header: some View {
        HStack {
            Text("Select Collaborators")
                .font(.headline)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.secondary.opacity(0.12), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            Text("\(selectedIDs.count) selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Confirm") {
                let picked = viewModel.members.filter { selectedIDs.contains($0.memberId) }
                onConfirm(picked)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedIDs.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func selectionRow(_ member: Member) -> some View {
        Button {
            if selectedIDs.contains(member.memberId) {
                selectedIDs.remove(member.memberId)
            } else {
                selectedIDs.insert(member.memberId)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selectedIDs.contains(member.memberId) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedIDs.contains(member.memberId) ? Color.accentColor : Color.secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(member.roleLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if member.isOwner {
                    Image(systemName: "crown.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}
