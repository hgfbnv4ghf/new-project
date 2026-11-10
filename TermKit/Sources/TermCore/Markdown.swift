import Foundation

public enum Markdown {
    public struct Segment: Equatable, Sendable {
        public var isCode: Bool
        public var text: String
    }

    /// Splits text into prose and fenced code blocks. An unclosed fence (mid-stream) is treated as code.
    public static func segments(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var current: [Substring] = []
        var inCode = false

        func flush() {
            let joined = current.joined(separator: "\n")
            current = []
            let body = inCode ? joined : joined.trimmingCharacters(in: .newlines)
            if !body.isEmpty { segments.append(Segment(isCode: inCode, text: body)) }
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                inCode.toggle()
            } else {
                current.append(line)
            }
        }
        flush()
        return segments
    }

    public static func export(_ session: Session) -> String {
        var lines = ["# \(session.title)", ""]
        for item in session.transcript {
            switch item.kind {
            case .user: lines.append("**❯ \(item.text)**")
            case .assistant: lines.append(item.text)
            case .tool: lines.append("```\n\(item.title ?? "tool")\n\(item.text)\n```")
            case .info, .error: continue
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
