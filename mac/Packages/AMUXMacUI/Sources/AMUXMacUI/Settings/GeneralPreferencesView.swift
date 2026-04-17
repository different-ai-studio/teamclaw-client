import SwiftUI

struct GeneralPreferencesView: View {
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw: String = AppAppearance.system.rawValue

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: appearanceBinding) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.label).tag(appearance)
                    }
                }
                .pickerStyle(.inline)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 460, height: 220)
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { AppAppearance(rawValue: appearanceRaw) ?? .system },
            set: { appearanceRaw = $0.rawValue }
        )
    }
}
