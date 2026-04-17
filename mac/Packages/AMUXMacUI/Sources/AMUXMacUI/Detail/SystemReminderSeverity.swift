import SwiftUI

enum SystemReminderSeverity: Equatable {
    case info
    case warn
    case urgent

    var label: String {
        switch self {
        case .info: "Info"
        case .warn: "Warning"
        case .urgent: "Urgent"
        }
    }

    var color: Color {
        switch self {
        case .info: .accentColor
        case .warn: .yellow
        case .urgent: .red
        }
    }

    static func from(content: String) -> SystemReminderSeverity {
        let lower = content.lowercased()
        let urgentMarkers = ["permission requested", "approval required", "permission required", "blocking"]
        if urgentMarkers.contains(where: lower.contains) { return .urgent }
        let warnMarkers = ["warning", "caution", "deprecated"]
        if warnMarkers.contains(where: lower.contains) { return .warn }
        return .info
    }
}
