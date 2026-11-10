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

/// The agent's tools: files in a workspace folder, web fetch, and commands on the active SSH host.
public struct ToolBox: ToolRunning {
    public let workspace: URL
    public let shell: RemoteShell?

    public init(workspace: URL, shell: RemoteShell?) {
        self.workspace = workspace
        self.shell = shell
    }

    public var specs: [ToolSpec] { Self.specs(shell: shell != nil) }

    /// The tool list; `ssh_exec` is offered only while a host is connected.
    public static func specs(shell: Bool) -> [ToolSpec] {
        var specs = [
            ToolSpec(name: "read_file", description: "Read a text file from the on-device workspace.",
                     parametersJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Path relative to the workspace root"}},"required":["path"]}"#),
            ToolSpec(name: "write_file", description: "Create or overwrite a text file in the on-device workspace.",
                     parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}"#),
            ToolSpec(name: "edit_file", description: "Replace one passage of a workspace text file and leave the rest untouched. Much cheaper than rewriting the file.",
                     parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"},"old_text":{"type":"string","description":"Exact text to replace; it must occur once in the file"},"new_text":{"type":"string"}},"required":["path","old_text","new_text"]}"#),
            ToolSpec(name: "list_files", description: "List files in a directory of the on-device workspace.",
                     parametersJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Directory relative to the workspace root; omit for the root"},"recursive":{"type":"boolean","description":"Include subdirectories"}}}"#),
            ToolSpec(name: "search_files", description: "Find the lines that contain a piece of text in the workspace's files, ignoring case.",
                     parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"},"path":{"type":"string","description":"Directory to search; omit for the whole workspace"}},"required":["query"]}"#),
            ToolSpec(name: "move_file", description: "Move or rename a file or folder inside the workspace.",
                     parametersJSON: #"{"type":"object","properties":{"from":{"type":"string"},"to":{"type":"string"}},"required":["from","to"]}"#),
            ToolSpec(name: "delete_file", description: "Delete a file or folder from the workspace.",
                     parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#),
            ToolSpec(name: "fetch_url", description: "Fetch a web page or API response over HTTP(S) and return its text.",
                     parametersJSON: #"{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}"#),
        ]
        if shell {
            specs.insert(ToolSpec(
                name: "ssh_exec",
                description: "Run a shell command on the connected remote host over SSH. Non-interactive: no TTY, no prompts. Returns combined stdout/stderr and the exit code.",
                parametersJSON: #"{"type":"object","properties":{"command":{"type":"string"},"timeout_seconds":{"type":"number","description":"Default 120, max 900"}},"required":["command"]}"#), at: 0)
        }
        return specs
    }

    public func needsApproval(_ call: ToolCall) -> Bool {
        // Looking is free; anything that changes files or leaves the device asks first.
        !["read_file", "list_files", "search_files"].contains(call.name)
    }

    public func summary(_ call: ToolCall) -> String {
        switch call.name {
        case "ssh_exec": return "ssh \(shell?.label ?? "?") $ \(call.string("command") ?? "")"
        case "read_file": return "read \(call.string("path") ?? "")"
        case "write_file": return "write \(call.string("path") ?? "") (\((call.string("content") ?? "").utf8.count) bytes)"
        case "edit_file": return "edit \(call.string("path") ?? "")"
        case "list_files": return "ls \(call.bool("recursive") == true ? "-R " : "")\(call.string("path") ?? ".")"
        case "search_files": return "search \"\(call.string("query") ?? "")\"" + (call.string("path").map { " in \($0)" } ?? "")
        case "move_file": return "move \(call.string("from") ?? "") → \(call.string("to") ?? "")"
        case "delete_file": return "delete \(call.string("path") ?? "")"
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
            case "edit_file": return try editFile(call)
            case "list_files": return try listFiles(call)
            case "search_files": return try searchFiles(call)
            case "move_file": return try moveFile(call)
            case "delete_file": return try deleteFile(call)
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

    private func editFile(_ call: ToolCall) throws -> ToolResult {
        let path = try require(call, "path")
        let url = try resolve(path)
        let old = try require(call, "old_text")
        let new = try require(call, "new_text")
        guard !old.isEmpty else { throw ToolError(message: "old_text is empty") }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolError(message: "not a UTF-8 text file (\(data.count) bytes)")
        }
        // Exactly one match, so the edit can only land where the model meant it to.
        let matches = text.components(separatedBy: old).count - 1
        guard matches == 1 else {
            throw ToolError(message: matches == 0
                ? "old_text was not found in \(path); read the file and copy the passage exactly"
                : "old_text occurs \(matches) times in \(path); include more of the surrounding text so it is unique")
        }
        try Data(text.replacingOccurrences(of: old, with: new).utf8).write(to: url, options: .atomic)
        return ToolResult(text: "edited \(path): \(old.utf8.count) bytes replaced with \(new.utf8.count)")
    }

    private struct Entry {
        var path: String
        var url: URL
        var isDirectory: Bool
        var size: Int
    }

    /// Everything under `directory`, depth first, with paths that start with `prefix`. Hidden entries and
    /// symbolic links are skipped, so a walk cannot wander out of the workspace.
    private func walk(_ directory: URL, prefix: String, limit: Int, into entries: inout [Entry]) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let children = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for child in children {
            guard entries.count < limit else { return }
            let name = child.lastPathComponent
            let values = try? child.resourceValues(forKeys: keys)
            if name.hasPrefix(".") || values?.isSymbolicLink == true { continue }
            let isDirectory = values?.isDirectory == true
            let path = prefix.isEmpty ? name : prefix + "/" + name
            entries.append(Entry(path: path, url: child, isDirectory: isDirectory, size: values?.fileSize ?? 0))
            if isDirectory { walk(child, prefix: path, limit: limit, into: &entries) }
        }
    }

    /// A model-supplied directory as the start of the paths of what is inside it.
    private func prefix(for path: String?) -> String {
        var value = (path ?? "").trimmingCharacters(in: .whitespaces)
        while value.hasPrefix("/") { value.removeFirst() }
        while value.hasSuffix("/") { value.removeLast() }
        return value == "." ? "" : value
    }

    private func listFiles(_ call: ToolCall) throws -> ToolResult {
        let url = try resolve(call.string("path") ?? "")
        if call.bool("recursive") == true {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ToolError(message: "not a directory: \(call.string("path") ?? ".")")
            }
            let limit = 400
            var entries: [Entry] = []
            walk(url, prefix: prefix(for: call.string("path")), limit: limit, into: &entries)
            var lines = entries.map { $0.isDirectory ? $0.path + "/" : "\($0.path)  \($0.size)" }
            if entries.count >= limit { lines.append("… stopped at \(limit) entries; list a subdirectory for the rest") }
            return ToolResult(text: lines.isEmpty ? "(empty)" : lines.joined(separator: "\n"))
        }
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

    private func searchFiles(_ call: ToolCall) throws -> ToolResult {
        let query = try require(call, "query")
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolError(message: "query is empty") }
        let directory = try resolve(call.string("path") ?? "")
        var entries: [Entry] = []
        walk(directory, prefix: prefix(for: call.string("path")), limit: 3_000, into: &entries)

        let cap = 60
        var lines: [String] = []
        search: for entry in entries where !entry.isDirectory && entry.size <= 1_000_000 {
            // Binary files are not UTF-8 and are passed over.
            guard let data = try? Data(contentsOf: entry.url), let text = String(data: data, encoding: .utf8) else { continue }
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.range(of: query, options: .caseInsensitive) != nil {
                guard lines.count < cap else {
                    lines.append("… more matches not shown; narrow the query or the path")
                    break search
                }
                lines.append("\(entry.path):\(number + 1): \(line.trimmingCharacters(in: .whitespaces).prefix(200))")
            }
        }
        return ToolResult(text: lines.isEmpty ? "no matches" : lines.joined(separator: "\n"))
    }

    private func moveFile(_ call: ToolCall) throws -> ToolResult {
        let from = try require(call, "from")
        let to = try require(call, "to")
        let source = try resolve(from)
        let destination = try resolve(to)
        let files = FileManager.default
        guard source.path != (try resolve("")).path else { throw ToolError(message: "cannot move the workspace folder itself") }
        guard files.fileExists(atPath: source.path) else { throw ToolError(message: "no such file: \(from)") }
        guard !files.fileExists(atPath: destination.path) else { throw ToolError(message: "\(to) already exists") }
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.moveItem(at: source, to: destination)
        return ToolResult(text: "moved \(from) → \(to)")
    }

    private func deleteFile(_ call: ToolCall) throws -> ToolResult {
        let path = try require(call, "path")
        let url = try resolve(path)
        guard url.path != (try resolve("")).path else { throw ToolError(message: "cannot delete the workspace folder itself") }
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError(message: "no such file: \(path)") }
        try FileManager.default.removeItem(at: url)
        return ToolResult(text: "deleted \(path)")
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
