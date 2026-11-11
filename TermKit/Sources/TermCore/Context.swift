import Foundation

/// Token arithmetic. Every model tokenises differently and the app carries no tokeniser, so text is sized
/// at four UTF-8 bytes a token: close for English and code, and scripts that take more bytes per
/// character (Cyrillic, CJK) are counted as costing more, which they do.
public enum Tokens {
    public static func estimate(_ text: String) -> Int {
        (text.utf8.count + 3) / 4
    }

    public static func estimate(_ message: ChatMessage) -> Int {
        // A few tokens of framing per message and per tool call, on top of the text.
        (message.toolCalls ?? []).reduce(4 + estimate(message.content)) {
            $0 + 4 + estimate($1.name) + estimate($1.arguments)
        }
    }

    public static func estimate(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + estimate($1) }
    }

    public static func estimate(_ tools: [ToolSpec]) -> Int {
        tools.reduce(0) { $0 + 8 + estimate($1.name) + estimate($1.description) + estimate($1.parametersJSON) }
    }

    /// `950`, `2.4k`, `64k`, `1M`.
    public static func format(_ count: Int) -> String {
        guard count >= 1_000 else { return "\(count)" }
        var value = Double(count) / 1_000
        var unit = "k"
        if value >= 999.95 {
            value /= 1_000
            unit = "M"
        }
        let text = String(format: "%.1f", value)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + unit
    }

    /// Reads `64k`, `1.5m` or a plain number of tokens.
    public static func parse(_ text: String) -> Int? {
        var digits = text.trimmingCharacters(in: .whitespaces).lowercased()
        var scale = 1.0
        if digits.hasSuffix("k") {
            scale = 1_000
            digits.removeLast()
        } else if digits.hasSuffix("m") {
            scale = 1_000_000
            digits.removeLast()
        }
        guard let number = Double(digits), number.isFinite, number > 0, number * scale < 1e12 else { return nil }
        return Int((number * scale).rounded())
    }
}

/// What the next request is made of, in estimated tokens.
public struct ContextUsage: Equatable, Sendable {
    public var system: Int
    public var tools: Int
    /// The summary left by a compaction, which travels with the system prompt.
    public var summary: Int
    public var user: Int
    /// Assistant text and the tool calls it made.
    public var assistant: Int
    public var toolResults: Int
    public var messageCount: Int
    public var limit: Int

    public init(system: String, tools: [ToolSpec], summary: String?, messages: [ChatMessage], limit: Int) {
        self.system = Tokens.estimate(system)
        self.tools = Tokens.estimate(tools)
        self.summary = Tokens.estimate(summary ?? "")
        var user = 0, assistant = 0, toolResults = 0
        for message in messages {
            switch message.role {
            case .system: continue
            case .user: user += Tokens.estimate(message)
            case .assistant: assistant += Tokens.estimate(message)
            case .tool: toolResults += Tokens.estimate(message)
            }
        }
        self.user = user
        self.assistant = assistant
        self.toolResults = toolResults
        messageCount = messages.count
        self.limit = limit
    }

    public var total: Int { system + tools + summary + user + assistant + toolResults }
    public var fraction: Double { limit > 0 ? Double(total) / Double(limit) : 0 }
    public var percent: Int { Int((fraction * 100).rounded()) }
    /// Past the point where the app starts trimming and summarising by itself.
    public var isOverBudget: Bool { fraction > Compaction.threshold }

    /// The `/context` report, laid out for a monospaced transcript.
    public func report(reported: Int?, autoCompact: Bool) -> String {
        let cells = min(max(Int((fraction * 10).rounded()), total > 0 ? 1 : 0), 10)
        var lines = [
            "context " + String(repeating: "█", count: cells) + String(repeating: "░", count: 10 - cells) + " \(percent)%",
            "about \(Tokens.format(total)) of \(Tokens.format(limit)) tokens",
            "",
        ]
        var rows = [("system prompt", system), ("tools", tools)]
        if summary > 0 { rows.append(("summary", summary)) }
        rows += [("you", user), ("assistant", assistant), ("tool results", toolResults)]
        for (name, count) in rows {
            lines.append(name.padding(toLength: 15, withPad: " ", startingAt: 0) + Tokens.format(count))
        }
        lines.append("")
        lines.append("\(messageCount) message\(messageCount == 1 ? "" : "s") in the history")
        if let reported { lines.append("last request: \(Tokens.format(reported)) tokens, counted by the API") }
        lines.append(autoCompact
            ? "auto-compress: on, at \(Int(Compaction.threshold * 100))% of the limit"
            : "auto-compress: off")
        lines.append("/compact swaps the history for a summary")
        return lines.joined(separator: "\n")
    }
}

