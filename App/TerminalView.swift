import SwiftUI
import TermCore
import UIKit

struct TerminalView: View {
    var inputFocused: FocusState<Bool>.Binding

    var body: some View {
        TranscriptView()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                BottomBar(inputFocused: inputFocused)
            }
    }
}

// MARK: Transcript

private struct TranscriptView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let palette = model.palette
        let chat = model.terminal
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(chat.session.transcript) { item in
                            ItemView(item: item, palette: palette)
                        }
                        if chat.isRunning, chat.pendingApproval == nil {
                            Text("▍").font(palette.font).foregroundStyle(palette.accent)
                        } else if let usage = chat.usageLine {
                            Text(usage).font(palette.small).foregroundStyle(palette.dim)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    // A short transcript starts at the top, like a fresh terminal, rather than hugging the input.
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
                    .shadow(color: model.theme.glow ? palette.text.opacity(0.55) : .clear, radius: 3)
                }
                // Stay pinned to the newest output while it streams, unless the user scrolls up.
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chat.scrollTick) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }
}

private struct ItemView: View {
    let item: TranscriptItem
    let palette: Palette

    var body: some View {
        switch item.kind {
        case .user:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("❯").foregroundStyle(palette.accent)
                Text(item.text).foregroundStyle(palette.text).textSelection(.enabled)
            }
            .font(palette.bold)
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(Markdown.segments(item.text).enumerated()), id: \.offset) { _, segment in
                    if segment.isCode {
                        CodeBlock(code: segment.text, palette: palette)
                    } else {
                        Text(segment.text).font(palette.font).foregroundStyle(palette.text).textSelection(.enabled)
                    }
                }
            }
        case .tool:
            ToolBlock(item: item, palette: palette)
        case .info:
            Text(item.text).font(palette.font).foregroundStyle(palette.dim).textSelection(.enabled)
        case .error:
            Text(item.text).font(palette.font).foregroundStyle(palette.error).textSelection(.enabled)
        }
    }
}

private struct ToolBlock: View {
    let item: TranscriptItem
    let palette: Palette

    private var glyph: (String, Color) {
        switch item.status {
        case .running: return ("…", palette.accent)
        case .ok: return ("✓", palette.success)
        case .failed: return ("✗", palette.error)
        case .denied: return ("⊘", palette.dim)
        case nil: return ("·", palette.dim)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(glyph.0).foregroundStyle(glyph.1)
                Text(item.title ?? "tool").foregroundStyle(palette.text.opacity(0.85)).textSelection(.enabled)
            }
            .font(palette.small)
            if !item.text.isEmpty {
                Text(item.outputTail).font(palette.small).foregroundStyle(palette.dim).textSelection(.enabled)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.code, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: Input area

private struct BottomBar: View {
    @Environment(AppModel.self) private var model
    var inputFocused: FocusState<Bool>.Binding

    var body: some View {
        // The terminal's own state rather than "the chat on screen", so nothing changes under it while it fades out.
        @Bindable var chat = model.terminal
        let palette = model.palette
        let suggestions = model.suggestions(in: chat)
        let placeholder: Text = Text(model.placeholder(in: chat)).foregroundStyle(palette.dim)

        GlassGroup(spacing: 4) {
            VStack(spacing: 8) {
                VStack(spacing: 8) {
                    if let approval = chat.pendingApproval {
                        ApprovalBar(chat: chat, approval: approval, palette: palette)
                    } else if !suggestions.isEmpty {
                        SuggestionList(chat: chat, commands: suggestions, palette: palette)
                    }

                    HStack(alignment: .top, spacing: 6) {
                        Text(model.setup == nil ? "❯" : "?").font(palette.bold).foregroundStyle(palette.accent)
                        Group {
                            if model.inputIsSecret {
                                SecureField("", text: $chat.input, prompt: placeholder)
                            } else {
                                TextField("", text: $chat.input, prompt: placeholder, axis: .vertical)
                                    .lineLimit(1...6)
                            }
                        }
                        .font(palette.font)
                        .foregroundStyle(palette.text)
                        .tint(palette.accent)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.send)
                        .focused(inputFocused)
                        .onSubmit(send)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .glass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .padding(.horizontal, 10)

                KeyRow(palette: palette, send: send, hideKeyboard: { inputFocused.wrappedValue = false })
            }
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
        .background { BarShade(palette: palette, edge: .bottom) }
    }

    private func send() {
        model.submit()
        // Submitting drops focus; keep the keyboard up like a terminal would.
        DispatchQueue.main.async { inputFocused.wrappedValue = true }
    }
}

private struct KeyRow: View {
    @Environment(AppModel.self) private var model
    let palette: Palette
    let send: () -> Void
    let hideKeyboard: () -> Void

    var body: some View {
        let chat = model.terminal
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                key("esc") { model.escape() }
                key("/") { chat.input += "/" }
                key("!") { chat.input += "!" }
                key("↑") { model.historyUp() }
                key("↓") { model.historyDown() }
                key("tab") { model.completeSuggestion() }
                key("^C", tint: chat.isRunning ? palette.error : nil) { model.cancel() }
                key("paste") {
                    if let text = UIPasteboard.general.string { chat.input += text }
                }
                key("⌄", action: hideKeyboard)
                key("⏎", tint: palette.accent, action: send)
            }
            .padding(.horizontal, 10)
            // Room for the keys to lift when pressed without being clipped by the scroll view.
            .padding(.vertical, 2)
        }
    }

    private func key(_ label: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(palette.small)
                .foregroundStyle(tint ?? palette.text)
                .padding(.horizontal, 11)
                .frame(minWidth: 38, minHeight: 32)
                .glass(in: Capsule(), interactive: true)
        }
        .buttonStyle(.plain)
    }
}
