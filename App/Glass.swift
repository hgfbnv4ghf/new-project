import SwiftUI

// Liquid Glass arrived with iOS 26. The app still runs on iOS 17 and may be built with an older Xcode,
// so every use goes through this file: real glass when both the SDK and the system have it, a blurred
// material otherwise.

extension View {
    /// Places the view on a glass surface of the given shape.
    @ViewBuilder
    func glass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            frosted(in: shape, tint: tint)
        }
        #else
        frosted(in: shape, tint: tint)
        #endif
    }

    /// The stand-in for glass before iOS 26: a material with a hairline edge.
    private func frosted<S: Shape>(in shape: S, tint: Color?) -> some View {
        background {
            ZStack {
                shape.fill(.ultraThinMaterial)
                if let tint { shape.fill(tint.opacity(0.3)) }
                shape.stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
        }
    }
}

/// Groups neighbouring glass surfaces so the system draws them as one sheet of glass.
struct GlassGroup<Content: View>: View {
    /// Surfaces closer together than this flow into each other; keep it below the gaps between controls.
    var spacing: CGFloat = 4
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

/// The theme's background with soft colour in two corners, which gives the glass something to bend.
struct Backdrop: View {
    let palette: Palette

    var body: some View {
        ZStack {
            palette.background
            Backdrop.glow(palette, at: .top)
            Backdrop.glow(palette, at: .bottom)
        }
        .ignoresSafeArea()
    }

    /// The colour in the corner by an edge: the accent top left, the success colour bottom right.
    static func glow(_ palette: Palette, at edge: VerticalEdge) -> RadialGradient {
        edge == .top
            ? RadialGradient(colors: [palette.accent.opacity(0.22), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
            : RadialGradient(colors: [palette.success.opacity(0.12), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 480)
    }
}

/// Goes behind a floating bar and hides what scrolls beneath it, so text never shows through the glass
/// controls. It repeats the backdrop for that edge, so the bar still looks as if it floated on the
/// backdrop itself, and it fades out just past the bar instead of ending in a line.
struct BarShade: View {
    let palette: Palette
    let edge: VerticalEdge
    /// The fade starts inside the bar's own padding and ends this far beyond its edge.
    private let fade: CGFloat = 16
    private let overhang: CGFloat = 10

    var body: some View {
        ZStack {
            palette.background
            Backdrop.glow(palette, at: edge)
        }
        .mask {
            VStack(spacing: 0) {
                if edge == .bottom {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: fade)
                }
                Color.black
                if edge == .top {
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: fade)
                }
            }
        }
        .padding(edge == .top ? .bottom : .top, -overhang)
        .ignoresSafeArea(edges: edge == .top ? .top : .bottom)
        .allowsHitTesting(false)
    }
}
