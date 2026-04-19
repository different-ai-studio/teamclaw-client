import SwiftUI
import UserNotifications
import AppKit
import AMUXCore

/// Watches AgentDetailViewModel.events for unresolved permission_request
/// entries. When the app is inactive and a new one arrives, fires a
/// banner with Grant/Deny actions. When the request resolves (by any
/// path — in-app banner or daemon timeout), withdraws the banner.
@MainActor
struct PermissionNotificationObserver: ViewModifier {
    let agentVM: AgentDetailViewModel
    let sessionId: String

    @State private var tracked: Set<String> = []

    func body(content: Content) -> some View {
        content
            .onChange(of: pendingSignature) { _, _ in reconcile() }
            .onDisappear {
                // When the detail view goes away (session switch, window
                // closed), unregister every tracked request so the
                // singleton center doesn't hang on to the now-stale VM
                // via the stored Grant/Deny closures.
                for requestId in tracked {
                    PermissionNotificationCenter.shared.unregister(requestId: requestId)
                }
                tracked = []
            }
    }

    /// A string derived from the current set of pending permission_request
    /// events; changes whenever a new request appears or one is resolved.
    private var pendingSignature: String {
        agentVM.events
            .filter { $0.eventType == "permission_request" && !$0.isComplete }
            .compactMap { $0.toolId }
            .sorted()
            .joined(separator: ",")
    }

    private func reconcile() {
        let pending = agentVM.events.filter {
            $0.eventType == "permission_request" && !$0.isComplete
        }
        let pendingIds = Set(pending.compactMap { $0.toolId })

        for resolved in tracked.subtracting(pendingIds) {
            PermissionNotificationCenter.shared.unregister(requestId: resolved)
        }

        for event in pending where !tracked.contains(event.toolId ?? "") {
            guard let requestId = event.toolId, !requestId.isEmpty else { continue }
            tracked.insert(requestId)
            guard !NSApp.isActive else { continue }

            PermissionNotificationCenter.shared.register(
                requestId: requestId,
                handler: .init(
                    grant: { [weak agentVM] in
                        guard let agentVM else { return }
                        Task { try? await agentVM.grantPermission(requestId: requestId) }
                    },
                    deny: { [weak agentVM] in
                        guard let agentVM else { return }
                        Task { try? await agentVM.denyPermission(requestId: requestId) }
                    },
                    sessionId: sessionId
                )
            )

            let content = UNMutableNotificationContent()
            content.title = "Permission Request"
            content.body = "\(event.toolName ?? "tool"): \(event.text ?? "")"
            content.categoryIdentifier = PermissionNotificationCenter.categoryId
            content.userInfo = [
                "requestId": requestId,
                "sessionId": sessionId,
                "toolName": event.toolName ?? "",
            ]
            let request = UNNotificationRequest(identifier: requestId, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { _ in }
        }

        tracked = pendingIds
    }
}

extension View {
    func observesPermissionNotifications(agentVM: AgentDetailViewModel, sessionId: String) -> some View {
        modifier(PermissionNotificationObserver(agentVM: agentVM, sessionId: sessionId))
    }
}
