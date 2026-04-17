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

    var body: some View {
        List(selection: $selection) {
            Section("Functions") {
                FunctionRow(
                    function: .sessions,
                    count: sessions.count
                )
                .tag(SidebarItem.function(.sessions))

                FunctionRow(
                    function: .tasks,
                    count: openTasks.count
                )
                .tag(SidebarItem.function(.tasks))
            }

            Section("Members") {
                Text("(no members yet)")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
        .listStyle(.sidebar)
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
