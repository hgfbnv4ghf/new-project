import SwiftUI
import TermCore

@main
struct TermAIApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            TerminalView()
                .environment(model)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

/// SwiftUI colours and fonts for the active theme.
struct Palette {
    let theme: Theme
    let fontSize: Double

    var background: Color { Color(hex: theme.background) }
    var text: Color { Color(hex: theme.text) }
    var dim: Color { Color(hex: theme.dim) }
    var accent: Color { Color(hex: theme.accent) }
    var error: Color { Color(hex: theme.error) }
    var success: Color { Color(hex: theme.success) }
    var code: Color { Color(hex: theme.codeBackground) }

    var font: Font { .system(size: fontSize, design: .monospaced) }
    var small: Font { .system(size: max(fontSize - 2, 9), design: .monospaced) }
    var bold: Font { .system(size: fontSize, weight: .semibold, design: .monospaced) }
}
