import SwiftUI
import SwiftData
import AMUXCore

public struct WorkspaceSheet: View {
    @Environment(\.dismiss) private var dismiss

    let viewModel: SessionListViewModel
    let teamclawService: TeamclawService

    public init(viewModel: SessionListViewModel, teamclawService: TeamclawService) {
        self.viewModel = viewModel
        self.teamclawService = teamclawService
    }

    public var body: some View {
        NavigationStack {
            WorkspaceManagementView(viewModel: viewModel, teamclawService: teamclawService)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.title3).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
        }
    }
}
