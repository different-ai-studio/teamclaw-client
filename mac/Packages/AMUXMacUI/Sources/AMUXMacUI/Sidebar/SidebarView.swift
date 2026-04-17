import SwiftUI
import SwiftData
import AMUXCore

struct SidebarView: View {
    @Binding var selection: SidebarItem?
    let members: [Member]

    @Query(sort: \CollabSession.lastMessageAt, order: .reverse)
    private var sessions: [CollabSession]

    @Query(filter: #Predicate<WorkItem> { $0.status != "done" })
    private var openTasks: [WorkItem]

    @Query private var allMessages: [SessionMessage]

    var body: some View {
        List(selection: $selection) {
            Section("Functions") {
                FunctionRow(function: .sessions, count: sessions.count)
                    .tag(SidebarItem.function(.sessions))

                FunctionRow(function: .tasks, count: openTasks.count)
                    .tag(SidebarItem.function(.tasks))
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
