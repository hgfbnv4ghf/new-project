import SwiftUI
import TermCore
import UIKit

struct TerminalView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var inputFocused: Bool

    var body: some View {
        @Bindable var model = model
        let palette = model.palette

        VStack(spacing: 0) {
            StatusBar()
            Rectangle().fill(palette.dim.opacity(0.3)).frame(height: 1)
            TranscriptView()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomBar(inputFocused: $inputFocused)
        }
        .background(palette.background.ignoresSafeArea())
        .preferredColorScheme(model.theme.isDark ? .dark : .light)
        .sheet(isPresented: $model.showSettings) {
            SettingsView()
        }
        .sheet(item: $model.shareItem) { item in
            ShareSheet(text: item.text)
        }
    }
}

// MARK: Status bar

private struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let palette = model.palette
        HStack(spacing: 10) {
            Menu {
                ForEach(model.profiles) { profile in
                    Section(profile.name) {
                        ForEach(profile.models, id: \.self) { id in
                            Button {
                                model.select(model: id, in: profile.id)
                            } label: {
                                if profile.id == model.activeProfile?.id, id == model.activeModel {
                                    Label(id, systemImage: "checkmark")
                                } else {
                                    Text(id)
                                }
                            }
                        }
                    }
                }
                Button("Settings…") { model.showSettings = true }
            } label: {
                HStack(spacing: 6) {
                    Text("●").foregroundStyle(model.isRunning ? palette.accent : palette.success)
                    Text(profileLabel).foregroundStyle(palette.text).lineLimit(1).truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)

            Menu {
                ForEach(model.hosts) { host in
                    Button {
                        model.selectHost(host.id)
                    } label: {
                        if host.id == model.activeHost?.id {
                            Label("\(host.name)  \(host.address)", systemImage: "checkmark")
                        } else {
                            Text("\(host.name)  \(host.address)")
                        }
                    }
                }
                Button("No SSH host") { model.selectHost(nil) }
            } label: {
                Text(model.activeHost.map { "⇄ \($0.name)" } ?? "⇄ off")
                    .foregroundStyle(model.activeHost == nil ? palette.dim : palette.accent)
                    .lineLimit(1)
            }

            Button {
                model.showSettings = true
            } label: {
                Image(systemName: "gearshape").foregroundStyle(palette.dim)
            }
            .accessibilityLabel("Settings")
        }
        .font(palette.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var profileLabel: String {
        guard let profile = model.activeProfile else { return "no profile · /setup" }
        return "\(profile.name) · \(model.activeModel ?? "no model")"
    }
}

// MARK: Transcript

private struct TranscriptView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let palette = model.palette
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.session.transcript) { item in
                            ItemView(item: item, palette: palette)
                        }
                        if model.isRunning, model.pendingApproval == nil {
                            Text("▍").font(palette.font).foregroundStyle(palette.accent)
                        } else if let usage = model.usageLine {
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
                .onChange(of: model.scrollTick) {
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

private struct CodeBlock: View {
    let code: String
    let palette: Palette

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code).font(palette.font).foregroundStyle(palette.text).textSelection(.enabled)
                .padding(.vertical, 8)
                .padding(.leading, 10)
                .padding(.trailing, 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.code, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topTrailing) {
            Button {
                UIPasteboard.general.string = code
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 12)).foregroundStyle(palette.dim).padding(8)
            }
            .accessibilityLabel("Copy code")
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

    /// Long output is shown from the end, where the result usually is.
    private var tail: String {
        let lines = item.text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 40 else { return item.text }
        return "… \(lines.count - 40) earlier lines\n" + lines.suffix(40).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(glyph.0).foregroundStyle(glyph.1)
                Text(item.title ?? "tool").foregroundStyle(palette.text.opacity(0.85)).textSelection(.enabled)
            }
            .font(palette.small)
            if !item.text.isEmpty {
                Text(tail).font(palette.small).foregroundStyle(palette.dim).textSelection(.enabled)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.code, in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: Input area

private struct BottomBar: View {
    @Environment(AppModel.self) private var model
    var inputFocused: FocusState<Bool>.Binding

    var body: some View {
        @Bindable var model = model
        let palette = model.palette

        VStack(spacing: 0) {
            if let approval = model.pendingApproval {
                ApprovalBar(approval: approval, palette: palette)
            } else if !model.suggestions.isEmpty {
                SuggestionList(palette: palette)
            }
            Rectangle().fill(palette.dim.opacity(0.3)).frame(height: 1)

            HStack(alignment: .top, spacing: 6) {
                Text(model.setup == nil ? "❯" : "?").font(palette.bold).foregroundStyle(palette.accent)
                Group {
                    if model.inputIsSecret {
                        SecureField("", text: $model.input, prompt: Text(model.placeholder).foregroundStyle(palette.dim))
                    } else {
                        TextField("", text: $model.input, prompt: Text(model.placeholder).foregroundStyle(palette.dim), axis: .vertical)
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
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            KeyRow(palette: palette, send: send, hideKeyboard: { inputFocused.wrappedValue = false })
        }
        .background(palette.background)
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                key("esc") { model.escape() }
                key("/") { model.input += "/" }
                key("!") { model.input += "!" }
                key("↑") { model.historyUp() }
                key("↓") { model.historyDown() }
                key("tab") { model.completeSuggestion() }
                key("^C", tint: model.isRunning ? palette.error : nil) { model.cancel() }
                key("paste") {
                    if let text = UIPasteboard.general.string { model.input += text }
                }
                key("⌄", action: hideKeyboard)
                key("⏎", tint: palette.accent, action: send)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
    }

    private func key(_ label: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(palette.small)
                .foregroundStyle(tint ?? palette.text)
                .padding(.horizontal, 11)
                .frame(minWidth: 38, minHeight: 32)
                .background(palette.code, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

private struct SuggestionList: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.suggestions.prefix(6), id: \.name) { command in
                Button {
                    model.input = "/\(command.name) "
                } label: {
                    HStack(spacing: 10) {
                        Text("/\(command.name)").foregroundStyle(palette.accent)
                        Text(command.help).foregroundStyle(palette.dim).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(palette.small)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(palette.code)
    }
}

private struct ApprovalBar: View {
    @Environment(AppModel.self) private var model
    let approval: PendingApproval
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("run this?").font(palette.small).foregroundStyle(palette.accent)
            Text(approval.summary).font(palette.small).foregroundStyle(palette.text).lineLimit(6)
            HStack(spacing: 8) {
                choice("[y] yes", palette.success) { model.resolveApproval(.allow) }
                choice("[n] no", palette.error) { model.resolveApproval(.deny) }
                choice("[a] always", palette.dim) { model.allowAlways() }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.code)
    }

    private func choice(_ label: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(palette.small).foregroundStyle(color)
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.6)))
        }
        .buttonStyle(.plain)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
