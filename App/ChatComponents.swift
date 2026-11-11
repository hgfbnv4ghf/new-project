import SwiftUI
import TermCore
import UIKit

// Pieces both chats use.

extension TranscriptItem {
    /// Long tool output is shown from the end, where the result usually is.
    var outputTail: String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 40 else { return text }
        return "… \(lines.count - 40) earlier lines\n" + lines.suffix(40).joined(separator: "\n")
    }
}

struct CodeBlock: View {
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
        .background(palette.code, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

/// Commands matching what has been typed after a slash.
struct SuggestionList: View {
    let chat: ChatState
    let commands: [SlashCommand]
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(commands.prefix(6), id: \.name) { command in
                Button {
                    chat.input = "/\(command.name) "
                } label: {
                    HStack(spacing: 10) {
                        Text("/\(command.name)").foregroundStyle(palette.accent)
                        Text(command.help).foregroundStyle(palette.dim).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(palette.small)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 5)
        .glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// The question a tool call waits on. The terminal keeps its `y / n / a` wording; Cowork spells it out.
struct ApprovalBar: View {
    @Environment(AppModel.self) private var model
    let chat: ChatState
    let approval: PendingApproval
    let palette: Palette

    private var terse: Bool { chat.kind == .terminal }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(terse ? "run this?" : "Allow this step?").font(palette.small).foregroundStyle(palette.accent)
            Text(approval.summary).font(palette.small).foregroundStyle(palette.text).lineLimit(6)
            HStack(spacing: 8) {
                choice(terse ? "[y] yes" : "Allow", palette.success) { model.resolveApproval(.allow, in: chat) }
                choice(terse ? "[n] no" : "Deny", palette.error) { model.resolveApproval(.deny, in: chat) }
                choice(terse ? "[a] always" : "Always allow", palette.dim) { model.allowAlways(in: chat) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func choice(_ label: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(palette.small).foregroundStyle(color)
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                .overlay(Capsule().stroke(color.opacity(0.6)))
                .contentShape(Capsule())
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
