import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ToolResult: Equatable, Sendable {
    public var text: String
    public var isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

/// A connected remote machine that can run shell commands.
public protocol RemoteShell: Sendable {
    var label: String { get }
    /// Runs `command`, streaming combined stdout/stderr, and returns the exit code.
    func run(command: String, timeout: TimeInterval, onOutput: @escaping @Sendable (String) -> Void) async throws -> Int
}

public protocol ToolRunning: Sendable {
    var specs: [ToolSpec] { get }
    func needsApproval(_ call: ToolCall) -> Bool
    /// One-line description shown in the transcript and in approval prompts.
    func summary(_ call: ToolCall) -> String
    func run(_ call: ToolCall, onOutput: @escaping @Sendable (String) -> Void) async -> ToolResult
}

public enum Truncate {
    /// Keeps the head and tail of long output so the model sees both the start and the final lines.
    public static func middle(_ text: String, limit: Int = 16_000) -> String {
        guard text.count > limit else { return text }
        let half = limit / 2
        return String(text.prefix(half)) + "\n… [\(text.count - limit) characters omitted] …\n" + String(text.suffix(half))
    }
}

/// The agent's tools: files in the on-device workspace, web fetch, and commands on the active SSH host.
public struct ToolBox: ToolRunning {
    public let workspace: URL
    public let shell: RemoteShell?

    public init(workspace: URL, shell: RemoteShell?) {
        self.workspace = workspace
        self.shell = shell
    }

    public var specs: [ToolSpec] {
        var specs = [
            ToolSpec(name: "read_file", description: "Read a text file from the on-device workspace.",
                     parametersJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Path relative to the workspace root"}},"required":["path"]}"#),
            ToolSpec(name: "write_file", description: "Create or overwrite a text file in the on-device workspace.",
                     parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}"#),
            ToolSpec(name: "list_files", description: "List files in a directory of the on-device workspace.",
                     parametersJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Directory relative to the workspace root; omit for the root"}}}"#),
            ToolSpec(name: "fetch_url", description: "Fetch a web page or API response over HTTP(S) and return its text.",
                     parametersJSON: #"{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}"#),
        ]
        if shell != nil {
            specs.insert(ToolSpec(
                name: "ssh_exec",
                description: "Run a shell command on the connected remote host over SSH. Non-interactive: no TTY, no prompts. Returns combined stdout/stderr and the exit code.",
                parametersJSON: #"{"type":"object","properties":{"command":{"type":"string"},"timeout_seconds":{"type":"number","description":"Default 120, max 900"}},"required":["command"]}"#), at: 0)
        }
        return specs
    }

    public func needsApproval(_ call: ToolCall) -> Bool {
        call.name != "read_file" && call.name != "list_files"
    }

    public func summary(_ call: ToolCall) -> String {
        switch call.name {
        case "ssh_exec": return "ssh \(shell?.label ?? "?") $ \(call.string("command") ?? "")"
        case "read_file": return "read \(call.string("path") ?? "")"
        case "write_file": return "write \(call.string("path") ?? "") (\((call.string("content") ?? "").utf8.count) bytes)"
        case "list_files": return "ls \(call.string("path") ?? ".")"
        case "fetch_url": return "fetch \(call.string("url") ?? "")"
        default: return call.name
        }
    }

    public func run(_ call: ToolCall, onOutput: @escaping @Sendable (String) -> Void) async -> ToolResult {
        do {
            switch call.name {
            case "ssh_exec": return try await sshExec(call, onOutput: onOutput)
            case "read_file": return try readFile(call)
            case "write_file": return try writeFile(call)
            case "list_files": return try listFiles(call)
            case "fetch_url": return try await fetchURL(call)
            default: return ToolResult(text: "unknown tool: \(call.name)", isError: true)
            }
        } catch is CancellationError {
            return ToolResult(text: "cancelled", isError: true)
        } catch {
            return ToolResult(text: "error: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: Workspace

    struct ToolError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Resolves a model-supplied path, refusing anything that escapes the workspace.
    func resolve(_ path: String) throws -> URL {
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath()
        var relative = path.trimmingCharacters(in: .whitespaces)
        while relative.hasPrefix("/") { relative.removeFirst() }
        let target = relative.isEmpty || relative == "." ? root
            : root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        guard target.path == root.path || target.path.hasPrefix(root.path + "/") else {
            throw ToolError(message: "path is outside the workspace: \(path)")
        }
        return target
    }

    private func require(_ call: ToolCall, _ key: String) throws -> String {
        guard let value = call.string(key) else { throw ToolError(message: "missing argument: \(key)") }
        return value
    }

    private func readFile(_ call: ToolCall) throws -> ToolResult {
        let url = try resolve(try require(call, "path"))
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolError(message: "not a UTF-8 text file (\(data.count) bytes)")
        }
        return ToolResult(text: Truncate.middle(text, limit: 60_000))
    }

    private func writeFile(_ call: ToolCall) throws -> ToolResult {
        let url = try resolve(try require(call, "path"))
        let content = try require(call, "content")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url, options: .atomic)
        return ToolResult(text: "wrote \(content.utf8.count) bytes")
    }

    private func listFiles(_ call: ToolCall) throws -> ToolResult {
        let url = try resolve(call.string("path") ?? "")
        let entries = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])
        let lines = entries.map { entry -> String in
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            return values?.isDirectory == true ? entry.lastPathComponent + "/"
                : "\(entry.lastPathComponent)  \(values?.fileSize ?? 0)"
        }
        .sorted()
        return ToolResult(text: lines.isEmpty ? "(empty)" : lines.joined(separator: "\n"))
    }

    // MARK: Network

    private func fetchURL(_ call: ToolCall) async throws -> ToolResult {
        let raw = try require(call, "url")
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw ToolError(message: "only http and https URLs are supported")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (status, body) = try await HTTP.collect(request, limit: 400_000)
        var text = String(decoding: body, as: UTF8.self)
        if text.range(of: "<html", options: .caseInsensitive) != nil { text = Self.stripHTML(text) }
        return ToolResult(text: "HTTP \(status)\n" + Truncate.middle(text), isError: !(200..<400).contains(status))
    }

    static func stripHTML(_ html: String) -> String {
        var text = html
        for pattern in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "<[^>]+>"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        for (entity, value) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s*\\n\\s*", with: "\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: SSH

    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""

        func append(_ chunk: String) {
            lock.lock()
            defer { lock.unlock() }
            // Bounded so a runaway command cannot exhaust memory; the tail matters most.
            text += chunk
            if text.count > 400_000 { text = String(text.suffix(200_000)) }
        }

        var value: String {
            lock.lock()
            defer { lock.unlock() }
            return text
        }
    }

    private func sshExec(_ call: ToolCall, onOutput: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        guard let shell else {
            throw ToolError(message: "no SSH host is connected; the user can add one with /config and select it with /host")
        }
        let command = try require(call, "command")
        let timeout = min(max(call.number("timeout_seconds") ?? 120, 1), 900)
        let buffer = OutputBuffer()
        let code = try await shell.run(command: command, timeout: timeout) { chunk in
            buffer.append(chunk)
            onOutput(chunk)
        }
        let output = Truncate.middle(buffer.value)
        return ToolResult(text: (output.isEmpty ? "" : output + "\n") + "[exit \(code)]", isError: code != 0)
    }
}
