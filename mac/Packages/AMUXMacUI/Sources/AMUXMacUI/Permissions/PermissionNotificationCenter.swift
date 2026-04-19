import Foundation
import UserNotifications
import AppKit

/// Registers the AGENT_PERMISSION notification category and handles
/// user responses. Holds handlers keyed by requestId; handler closures
/// should capture their owning VM weakly so that the singleton cannot
/// keep stale ViewModels alive after a session switch. Callers must
/// also unregister when their detail view goes away — see
/// `PermissionNotificationObserver.onDisappear`.
/// Singleton because `UNUserNotificationCenter.delegate` is process-wide.
@MainActor
public final class PermissionNotificationCenter: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = PermissionNotificationCenter()

    public struct Handler {
        public let grant: () -> Void
        public let deny: () -> Void
        public let sessionId: String
    }

    public static let categoryId = "AGENT_PERMISSION"
    public static let grantAction = "GRANT"
    public static let denyAction = "DENY"

    private var handlers: [String: Handler] = [:]

    public override init() {
        super.init()
    }

    public func bootstrap() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let grant = UNNotificationAction(identifier: Self.grantAction, title: "Grant", options: [.authenticationRequired])
        let deny  = UNNotificationAction(identifier: Self.denyAction,  title: "Deny",  options: [.destructive])
        let category = UNNotificationCategory(identifier: Self.categoryId,
                                              actions: [grant, deny],
                                              intentIdentifiers: [],
                                              options: [])
        center.setNotificationCategories([category])

        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    public func register(requestId: String, handler: Handler) {
        handlers[requestId] = handler
    }

    public func unregister(requestId: String) {
        handlers.removeValue(forKey: requestId)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [requestId])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [requestId])
    }

    public var onFocusSession: ((String) -> Void)?

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                   willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                   didReceive response: UNNotificationResponse) async {
        let requestId = response.notification.request.identifier
        let actionIdentifier = response.actionIdentifier
        await MainActor.run {
            guard let handler = handlers[requestId] else { return }
            switch actionIdentifier {
            case Self.grantAction:
                handler.grant()
            case Self.denyAction:
                handler.deny()
            case UNNotificationDefaultActionIdentifier:
                NSApp.activate(ignoringOtherApps: true)
                onFocusSession?(handler.sessionId)
            default:
                break
            }
            unregister(requestId: requestId)
        }
    }
}
