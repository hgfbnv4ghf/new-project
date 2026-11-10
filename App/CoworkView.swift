import SwiftUI
import TermCore

/// The Cowork chat: the agent works on the files in a folder, and the screen reads as a conversation.
struct CoworkView: View {
    @Environment(AppModel.self) private var model
    var inputFocused: FocusState<Bool>.Binding

    var body: some View {
        let palette = model.palette
        ZStack {
            if model.cowork.session.transcript.isEmpty {
                CoworkStart(palette: palette, inputFocused: inputFocused)
            } else {
                CoworkTranscript(palette: palette)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Composer(inputFocused: inputFocused)
        }
    }
}

// MARK: Start screen

private struct Idea: Identifiable {
    let icon: String
    let text: String
    var id: String { text }
}

/// Shown until the first message: where the agent will work and a few things to ask for.
private struct CoworkStart: View {
    @Environment(AppModel.self) private var model
    let palette: Palette
    var inputFocused: FocusState<Bool>.Binding

    private let ideas = [
        Idea(icon: "list.bullet.rectangle", text: "Summarise what is in this folder"),
        Idea(icon: "folder.badge.plus", text: "Sort the files into subfolders"),
        Idea(icon: "doc.text", text: "Write a README for this folder"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "sparkles")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 72, height: 72)
                    .glass(in: Circle())
                Text("Cowork").font(palette.title).foregroundStyle(palette.text)
                Text("Choose a folder and describe the job. The agent reads, writes and tidies the files in it, and asks before it changes anything.")
                    .font(palette.body)
                    .foregroundStyle(palette.dim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    model.showFolderPicker = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill").font(.system(size: 20)).foregroundStyle(palette.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.coworkFolderName)
                                .font(palette.body.weight(.semibold))
                                .foregroundStyle(palette.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(model.pickedFolder == nil ? "The app's own folder. Tap to choose one in Files" : "Tap to choose another in Files")
                                .font(palette.caption)
                                .foregroundStyle(palette.dim)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.dim)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .glass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Folder: \(model.coworkFolderName). Opens Files to choose another")

                VStack(spacing: 8) {
                    ForEach(ideas) { idea in
                        Button {
                            model.cowork.input = idea.text
                            inputFocused.wrappedValue = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: idea.icon).foregroundStyle(palette.accent).frame(width: 22)
                                Text(idea.text).foregroundStyle(palette.text)
                                Spacer(minLength: 0)
                            }
                            .font(palette.caption)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .background(palette.code.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

// MARK: Conversation

private struct CoworkTranscript: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        let chat = model.cowork
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(chat.session.transcript) { item in
                        CoworkItem(item: item, palette: palette)
                    }
                    if chat.isRunning, chat.pendingApproval == nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).tint(palette.accent)
                            Text("Working…").font(palette.caption).foregroundStyle(palette.dim)
                        }
                    } else if let usage = chat.usageLine {
                        Text(usage).font(palette.small).foregroundStyle(palette.dim)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat.scrollTick) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

private struct CoworkItem: View {
    let item: TranscriptItem
    let palette: Palette

    var body: some View {
        switch item.kind {
        case .user:
            Text(item.text)
                .font(palette.body)
                .foregroundStyle(palette.text)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(palette.accent.opacity(0.2), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.leading, 40)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(Markdown.segments(item.text).enumerated()), id: \.offset) { _, segment in
                    if segment.isCode {
                        CodeBlock(code: segment.text, palette: palette)
                    } else {
                        Text(Self.rich(segment.text)).font(palette.body).foregroundStyle(palette.text).textSelection(.enabled)
                    }
                }
            }
        case .tool:
            StepRow(item: item, palette: palette)
        case .info:
            Text(item.text).font(palette.small).foregroundStyle(palette.dim).textSelection(.enabled)
        case .error:
            Text(item.text).font(palette.caption).foregroundStyle(palette.error).textSelection(.enabled)
        }
    }

    /// Inline Markdown (bold, italics, code, links) with the line breaks left where they are.
    private static func rich(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// One thing the agent did. The output stays folded away until it is asked for.
private struct StepRow: View {
    let item: TranscriptItem
    let palette: Palette
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    status
                    Text(item.title ?? "tool")
                        .font(palette.small)
                        .foregroundStyle(palette.text.opacity(0.9))
                        .lineLimit(expanded ? nil : 1)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if !item.text.isEmpty {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(palette.dim)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded, !item.text.isEmpty {
                Text(item.outputTail).font(palette.small).foregroundStyle(palette.dim).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.code.opacity(0.8), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var status: some View {
        switch item.status {
        case .running:
            ProgressView().controlSize(.mini).tint(palette.accent)
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.success)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(palette.error)
        case .denied:
            Image(systemName: "nosign").foregroundStyle(palette.dim)
        case nil:
            Image(systemName: "circle").foregroundStyle(palette.dim)
        }
    }
}

// MARK: Input

private struct Composer: View {
    @Environment(AppModel.self) private var model
    var inputFocused: FocusState<Bool>.Binding

    var body: some View {
        // Cowork's own state rather than "the chat on screen", so nothing changes under it while it fades out.
        @Bindable var chat = model.cowork
        let palette = model.palette
        let suggestions = model.suggestions(in: chat)
        let isEmpty = chat.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let placeholder: Text = Text(model.placeholder(in: chat)).foregroundStyle(palette.dim)

        GlassGroup(spacing: 4) {
            VStack(spacing: 8) {
                if let approval = chat.pendingApproval {
                    ApprovalBar(chat: chat, approval: approval, palette: palette)
                } else if !suggestions.isEmpty {
                    SuggestionList(chat: chat, commands: suggestions, palette: palette)
                }

                VStack(alignment: .leading, spacing: 10) {
                    TextField("", text: $chat.input, prompt: placeholder, axis: .vertical)
                        .lineLimit(1...6)
                        .font(palette.body)
                        .foregroundStyle(palette.text)
                        .tint(palette.accent)
                        .submitLabel(.send)
                        .focused(inputFocused)
                        .onSubmit(send)

                    HStack(spacing: 8) {
                        Button {
                            model.showFolderPicker = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "folder")
                                Text(model.coworkFolderName).lineLimit(1).truncationMode(.middle)
                            }
                            .font(palette.caption)
                            .foregroundStyle(palette.dim)
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .overlay(Capsule().stroke(palette.dim.opacity(0.4)))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Choose the folder in Files")

                        Spacer(minLength: 0)

                        Button {
                            if chat.isRunning { model.cancel() } else { send() }
                        } label: {
                            Image(systemName: chat.isRunning ? "stop.fill" : "arrow.up")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(palette.background)
                                .frame(width: 34, height: 34)
                                .background(chat.isRunning ? palette.error : palette.accent, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!chat.isRunning && isEmpty)
                        .opacity(!chat.isRunning && isEmpty ? 0.4 : 1)
                        .accessibilityLabel(chat.isRunning ? "Stop" : "Send")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 13)
                .padding(.bottom, 10)
                .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
    }

    private func send() {
        model.submit()
    }
}
