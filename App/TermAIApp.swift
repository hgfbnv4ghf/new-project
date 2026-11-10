import SwiftUI
import TermCore
import UniformTypeIdentifiers

@main
struct TermAIApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

/// One window for both chats: the shared bar on top, then whichever chat is open with its own input.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var inputFocused: Bool

    var body: some View {
        @Bindable var model = model
        let palette = model.palette

        ZStack {
            if model.mode == .cowork {
                CoworkView(inputFocused: $inputFocused)
            } else {
                TerminalView(inputFocused: $inputFocused)
            }
        }
        // The bar floats over the chat, so the transcript scrolls underneath the glass.
        .safeAreaInset(edge: .top, spacing: 0) {
            TopBar()
        }
        .background(Backdrop(palette: palette))
        .preferredColorScheme(model.theme.isDark ? .dark : .light)
        .sheet(isPresented: $model.showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $model.showContext) {
            ContextView()
        }
        .sheet(item: $model.shareItem) { item in
            ShareSheet(text: item.text)
        }
        // Folders are chosen in the Files browser, never typed as a path.
        .fileImporter(isPresented: $model.showFolderPicker, allowedContentTypes: [.folder]) { result in
            model.folderPicked(result)
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

    // Cowork reads as a conversation rather than a terminal, so it is set in the proportional face.
    var body: Font { .system(size: fontSize + 3) }
    var caption: Font { .system(size: fontSize) }
    var title: Font { .system(size: fontSize + 15, weight: .bold, design: .rounded) }
}
