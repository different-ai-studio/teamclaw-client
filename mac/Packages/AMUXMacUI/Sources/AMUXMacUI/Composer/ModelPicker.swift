import SwiftUI

public struct ComposerModel: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String

    public static let defaults: [ComposerModel] = [
        .init(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5"),
        .init(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6"),
        .init(id: "claude-opus-4-7", displayName: "Claude Opus 4.7"),
    ]

    public static let `default`: ComposerModel = defaults[1]
}

struct ModelPicker: View {
    let sessionId: String

    @State private var selection: ComposerModel = ComposerModel.default

    var body: some View {
        Menu {
            ForEach(ComposerModel.defaults) { model in
                Button {
                    select(model)
                } label: {
                    if model == selection {
                        Label(model.displayName, systemImage: "checkmark")
                    } else {
                        Text(model.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "diamond.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.accentColor)
                Text(selection.displayName)
                    .font(.system(size: 12))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(.primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onAppear {
            let stored = UserDefaults.standard.string(forKey: storageKey)
            if let stored, let match = ComposerModel.defaults.first(where: { $0.id == stored }) {
                selection = match
            }
        }
    }

    private var storageKey: String { "amux.model.session.\(sessionId)" }

    private func select(_ model: ComposerModel) {
        selection = model
        UserDefaults.standard.set(model.id, forKey: storageKey)
    }
}
