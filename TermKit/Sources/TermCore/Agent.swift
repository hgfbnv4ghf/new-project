import Foundation

public enum AgentEvent: Sendable {
    case assistantDelta(String)
    /// A message to append to the conversation history (assistant turn or tool result).
    case message(ChatMessage)
    case toolStarted(ToolCall, summary: String)
    case toolOutput(id: String, chunk: String)
    case toolFinished(id: String, result: ToolResult, denied: Bool)
    case usage(input: Int, output: Int)
}

public enum ApprovalDecision: Sendable {
    case allow, deny
}

public enum AgentError: LocalizedError, Equatable {
    case tooManySteps(Int)

    public var errorDescription: String? {
        switch self {
        case .tooManySteps(let limit): return "stopped after \(limit) tool rounds; send another message to continue"
        }
    }
}

/// Runs the model, executes the tool calls it asks for, and repeats until it answers in plain text.
public struct Agent: Sendable {
    public var client: ChatStreaming
    public var tools: ToolRunning
    public var maxSteps: Int

    public init(client: ChatStreaming, tools: ToolRunning, maxSteps: Int = 40) {
        self.client = client
        self.tools = tools
        self.maxSteps = maxSteps
    }

    /// `request.messages` is the history including the new user message. Every message produced is
    /// reported through `emit(.message)` as soon as it is complete, so the caller's history stays valid
    /// even when the run is cancelled or fails part-way.
    public func run(
        request: ChatRequest,
        approve: @escaping @Sendable (ToolCall, String) async -> ApprovalDecision,
        emit: @escaping @Sendable (AgentEvent) async -> Void
    ) async throws {
        var request = request
        request.tools = tools.specs

        for _ in 0..<maxSteps {
            var text = ""
            var calls: [Int: ToolCall] = [:]

            do {
                for try await event in client.streamChat(request) {
                    switch event {
                    case .text(let delta):
                        text += delta
                        await emit(.assistantDelta(delta))
                    case .toolCallDelta(let index, let id, let name, let arguments):
                        var call = calls[index] ?? ToolCall(id: "", name: "", arguments: "")
                        if let id, !id.isEmpty { call.id = id }
                        if let name, !name.isEmpty { call.name = name }
                        if let arguments { call.arguments += arguments }
                        calls[index] = call
                    case .usage(let input, let output):
                        await emit(.usage(input: input, output: output))
                    }
                }
                try Task.checkCancellation()
            } catch {
                // Keep whatever text arrived; half-received tool calls are dropped so history stays well-formed.
                if !text.isEmpty { await emit(.message(ChatMessage(role: .assistant, content: text))) }
                throw Task.isCancelled ? CancellationError() : error
            }

            let toolCalls = calls.keys.sorted().compactMap { index -> ToolCall? in
                guard var call = calls[index], !call.name.isEmpty else { return nil }
                if call.id.isEmpty { call.id = "call_\(index)_\(UUID().uuidString.prefix(8))" }
                return call
            }

            let assistant = ChatMessage(role: .assistant, content: text, toolCalls: toolCalls.isEmpty ? nil : toolCalls)
            request.messages.append(assistant)
            await emit(.message(assistant))
            if toolCalls.isEmpty { return }

            for call in toolCalls {
                let summary = tools.summary(call)
                await emit(.toolStarted(call, summary: summary))

                var result: ToolResult
                var denied = false
                if Task.isCancelled {
                    result = ToolResult(text: "cancelled by the user", isError: true)
                } else if tools.needsApproval(call), await approve(call, summary) == .deny {
                    denied = true
                    result = ToolResult(text: "The user declined to run this tool call.", isError: true)
                } else {
                    // Output is forwarded through a stream so chunks stay ordered and all arrive before the result.
                    let (output, continuation) = AsyncStream<String>.makeStream()
                    let forwarder = Task {
                        for await chunk in output { await emit(.toolOutput(id: call.id, chunk: chunk)) }
                    }
                    result = await tools.run(call) { continuation.yield($0) }
                    continuation.finish()
                    await forwarder.value
                }

                // Every tool call needs a result message, or the next request is rejected by the API.
                let message = ChatMessage(role: .tool, content: result.text, toolCallID: call.id)
                request.messages.append(message)
                await emit(.toolFinished(id: call.id, result: result, denied: denied))
                await emit(.message(message))
            }
            try Task.checkCancellation()
        }
        throw AgentError.tooManySteps(maxSteps)
    }
}

public enum SystemPrompt {
    public static func build(custom: String, hostLabel: String?) -> String {
        var lines = [
            "You are an assistant running inside a terminal app on the user's iPhone.",
            "The screen is narrow and monospaced: answer concisely in plain text, use short lines, and keep Markdown to fenced code blocks.",
            "You can read and write files in a small on-device workspace and fetch URLs.",
        ]
        if let hostLabel {
            lines.append("An SSH session to \(hostLabel) is available through the ssh_exec tool. Commands are non-interactive (no TTY): avoid editors, pagers and prompts, and pass flags such as -y where needed. The user approves commands before they run, so prefer a few purposeful commands and explain destructive ones first.")
        } else {
            lines.append("No SSH host is connected, so you cannot run remote commands. If one is needed, tell the user to add a host in /config and select it with /host.")
        }
        let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { lines.append(trimmed) }
        return lines.joined(separator: "\n")
    }
}
