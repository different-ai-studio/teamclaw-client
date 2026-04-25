import SwiftUI
import AMUXCore

/// Sits between WelcomeView and LoginView. Two paths:
///   - "Try it first" → anonymous Supabase sign-in + auto-created random team
///   - "Sign in or register" → push the existing LoginView
struct ChooseAuthView: View {
    @Bindable var coordinator: AppOnboardingCoordinator
    @State private var showLogin = false

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Image(systemName: "rectangle.3.group")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("Welcome to AMUX")
                    .font(.title.bold())
                Text("Pick how you want to start.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 32)

            Spacer(minLength: 0)

            VStack(spacing: 14) {
                Button {
                    Task { await coordinator.signInAnonymously() }
                } label: {
                    optionLabel(
                        icon: "sparkles",
                        title: "先试试",
                        subtitle: "Anonymous workspace, no email needed. You can upgrade later."
                    )
                }
                .glassProminentButtonStyle()
                .disabled(coordinator.isBusy)
                .accessibilityIdentifier("choose.anonymousButton")

                Button {
                    showLogin = true
                } label: {
                    optionLabel(
                        icon: "envelope",
                        title: "登录或注册",
                        subtitle: "Email, Apple, or Google. Saves your work across devices."
                    )
                }
                .glassButtonStyle()
                .disabled(coordinator.isBusy)
                .accessibilityIdentifier("choose.signInButton")
            }
            .padding(.horizontal, 24)

            if let err = coordinator.errorMessage {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
            }

            Spacer(minLength: 0)
        }
        .padding(.bottom, 32)
        .navigationDestination(isPresented: $showLogin) {
            LoginView(coordinator: coordinator)
        }
    }

    private func optionLabel(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
    }
}
