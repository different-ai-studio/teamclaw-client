import SwiftUI

public enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    public static let storageKey = "amux.appearance"
}

private struct AppAppearanceModifier: ViewModifier {
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw: String = AppAppearance.system.rawValue

    func body(content: Content) -> some View {
        content.preferredColorScheme((AppAppearance(rawValue: appearanceRaw) ?? .system).colorScheme)
    }
}

public extension View {
    /// Applies the user-selected app appearance (System/Light/Dark) to this view.
    /// Must be applied to the root of every Scene — `.preferredColorScheme` does
    /// not propagate across separate WindowGroups/Windows.
    func appAppearance() -> some View {
        modifier(AppAppearanceModifier())
    }
}
