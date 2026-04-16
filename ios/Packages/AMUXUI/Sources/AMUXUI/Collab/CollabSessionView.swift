import SwiftUI
import SwiftData
import AMUXCore

public struct CollabSessionView: View {
    let session: CollabSession
    let teamclawService: TeamclawService
    let actorId: String

    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: CollabSessionViewModel
    @State private var promptText = ""

    public init(session: CollabSession, teamclawService: TeamclawService, actorId: String) {
        self.session = session
        self.teamclawService = teamclawService
        self.actorId = actorId
        self._viewModel = State(initialValue: CollabSessionViewModel(session: session))
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Messages list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.messages, id: \.messageId) { message in
                            CollabMessageBubble(message: message, isMe: message.senderActorId == actorId)
                                .id(message.messageId)
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.messages.count) {
                    if let last = viewModel.messages.last {
                        withAnimation { proxy.scrollTo(last.messageId, anchor: .bottom) }
                    }
                }
            }

            // Work items bar (if any)
            if !viewModel.workItems.isEmpty {
                workItemBar
            }

            // Input bar
            inputBar
        }
        .navigationTitle(session.title.isEmpty ? "Collab Session" : session.title)
        .task {
            viewModel.start(teamclawService: teamclawService, actorId: actorId, modelContext: modelContext)
        }
        .onDisappear { viewModel.stop() }
    }

    private var workItemBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.workItems, id: \.workItemId) { item in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(item.isDone ? .green : item.isInProgress ? .orange : .blue)
                            .frame(width: 8, height: 8)
                        Text(item.title)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .liquidGlass(in: Capsule(), interactive: false)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Message...", text: $promptText, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .liquidGlass(in: RoundedRectangle(cornerRadius: 20))

            Button {
                guard !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                viewModel.sendMessage(promptText)
                promptText = ""
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

struct CollabMessageBubble: View {
    let message: SessionMessage
    let isMe: Bool

    var body: some View {
        HStack {
            if isMe { Spacer(minLength: 60) }

            VStack(alignment: isMe ? .trailing : .leading, spacing: 2) {
                if !isMe && !message.isSystem {
                    Text(message.senderActorId)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(message.content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .liquidGlass(in: RoundedRectangle(cornerRadius: 16), interactive: false)
                    .font(message.isSystem ? .callout.italic() : .body)
            }

            if !isMe { Spacer(minLength: 60) }
        }
    }
}
