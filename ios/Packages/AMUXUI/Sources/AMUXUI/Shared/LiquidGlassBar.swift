import SwiftUI

// MARK: - Liquid Glass View Modifier

extension View {
    @ViewBuilder
    func liquidGlass<S: Shape>(
        in shape: S,
        interactive: Bool = true
    ) -> some View {
        if #available(iOS 26.0, *) {
            if interactive {
                self.glassEffect(.regular.interactive(), in: shape)
            } else {
                self.glassEffect(.regular, in: shape)
            }
        } else {
            self
                .background {
                    shape
                        .fill(.gray.opacity(0.14))
                        .background(.ultraThinMaterial, in: shape)
                }
                .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
        }
    }
}

// MARK: - LiquidGlassContainer

struct LiquidGlassContainer<Content: View>: View {
    let spacing: CGFloat
    let content: Content

    init(spacing: CGFloat = 10, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

// MARK: - LiquidGlassBar

struct LiquidGlassBar<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 20), interactive: false)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
    }
}
