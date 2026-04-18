import SwiftUI
import AMUXCore

struct ModelPicker: View {
    let agent: Agent?
    @Binding var selectedModelId: String?

    var body: some View {
        if let agent, !agent.availableModels.isEmpty {
            Menu {
                ForEach(agent.availableModels) { model in
                    Button {
                        selectedModelId = model.id
                    } label: {
                        if model.id == effectiveSelection(agent: agent) {
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
                    Text(currentDisplayName(agent: agent))
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
        } else {
            EmptyView()
        }
    }

    private func effectiveSelection(agent: Agent) -> String {
        selectedModelId ?? agent.currentModel ?? agent.availableModels.first?.id ?? ""
    }

    private func currentDisplayName(agent: Agent) -> String {
        let id = effectiveSelection(agent: agent)
        return agent.availableModels.first(where: { $0.id == id })?.displayName ?? id
    }
}