public enum CompactionError: LocalizedError, Equatable {
    case emptySummary

    public var errorDescription: String? {
        switch self {
        case .emptySummary: return "the model returned an empty summary, so nothing was changed"
        }
    }
}

/// Keeping a long conversation inside its token budget.
public enum Compaction {
    /// Share of the context limit at which the app steps in by itself.
    public static let threshold = 0.8

    /// Cuts down every tool result older than the newest `keep`. Old output is rarely needed again, yet it
    /// is resent with each request. Returns the estimated tokens saved.
    @discardableResult
    public static func trimToolResults(in messages: inout [ChatMessage], keep: Int = 4, head: Int = 300) -> Int {
        let results = messages.indices.filter { messages[$0].role == .tool }
        var saved = 0
        for index in results.dropLast(max(keep, 0)) {
            let content = messages[index].content
            // Short results, and ones trimmed earlier, stay as they are.
            guard content.count > head + 200 else { continue }
            let trimmed = String(content.prefix(head))
                + "\n… [\(content.count - head) more characters of old tool output dropped to save context; run the tool again if they are needed]"
            saved += Tokens.estimate(content) - Tokens.estimate(trimmed)
            messages[index].content = trimmed
        }
        return saved
    }

    static let instructions = """
        You are compacting a conversation between a user and an AI assistant so that it can go on with far fewer tokens. \
        Write the summary the assistant will read in place of the history. Keep what the user wants and any preferences \
        they stated; what was done and found so far, with the exact paths, hosts, commands, names and values that still \
        matter; the current state; and what is left to do. Leave out pleasantries and raw tool output. \
        Plain text, no preamble, at most 300 words.
        """

    /// The conversation as plain text for the summarising request. Tool calls and results are cut short:
    /// the summary needs their gist, and sending them whole would cost what compaction is meant to save.
    static func digest(summary: String?, messages: [ChatMessage], toolTextLimit: Int = 1_500) -> String {
        var parts: [String] = []
        if let summary, !summary.isEmpty {
            parts.append("[summary of the conversation before this point]\n\(summary)")
        }
        for message in messages {
            switch message.role {
            case .system:
                continue
            case .user:
                parts.append("[user]\n\(message.content)")
            case .assistant:
                if !message.content.isEmpty { parts.append("[assistant]\n\(message.content)") }
                for call in message.toolCalls ?? [] {
                    parts.append("[assistant called \(call.name)]\n\(Truncate.middle(call.arguments, limit: toolTextLimit))")
                }
            case .tool:
                parts.append("[tool result]\n\(Truncate.middle(message.content, limit: toolTextLimit))")
            }
        }
        return parts.joined(separator: "\n\n")
    }

    /// Asks the model to summarise `messages`, folding in the summary of an earlier compaction.
    /// `endpoint` supplies the base URL, key and model; its own messages and tools are not sent.
    public static func summarize(client: ChatStreaming, endpoint: ChatRequest, summary: String?, messages: [ChatMessage],
                                 focus: String = "", limit: Int = AppSettings.defaultContextLimit) async throws -> String {
        var text = digest(summary: summary, messages: messages)
        // The digest has to fit the model as well; lose its middle rather than fail.
        let budget = max(limit * 7 / 10, 1_000)
        let size = Tokens.estimate(text)
        if size > budget { text = Truncate.middle(text, limit: max(text.count * budget / size, 2_000)) }

        var system = instructions
        let focus = focus.trimmingCharacters(in: .whitespacesAndNewlines)
        if !focus.isEmpty { system += "\nThe user asked for the summary to focus on: \(focus)" }

        var request = endpoint
        request.tools = []
        request.messages = [ChatMessage(role: .system, content: system), ChatMessage(role: .user, content: text)]
        var result = ""
        for try await event in client.streamChat(request) {
            if case .text(let delta) = event { result += delta }
        }
        try Task.checkCancellation()
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw CompactionError.emptySummary }
        return result
    }
}
