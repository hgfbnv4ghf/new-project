import Foundation

public struct SlashCommand: Equatable, Sendable {
    public var name: String
    public var usage: String
    public var help: String
}

public enum ParsedInput: Equatable, Sendable {
    case empty
    case prompt(String)
    /// `!cmd`: run directly on the active SSH host, bypassing the model.
    case shell(String)
    case command(name: String, args: String)
}

public enum Commands {
    public static let all: [SlashCommand] = [
        .init(name: "help", usage: "/help", help: "list commands"),
        .init(name: "setup", usage: "/setup", help: "add an API profile step by step"),
        .init(name: "config", usage: "/config", help: "open settings"),
        .init(name: "model", usage: "/model [id]", help: "show or switch model"),
        .init(name: "profile", usage: "/profile [name]", help: "show or switch API profile"),
        .init(name: "host", usage: "/host [name|off]", help: "show or switch SSH host"),
        .init(name: "approve", usage: "/approve [ask|auto]", help: "tool approval mode"),
        .init(name: "theme", usage: "/theme [id]", help: "show or switch theme"),
        .init(name: "system", usage: "/system [text|reset]", help: "show or set the system prompt"),
        .init(name: "cowork", usage: "/cowork", help: "open the cowork chat"),
        .init(name: "terminal", usage: "/terminal", help: "back to the terminal chat"),
        .init(name: "folder", usage: "/folder [reset]", help: "pick the cowork folder in Files"),
        .init(name: "context", usage: "/context [n|auto|off]", help: "show context use, set its limit"),
        .init(name: "compact", usage: "/compact [focus]", help: "summarise the chat to save tokens"),
        .init(name: "new", usage: "/new", help: "start a new session"),
        .init(name: "sessions", usage: "/sessions [n]", help: "list or resume sessions"),
        .init(name: "retry", usage: "/retry", help: "resend the last prompt"),
        .init(name: "copy", usage: "/copy", help: "copy the last answer"),
        .init(name: "export", usage: "/export", help: "share the session as Markdown"),
        .init(name: "clear", usage: "/clear", help: "clear the screen"),
    ]

    public static func parse(_ raw: String) -> ParsedInput {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .empty }
        if text.hasPrefix("!") {
            let command = text.dropFirst().trimmingCharacters(in: .whitespaces)
            return command.isEmpty ? .empty : .shell(command)
        }
        if text.hasPrefix("/") {
            let body = text.dropFirst()
            let name = body.prefix { !$0.isWhitespace }.lowercased()
            // A leading slash that is not a known command (e.g. a file path) is an ordinary prompt.
            guard all.contains(where: { $0.name == name }) else { return .prompt(text) }
            let args = body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return .command(name: name, args: args)
        }
        return .prompt(text)
    }

    /// Commands matching a partially typed `/name` (no arguments yet).
    public static func suggestions(for input: String) -> [SlashCommand] {
        guard input.hasPrefix("/"), !input.contains(where: { $0.isWhitespace }) else { return [] }
        let partial = input.dropFirst().lowercased()
        return all.filter { $0.name.hasPrefix(partial) && $0.name != partial }
    }
}
