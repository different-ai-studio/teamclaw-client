import SwiftUI

// MARK: - Liquid Glass View Modifier

extension View {
    @ViewBuilder
    func liquidGlass<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = true
    ) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            // DEBUG: red border = glass effect branch is active
            if interactive {
                if let tint {
                    self.glassEffect(.regular.interactive().tint(tint), in: shape)
                        .overlay(shape.stroke(Color.red, lineWidth: 1))
                } else {
                    self.glassEffect(.regular.interactive(), in: shape)
                        .overlay(shape.stroke(Color.red, lineWidth: 1))
                }
            } else {
                if let tint {
                    self.glassEffect(.regular.tint(tint), in: shape)
                        .overlay(shape.stroke(Color.red, lineWidth: 1))
                } else {
                    self.glassEffect(.regular, in: shape)
                        .overlay(shape.stroke(Color.red, lineWidth: 1))
                }
            }
        } else {
            // DEBUG: blue border = fallback branch
            self
                .background {
                    shape
                        .fill((tint ?? .gray).opacity(0.14))
                        .background(.ultraThinMaterial, in: shape)
                }
                .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
                .overlay(shape.stroke(Color.blue, lineWidth: 2))
        }
        #else
        // DEBUG: green border = old compiler branch
        self
            .background {
                shape
                    .fill((tint ?? .gray).opacity(0.14))
                    .background(.ultraThinMaterial, in: shape)
            }
            .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
            .overlay(shape.stroke(Color.green, lineWidth: 2))
        #endif
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
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
        #else
        content
        #endif
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
