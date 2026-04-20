import SwiftUI
import AMUXCore

struct ModelPicker: View {
    let agent: Agent?
    @Binding var selectedModelId: String?

    var body: some View {
        if let agent {
            let models = agent.availableModels
            if !models.isEmpty {
                Menu {
                    ForEach(models) { model in
                        Button {
                            selectedModelId = model.id
                        } label: {
                            if model.id == effectiveSelection(agent: agent, models: models) {
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
                        Text(currentDisplayName(agent: agent, models: models))
                            .font(.system(size: 12))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .glassEffect(in: Capsule())
                    .foregroundStyle(.primary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                EmptyView()
            }
        } else {
            EmptyView()
        }
    }

    private func effectiveSelection(agent: Agent, models: [AvailableModel]) -> String {
        selectedModelId ?? agent.currentModel ?? models.first?.id ?? ""
    }

    private func currentDisplayName(agent: Agent, models: [AvailableModel]) -> String {
        let id = effectiveSelection(agent: agent, models: models)
        return models.first(where: { $0.id == id })?.displayName ?? id
    }
}
