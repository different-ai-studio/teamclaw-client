import SwiftUI

public enum SystemReminderSeverity: Equatable {
    case info
    case warn
    case urgent

    public var label: String {
        switch self {
        case .info: "Info"
        case .warn: "Warning"
        case .urgent: "Urgent"
        }
    }

    public var color: Color {
        switch self {
        case .info: .accentColor
        case .warn: .yellow
        case .urgent: .red
        }
    }

    public static func from(content: String) -> SystemReminderSeverity {
        let lower = content.lowercased()
        let urgentMarkers = ["permission requested", "approval required", "permission required", "blocking"]
        if urgentMarkers.contains(where: lower.contains) { return .urgent }
        let warnMarkers = ["warning", "caution", "deprecated"]
        if warnMarkers.contains(where: lower.contains) { return .warn }
        return .info
    }
}
