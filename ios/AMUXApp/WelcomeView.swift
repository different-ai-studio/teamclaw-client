import SwiftUI
import AMUXCore

struct WelcomeView: View {
    @Bindable var coordinator: AppOnboardingCoordinator
    @State private var showChoose = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 16) {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 64))
                        .foregroundStyle(.tint)
                    Text("AMUX")
                        .font(.largeTitle.bold())
                    Text("Monitor and control your AI coding agents from anywhere.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()

                Button {
                    showChoose = true
                } label: {
                    Text("Get Started")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .glassProminentButtonStyle()
                .padding(.horizontal, 24)
                .padding(.bottom, 48)
                .accessibilityIdentifier("welcome.getStartedButton")
            }
            .navigationDestination(isPresented: $showChoose) {
                ChooseAuthView(coordinator: coordinator)
            }
        }
    }
}
