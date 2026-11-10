import XCTest
@testable import TermCore

/// Replays scripted streams, one per model call, and records the requests it received.
final class ScriptedClient: ChatStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[StreamEvent]]
    private(set) var requests: [ChatRequest] = []

    init(_ scripts: [[StreamEvent]]) {
        self.scripts = scripts
    }

    func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        lock.lock()
        requests.append(request)
        let events = scripts.isEmpty ? [] : scripts.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            events.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}

struct FakeShell: RemoteShell {
    var label = "box"
    func run(command: String, timeout: TimeInterval, onOutput: @escaping @Sendable (String) -> Void) async throws -> Int {
        onOutput("ran: \(command)\n")
        return command.contains("fail") ? 3 : 0
    }
}

actor Recorder {
    var messages: [ChatMessage] = []
    var finished: [(id: String, result: ToolResult, denied: Bool)] = []
    var text = ""

    func record(_ event: AgentEvent) {
        switch event {
        case .message(let message): messages.append(message)
        case .toolFinished(let id, let result, let denied): finished.append((id, result, denied))
        case .assistantDelta(let delta): text += delta
        default: break
        }
    }
}

final class TermCoreTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("termcore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
    }

    // MARK: Streaming

    func testSSEParserHandlesSplitChunksAndCRLF() {
        var parser = SSEParser()
        XCTAssertEqual(parser.feed(Data("data: {\"a\"".utf8)), [])
        XCTAssertEqual(parser.feed(Data(":1}\r\n\r\ndata:[DONE]\n: comment\nevent: x\n".utf8)), ["{\"a\":1}", "[DONE]"])
    }

    func testSSEParserKeepsMultibyteCharactersSplitAcrossChunks() {
        var parser = SSEParser()
        let bytes = Array("data: héllo ✓\n".utf8)
        XCTAssertEqual(parser.feed(Data(bytes[..<8])), [])
        XCTAssertEqual(parser.feed(Data(bytes[8...])), ["héllo ✓"])
    }

    func testDecodeTextToolCallsAndUsage() {
        XCTAssertEqual(OpenAIClient.decode(#"{"choices":[{"delta":{"content":"hi"}}]}"#), [.text("hi")])
        XCTAssertEqual(
            OpenAIClient.decode(#"{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"c1","function":{"name":"ssh_exec","arguments":"{\"co"}}]}}]}"#),
            [.toolCallDelta(index: 1, id: "c1", name: "ssh_exec", arguments: "{\"co")])
        XCTAssertEqual(OpenAIClient.decode(#"{"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":3}}"#),
                       [.usage(input: 12, output: 3)])
        XCTAssertEqual(OpenAIClient.decode("not json"), [])
    }

    func testRequestBodyAndEndpoint() throws {
        let request = ChatRequest(
            baseURL: "https://example.com/v1/", apiKey: "k", model: "m",
            messages: [
                ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "c1", name: "ssh_exec", arguments: "")]),
                ChatMessage(role: .tool, content: "out", toolCallID: "c1"),
            ],
            tools: ToolBox(workspace: workspace, shell: FakeShell()).specs)
        let urlRequest = try OpenAIClient.urlRequest(for: request)
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer k")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(urlRequest.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "m")
        XCTAssertEqual(body["stream"] as? Bool, true)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let call = try XCTUnwrap((messages[0]["tool_calls"] as? [[String: Any]])?.first)
        XCTAssertEqual((call["function"] as? [String: Any])?["arguments"] as? String, "{}")
        XCTAssertEqual(messages[1]["tool_call_id"] as? String, "c1")
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        // ssh_exec plus the eight file and web tools.
        XCTAssertEqual(tools.count, 9)
        let schema = (tools[0]["function"] as? [String: Any])?["parameters"] as? [String: Any]
        XCTAssertEqual(schema?["type"] as? String, "object")

        XCTAssertThrowsError(try OpenAIClient.endpoint("ftp://x", "/models"))
        XCTAssertThrowsError(try OpenAIClient.endpoint("not a url", "/models"))
    }

    func testAPIErrorExtractsMessage() {
        let error = APIError.from(status: 401, body: Data(#"{"error":{"message":"bad key"}}"#.utf8))
        XCTAssertEqual(error, APIError(status: 401, message: "bad key"))
        XCTAssertEqual(APIError.from(status: 502, body: Data("Bad Gateway".utf8)).message, "Bad Gateway")
    }

    // MARK: Agent

    func testAgentRunsToolThenAnswers() async throws {
        let client = ScriptedClient([
            [.text("checking"),
             .toolCallDelta(index: 0, id: "c1", name: "ssh_exec", arguments: "{\"command\":"),
             .toolCallDelta(index: 0, id: nil, name: nil, arguments: "\"uptime\"}")],
            [.text("all good")],
        ])
        let recorder = Recorder()
        let agent = Agent(client: client, tools: ToolBox(workspace: workspace, shell: FakeShell()))
        try await agent.run(
            request: ChatRequest(baseURL: "http://x", apiKey: "", model: "m", messages: [ChatMessage(role: .user, content: "status?")]),
            approve: { _, summary in
                XCTAssertEqual(summary, "ssh box $ uptime")
                return .allow
            },
            emit: { await recorder.record($0) })

        let messages = await recorder.messages
        XCTAssertEqual(messages.map(\.role), [.assistant, .tool, .assistant])
        XCTAssertEqual(messages[0].toolCalls?.first?.arguments, "{\"command\":\"uptime\"}")
        XCTAssertEqual(messages[1].toolCallID, "c1")
        XCTAssertEqual(messages[1].content, "ran: uptime\n\n[exit 0]")
        XCTAssertEqual(messages[2].content, "all good")

        // The second model call must see the tool result.
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertEqual(client.requests[1].messages.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(client.requests[0].tools.first?.name, "ssh_exec")
    }

    func testDeniedToolIsReportedToTheModelAndNotRun() async throws {
        let client = ScriptedClient([
            [.toolCallDelta(index: 0, id: "c1", name: "write_file", arguments: "{\"path\":\"a.txt\",\"content\":\"x\"}")],
            [.text("ok, skipped")],
        ])
        let recorder = Recorder()
        let agent = Agent(client: client, tools: ToolBox(workspace: workspace, shell: nil))
        try await agent.run(
            request: ChatRequest(baseURL: "http://x", apiKey: "", model: "m", messages: [ChatMessage(role: .user, content: "write")]),
            approve: { _, _ in .deny },
            emit: { await recorder.record($0) })

        let finished = await recorder.finished
        XCTAssertEqual(finished.count, 1)
        XCTAssertTrue(finished[0].denied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("a.txt").path))
        let messages = await recorder.messages
        XCTAssertEqual(messages[1].role, .tool)
        XCTAssertTrue(messages[1].content.contains("declined"))
    }

    func testReadOnlyToolsSkipApprovalAndFailedCommandsAreErrors() async throws {
        try Data("hello".utf8).write(to: workspace.appendingPathComponent("note.txt"))
        let client = ScriptedClient([
            [.toolCallDelta(index: 0, id: "", name: "read_file", arguments: "{\"path\":\"note.txt\"}"),
             .toolCallDelta(index: 1, id: "c2", name: "ssh_exec", arguments: "{\"command\":\"fail\"}")],
            [.text("done")],
        ])
        let recorder = Recorder()
        let asked = Recorder()
        let agent = Agent(client: client, tools: ToolBox(workspace: workspace, shell: FakeShell()))
        try await agent.run(
            request: ChatRequest(baseURL: "http://x", apiKey: "", model: "m", messages: [ChatMessage(role: .user, content: "go")]),
            approve: { call, _ in
                await asked.record(.assistantDelta(call.name))
                return .allow
            },
            emit: { await recorder.record($0) })

        let askedFor = await asked.text
        XCTAssertEqual(askedFor, "ssh_exec")
        let finished = await recorder.finished
        XCTAssertEqual(finished[0].result, ToolResult(text: "hello"))
        XCTAssertTrue(finished[1].result.isError)
        XCTAssertTrue(finished[1].result.text.hasSuffix("[exit 3]"))
        // A call that arrived without an id still gets one, so its result can be matched.
        let messages = await recorder.messages
        XCTAssertFalse(try XCTUnwrap(messages[0].toolCalls?[0].id).isEmpty)
        XCTAssertEqual(messages[1].toolCallID, messages[0].toolCalls?[0].id)
    }

    func testAgentStopsAfterMaxSteps() async {
        let loop: [StreamEvent] = [.toolCallDelta(index: 0, id: "c", name: "list_files", arguments: "{}")]
        let agent = Agent(client: ScriptedClient([loop, loop, loop]), tools: ToolBox(workspace: workspace, shell: nil), maxSteps: 2)
        do {
            try await agent.run(
                request: ChatRequest(baseURL: "http://x", apiKey: "", model: "m", messages: []),
                approve: { _, _ in .allow }, emit: { _ in })
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AgentError, .tooManySteps(2))
        }
    }

    // MARK: Tools

    func testWorkspaceToolsStayInsideWorkspace() async throws {
        let tools = ToolBox(workspace: workspace, shell: nil)
        let write = await tools.run(ToolCall(id: "1", name: "write_file", arguments: #"{"path":"dir/a.txt","content":"abc"}"#)) { _ in }
        XCTAssertEqual(write, ToolResult(text: "wrote 3 bytes"))
        let list = await tools.run(ToolCall(id: "2", name: "list_files", arguments: #"{"path":"dir"}"#)) { _ in }
        XCTAssertEqual(list.text, "a.txt  3")
        let root = await tools.run(ToolCall(id: "3", name: "list_files", arguments: "{}")) { _ in }
        XCTAssertEqual(root.text, "dir/")

        for path in ["../outside.txt", "dir/../../outside.txt", "/../../etc/passwd"] {
            let escaped = await tools.run(ToolCall(id: "4", name: "read_file", arguments: "{\"path\":\"\(path)\"}")) { _ in }
            XCTAssertTrue(escaped.isError, path)
            XCTAssertTrue(escaped.text.contains("outside the workspace"), escaped.text)
        }
        // An absolute-looking path is treated as relative to the workspace root.
        let absolute = await tools.run(ToolCall(id: "5", name: "read_file", arguments: #"{"path":"/dir/a.txt"}"#)) { _ in }
        XCTAssertEqual(absolute.text, "abc")

        let noShell = await tools.run(ToolCall(id: "6", name: "ssh_exec", arguments: #"{"command":"ls"}"#)) { _ in }
        XCTAssertTrue(noShell.isError)
        XCTAssertFalse(tools.specs.contains { $0.name == "ssh_exec" })
    }

    func testSymlinkCannotEscapeWorkspace() async throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("secret".utf8).write(to: outside.appendingPathComponent("s.txt"))
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("link"), withDestinationURL: outside)

        let result = await ToolBox(workspace: workspace, shell: nil)
            .run(ToolCall(id: "1", name: "read_file", arguments: #"{"path":"link/s.txt"}"#)) { _ in }
        XCTAssertTrue(result.isError, result.text)
    }

    func testTruncateAndStripHTML() {
        let long = String(repeating: "a", count: 50) + String(repeating: "b", count: 50)
        let cut = Truncate.middle(long, limit: 20)
        XCTAssertTrue(cut.hasPrefix("aaaaaaaaaa\n"))
        XCTAssertTrue(cut.hasSuffix("\nbbbbbbbbbb"))
        XCTAssertTrue(cut.contains("80 characters omitted"))
        XCTAssertEqual(ToolBox.stripHTML("<html><style>p{}</style><p>Tom &amp; Jerry</p><script>x()</script></html>"), "Tom & Jerry")
    }

    func testMarkdownSegmentsAndExport() {
        XCTAssertEqual(Markdown.segments("intro\n\n```sh\nls -la\n\necho hi\n```\nafter"), [
            .init(isCode: false, text: "intro"),
            .init(isCode: true, text: "ls -la\n\necho hi"),
            .init(isCode: false, text: "after"),
        ])
        // A fence still open while streaming renders as code.
        XCTAssertEqual(Markdown.segments("a\n```\nx = 1"), [.init(isCode: false, text: "a"), .init(isCode: true, text: "x = 1")])
        XCTAssertEqual(Markdown.segments(""), [])

        let session = Session(title: "t", transcript: [
            TranscriptItem(kind: .user, text: "hi"), TranscriptItem(kind: .info, text: "noise"),
            TranscriptItem(kind: .tool, text: "up 3 days", title: "ssh box $ uptime"), TranscriptItem(kind: .assistant, text: "fine"),
        ])
        XCTAssertEqual(Markdown.export(session), "# t\n\n**❯ hi**\n\n```\nssh box $ uptime\nup 3 days\n```\n\nfine\n")
    }

    func testToolOutputArrivesInOrderBeforeTheResult() async throws {
        struct Chatty: RemoteShell {
            var label = "box"
            func run(command: String, timeout: TimeInterval, onOutput: @escaping @Sendable (String) -> Void) async throws -> Int {
                for n in 0..<200 { onOutput("\(n),") }
                return 0
            }
        }
        actor Log {
            var entries: [String] = []
            func add(_ entry: String) { entries.append(entry) }
        }
        let log = Log()
        let client = ScriptedClient([[.toolCallDelta(index: 0, id: "c1", name: "ssh_exec", arguments: "{\"command\":\"x\"}")], [.text("ok")]])
        try await Agent(client: client, tools: ToolBox(workspace: workspace, shell: Chatty())).run(
            request: ChatRequest(baseURL: "http://x", apiKey: "", model: "m", messages: []),
            approve: { _, _ in .allow },
            emit: { event in
                switch event {
                case .toolOutput(_, let chunk): await log.add(chunk)
                case .toolFinished: await log.add("END")
                default: break
                }
            })
        let entries = await log.entries
        XCTAssertEqual(entries, (0..<200).map { "\($0)," } + ["END"])
    }

    // MARK: Commands, storage

    func testCommandParsing() {
        XCTAssertEqual(Commands.parse("  "), .empty)
        XCTAssertEqual(Commands.parse("hello"), .prompt("hello"))
        XCTAssertEqual(Commands.parse("/model  gpt-x "), .command(name: "model", args: "gpt-x"))
        XCTAssertEqual(Commands.parse("/NEW"), .command(name: "new", args: ""))
        XCTAssertEqual(Commands.parse("/etc/hosts looks odd"), .prompt("/etc/hosts looks odd"))
        XCTAssertEqual(Commands.parse("! ls -la"), .shell("ls -la"))
        XCTAssertEqual(Commands.parse("!"), .empty)
        XCTAssertEqual(Commands.suggestions(for: "/se").map(\.name), ["setup", "sessions"])
        XCTAssertEqual(Commands.suggestions(for: "/model x"), [])
        XCTAssertEqual(Commands.suggestions(for: "hi"), [])
        XCTAssertEqual(Commands.parse("/context 32k"), .command(name: "context", args: "32k"))
        XCTAssertEqual(Commands.parse("/compact keep the nginx fix"), .command(name: "compact", args: "keep the nginx fix"))
        XCTAssertEqual(Commands.parse("/folder/photos is full"), .prompt("/folder/photos is full"))
        XCTAssertEqual(Commands.suggestions(for: "/co").map(\.name), ["config", "cowork", "context", "compact", "copy"])
    }

    func testStorageRoundTrip() {
        let storage = Storage(directory: workspace)
        let profile = Profile(name: "p", baseURL: "https://x/v1", models: ["a", "b"])
        storage.saveProfiles([profile])
        storage.saveHosts([SSHHost(name: "h", host: "example.com", port: 2222, username: "u", auth: .privateKey)])
        var settings = AppSettings()
        settings.themeID = "crt-amber"
        settings.approvalMode = .auto
        storage.saveSettings(settings)

        // Whole-second dates: the store keeps ISO 8601 timestamps without fractions.
        let older = Session(title: "older", createdAt: Date(timeIntervalSince1970: 50), updatedAt: Date(timeIntervalSince1970: 100),
                            messages: [ChatMessage(role: .user, content: "1")])
        let newer = Session(title: "newer", createdAt: Date(timeIntervalSince1970: 60), updatedAt: Date(timeIntervalSince1970: 200), messages: [ChatMessage(role: .user, content: "2")],
                            transcript: [TranscriptItem(kind: .tool, text: "out", title: "ssh $ ls", status: .ok)])
        storage.saveSession(older)
        storage.saveSession(newer)
        storage.saveSession(Session())  // empty sessions are not persisted

        let reloaded = Storage(directory: workspace)
        XCTAssertEqual(reloaded.loadProfiles(), [profile])
        XCTAssertEqual(reloaded.loadHosts().first?.address, "u@example.com:2222")
        XCTAssertEqual(reloaded.loadSettings(), settings)
        XCTAssertEqual(reloaded.sessionSummaries().map(\.title), ["newer", "older"])
        XCTAssertEqual(reloaded.loadSession(id: newer.id), newer)
        reloaded.deleteSession(id: newer.id)
        XCTAssertEqual(reloaded.sessionSummaries().map(\.title), ["older"])
        XCTAssertEqual(Theme.named("nope"), .minimalDark)
    }

    // MARK: File tools

    func testEditSearchMoveAndDeleteStayInsideTheWorkspace() async throws {
        let tools = ToolBox(workspace: workspace, shell: nil)
        func run(_ name: String, _ arguments: String) async -> ToolResult {
            await tools.run(ToolCall(id: "1", name: name, arguments: arguments)) { _ in }
        }
        // Double pound signs: the Markdown heading would otherwise close the raw string.
        _ = await run("write_file", ##"{"path":"notes/todo.md","content":"# Todo\n- buy milk\n- call Anna\n"}"##)
        _ = await run("write_file", #"{"path":"readme.txt","content":"Milk is in the fridge.\nmilk again\n"}"#)

        // edit_file changes one passage and refuses to guess.
        let edited = await run("edit_file", #"{"path":"notes/todo.md","old_text":"buy milk","new_text":"buy oat milk"}"#)
        XCTAssertEqual(edited, ToolResult(text: "edited notes/todo.md: 8 bytes replaced with 12"))
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("notes/todo.md"), encoding: .utf8),
                       "# Todo\n- buy oat milk\n- call Anna\n")
        let missing = await run("edit_file", #"{"path":"notes/todo.md","old_text":"buy bread","new_text":"x"}"#)
        XCTAssertTrue(missing.isError && missing.text.contains("was not found"), missing.text)
        let ambiguous = await run("edit_file", #"{"path":"notes/todo.md","old_text":"- ","new_text":"* "}"#)
        XCTAssertTrue(ambiguous.isError && ambiguous.text.contains("occurs 2 times"), ambiguous.text)

        // search_files reports workspace paths and line numbers, and reads neither hidden files nor symlinks.
        try Data("milk secret".utf8).write(to: workspace.appendingPathComponent(".hidden"))
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("milk outside".utf8).write(to: outside.appendingPathComponent("o.txt"))
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("link"), withDestinationURL: outside)
        let found = await run("search_files", #"{"query":"MILK"}"#)
        XCTAssertEqual(found.text, "notes/todo.md:2: - buy oat milk\nreadme.txt:1: Milk is in the fridge.\nreadme.txt:2: milk again")
        let scoped = await run("search_files", #"{"query":"milk","path":"notes/"}"#)
        XCTAssertEqual(scoped.text, "notes/todo.md:2: - buy oat milk")
        let none = await run("search_files", #"{"query":"bread"}"#)
        XCTAssertEqual(none, ToolResult(text: "no matches"))
        XCTAssertFalse(tools.needsApproval(ToolCall(id: "1", name: "search_files", arguments: "{}")))

        // list_files can take in the whole tree at once.
        let tree = await run("list_files", #"{"recursive":true}"#)
        XCTAssertEqual(tree.text, "notes/\nnotes/todo.md  34\nreadme.txt  34")
        let flags = ToolCall(id: "1", name: "x", arguments: #"{"a":true,"b":"yes","c":false}"#)
        XCTAssertEqual([flags.bool("a"), flags.bool("b"), flags.bool("c"), flags.bool("d")], [true, true, false, nil])

        // move_file creates the folders it needs and never overwrites.
        let moved = await run("move_file", #"{"from":"readme.txt","to":"docs/2026/readme.txt"}"#)
        XCTAssertEqual(moved, ToolResult(text: "moved readme.txt → docs/2026/readme.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("docs/2026/readme.txt").path))
        let clash = await run("move_file", #"{"from":"notes/todo.md","to":"docs/2026/readme.txt"}"#)
        XCTAssertTrue(clash.isError && clash.text.contains("already exists"), clash.text)
        let escape = await run("move_file", #"{"from":"notes/todo.md","to":"../stolen.md"}"#)
        XCTAssertTrue(escape.isError && escape.text.contains("outside the workspace"), escape.text)

        // delete_file removes files and folders, but never the workspace itself.
        let deleted = await run("delete_file", #"{"path":"docs"}"#)
        XCTAssertEqual(deleted, ToolResult(text: "deleted docs"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("docs").path))
        for root in ["", ".", "/"] {
            let refused = await run("delete_file", "{\"path\":\"\(root)\"}")
            XCTAssertTrue(refused.isError && refused.text.contains("workspace folder itself"), refused.text)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("notes/todo.md").path))
        let gone = await run("delete_file", #"{"path":"docs"}"#)
        XCTAssertTrue(gone.isError && gone.text.contains("no such file"), gone.text)

        for name in ["edit_file", "move_file", "delete_file"] {
            XCTAssertTrue(tools.needsApproval(ToolCall(id: "1", name: name, arguments: "{}")), name)
        }
        XCTAssertEqual(tools.summary(ToolCall(id: "1", name: "move_file", arguments: #"{"from":"a","to":"b/a"}"#)), "move a → b/a")
        XCTAssertEqual(tools.summary(ToolCall(id: "1", name: "search_files", arguments: #"{"query":"milk","path":"notes"}"#)),
                       "search \"milk\" in notes")
    }

    // MARK: Context

    func testTokenEstimatesFormattingAndParsing() {
        XCTAssertEqual(Tokens.estimate(""), 0)
        XCTAssertEqual(Tokens.estimate("abcd"), 1)
        XCTAssertEqual(Tokens.estimate("abcde"), 2)
        // Twelve bytes: scripts outside ASCII cost more tokens per character.
        XCTAssertEqual(Tokens.estimate("привет"), 3)
        let call = ToolCall(id: "c", name: "read", arguments: "{\"path\":1}")
        XCTAssertEqual(Tokens.estimate(ChatMessage(role: .assistant, content: "abcdefgh", toolCalls: [call])), 4 + 2 + 4 + 1 + 3)

        XCTAssertEqual([950, 1_234, 2_000, 64_000, 999_949, 999_950, 1_500_000].map(Tokens.format),
                       ["950", "1.2k", "2k", "64k", "999.9k", "1M", "1.5M"])
        XCTAssertEqual(Tokens.parse("64k"), 64_000)
        XCTAssertEqual(Tokens.parse(" 1.5M "), 1_500_000)
        XCTAssertEqual(Tokens.parse("32000"), 32_000)
        XCTAssertNil(Tokens.parse("lots"))
        XCTAssertNil(Tokens.parse("0"))
        XCTAssertNil(Tokens.parse("-4k"))
    }

    func testContextUsageSplitsTheRequestByRole() {
        let messages = [
            ChatMessage(role: .user, content: String(repeating: "u", count: 40)),
            ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "c1", name: "read_file", arguments: "{}")]),
            ChatMessage(role: .tool, content: String(repeating: "t", count: 400), toolCallID: "c1"),
            ChatMessage(role: .assistant, content: String(repeating: "a", count: 80)),
        ]
        let usage = ContextUsage(system: String(repeating: "s", count: 200), tools: [], summary: String(repeating: "m", count: 20),
                                 messages: messages, limit: 1_000)
        XCTAssertEqual(usage.system, 50)
        XCTAssertEqual(usage.tools, 0)
        XCTAssertEqual(usage.summary, 5)
        XCTAssertEqual(usage.user, 14)
        XCTAssertEqual(usage.assistant, 36)
        XCTAssertEqual(usage.toolResults, 104)
        XCTAssertEqual(usage.total, 209)
        XCTAssertEqual(usage.percent, 21)
        XCTAssertFalse(usage.isOverBudget)
        XCTAssertTrue(ContextUsage(system: "", tools: [], summary: nil, messages: messages, limit: 150).isOverBudget)
        // Tool definitions travel with every request as well.
        XCTAssertGreaterThan(ContextUsage(system: "", tools: ToolBox.specs(shell: true), summary: nil, messages: [], limit: 1_000).tools, 200)

        let report = usage.report(reported: 1_840, autoCompact: true)
        XCTAssertTrue(report.hasPrefix("context ██░░░░░░░░ 21%\nabout 209 of 1k tokens\n"), report)
        let rows = report.split(separator: "\n").map { $0.split(separator: " ").joined(separator: " ") }
        for row in ["system prompt 50", "tools 0", "summary 5", "you 14", "assistant 36", "tool results 104", "4 messages in the history",
                    "last request: 1.8k tokens, counted by the API", "auto-compress: on, at 80% of the limit"] {
            XCTAssertTrue(rows.contains(row), "\(row) missing from:\n\(report)")
        }
        let quiet = ContextUsage(system: "", tools: [], summary: nil, messages: [], limit: 1_000).report(reported: nil, autoCompact: false)
        // Rows with nothing to report are left out.
        XCTAssertFalse(quiet.split(separator: "\n").contains { $0.hasPrefix("summary") }, quiet)
        XCTAssertFalse(quiet.contains("last request"), quiet)
        XCTAssertTrue(quiet.contains("context ░░░░░░░░░░ 0%") && quiet.contains("auto-compress: off"), quiet)
    }

    func testTrimmingOldToolOutputKeepsTheNewestResults() {
        let big = String(repeating: "x", count: 4_000)
        var messages = [ChatMessage(role: .user, content: "go")]
        for n in 0..<6 {
            messages.append(ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "c\(n)", name: "read_file", arguments: "{}")]))
            messages.append(ChatMessage(role: .tool, content: n == 1 ? "short" : big, toolCallID: "c\(n)"))
        }
        let before = Tokens.estimate(messages)
        let saved = Compaction.trimToolResults(in: &messages, keep: 4)
        let results = messages.filter { $0.role == .tool }

        XCTAssertTrue(results[0].content.hasPrefix(String(repeating: "x", count: 300) + "\n… [3700 more characters"), results[0].content)
        XCTAssertEqual(results[1].content, "short")
        XCTAssertEqual(results[2...].map(\.content), [big, big, big, big])
        // Every result still answers its call, or the next request would be rejected.
        XCTAssertEqual(results.compactMap(\.toolCallID), (0..<6).map { "c\($0)" })
        XCTAssertEqual(Tokens.estimate(messages), before - saved)
        XCTAssertGreaterThan(saved, 800)
        // Nothing is left to trim the second time round.
        XCTAssertEqual(Compaction.trimToolResults(in: &messages, keep: 4), 0)
    }

    func testAgentTrimsOldToolOutputOnceTheRequestOutgrowsItsBudget() async throws {
        try Data(String(repeating: "y", count: 8_000).utf8).write(to: workspace.appendingPathComponent("big.txt"))
        let read: [StreamEvent] = [.toolCallDelta(index: 0, id: nil, name: "read_file", arguments: "{\"path\":\"big.txt\"}")]
        let client = ScriptedClient(Array(repeating: read, count: 6) + [[.text("done")]])
        actor History {
            var messages: [ChatMessage]
            var savings: [Int] = []
            init(_ messages: [ChatMessage]) { self.messages = messages }
            func apply(_ event: AgentEvent) {
                switch event {
                case .message(let message): messages.append(message)
                case .trimmed(let replacement, let saved):
                    messages = replacement
                    savings.append(saved)
                default: break
                }
            }
        }
        let prompt = ChatMessage(role: .user, content: "read it six times")
        let history = History([prompt])
        // Each read adds about 2k tokens, so the request passes 10k once five results are in it.
        let agent = Agent(client: client, tools: ToolBox(workspace: workspace, shell: nil), trimAbove: 10_000)
        try await agent.run(
            request: ChatRequest(baseURL: "http://x", apiKey: "", model: "m", messages: [ChatMessage(role: .system, content: "sys"), prompt]),
            approve: { _, _ in .allow }, emit: { await history.apply($0) })

        func results(_ index: Int) -> [Bool] {
            client.requests[index].messages.filter { $0.role == .tool }.map { $0.content.count < 1_000 }
        }
        XCTAssertEqual(client.requests.count, 7)
        XCTAssertEqual(results(4), [false, false, false, false])
        XCTAssertEqual(results(5), [true, false, false, false, false])
        XCTAssertEqual(results(6), [true, true, false, false, false, false])

        // The caller's history was replaced with the trimmed one, so it matches what the model was sent.
        let savings = await history.savings
        XCTAssertEqual(savings.count, 2)
        XCTAssertTrue(savings.allSatisfy { $0 > 1_500 }, "\(savings)")
        let kept = await history.messages
        XCTAssertEqual(Array(kept.dropLast()), Array(client.requests[6].messages.dropFirst()))
        XCTAssertEqual(kept.last?.content, "done")

        // Without a budget nothing is touched.
        let untouched = ScriptedClient(Array(repeating: read, count: 6) + [[.text("done")]])
        try await Agent(client: untouched, tools: ToolBox(workspace: workspace, shell: nil)).run(
            request: ChatRequest(baseURL: "http://x", apiKey: "", model: "m", messages: [prompt]),
            approve: { _, _ in .allow }, emit: { _ in })
        XCTAssertEqual(untouched.requests[6].messages.filter { $0.role == .tool }.map(\.content.count), Array(repeating: 8_000, count: 6))
    }

    func testSummarizeSendsADigestAndReturnsTheSummary() async throws {
        let client = ScriptedClient([[.text(" The user wants nginx fixed.\n"), .usage(input: 9, output: 4)], [.text("short")], []])
        let endpoint = ChatRequest(baseURL: "http://x", apiKey: "k", model: "m", messages: [ChatMessage(role: .user, content: "ignored")],
                                   tools: ToolBox.specs(shell: true))
        let messages = [
            ChatMessage(role: .user, content: "why is nginx down?"),
            ChatMessage(role: .assistant, content: "checking",
                        toolCalls: [ToolCall(id: "c1", name: "ssh_exec", arguments: "{\"command\":\"systemctl status nginx\"}")]),
            ChatMessage(role: .tool, content: String(repeating: "log line\n", count: 1_000), toolCallID: "c1"),
        ]
        let summary = try await Compaction.summarize(client: client, endpoint: endpoint, summary: "Earlier: set up the host.",
                                                     messages: messages, focus: " the config typo ")
        XCTAssertEqual(summary, "The user wants nginx fixed.")

        let request = client.requests[0]
        XCTAssertEqual(request.model, "m")
        XCTAssertEqual(request.apiKey, "k")
        XCTAssertTrue(request.tools.isEmpty)
        XCTAssertEqual(request.messages.map(\.role), [.system, .user])
        XCTAssertTrue(request.messages[0].content.hasSuffix("focus on: the config typo"), request.messages[0].content)
        let digest = request.messages[1].content
        XCTAssertTrue(digest.hasPrefix("[summary of the conversation before this point]\nEarlier: set up the host.\n\n[user]\nwhy is nginx down?\n\n[assistant]\nchecking\n\n[assistant called ssh_exec]\n{\"command\":\"systemctl status nginx\"}\n\n[tool result]\nlog line\n"), digest)
        // 9,000 characters of tool output are cut to their head and tail.
        XCTAssertTrue(digest.contains("characters omitted"), digest)
        XCTAssertLessThan(digest.count, 2_000)

        // A history too long for the model is cut down rather than sent whole.
        let long = (0..<50).map { ChatMessage(role: .user, content: "\($0) " + String(repeating: "z", count: 2_000)) }
        _ = try await Compaction.summarize(client: client, endpoint: endpoint, summary: nil, messages: long, limit: 1_500)
        let cut = client.requests[1].messages[1].content
        XCTAssertLessThan(Tokens.estimate(cut), 1_200)
        XCTAssertTrue(cut.hasPrefix("[user]\n0 zzz") && cut.hasSuffix("zzz"), String(cut.prefix(40)))

        // An empty answer must not replace the history.
        do {
            _ = try await Compaction.summarize(client: client, endpoint: endpoint, summary: nil, messages: messages)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CompactionError, .emptySummary)
        }
    }

    func testPromptsForCoworkAndCompactedHistory() {
        let cowork = SystemPrompt.cowork(custom: " Answer in Russian. ", folder: "Trip to Lisbon")
        XCTAssertTrue(cowork.contains("The folder is \"Trip to Lisbon\""), cowork)
        XCTAssertTrue(cowork.hasSuffix("\nAnswer in Russian."), cowork)
        XCTAssertFalse(cowork.contains("ssh_exec"))

        let base = SystemPrompt.build(custom: "", hostLabel: nil)
        XCTAssertEqual(SystemPrompt.withSummary(base, summary: nil), base)
        XCTAssertEqual(SystemPrompt.withSummary(base, summary: ""), base)
        XCTAssertTrue(SystemPrompt.withSummary(base, summary: "Fixed nginx.").hasSuffix("What happened so far:\nFixed nginx."))

        XCTAssertTrue(APIError(status: 400, message: "This model's maximum context length is 8192 tokens.").isContextOverflow)
        XCTAssertFalse(APIError(status: 401, message: "bad key").isContextOverflow)
        XCTAssertFalse(APIError(status: 400, message: "unknown model").isContextOverflow)
    }

    func testSettingsAndSessionsFromOlderVersionsStillLoad() throws {
        let storage = Storage(directory: workspace)
        // What 0.1 wrote: no chat mode, context settings, session kind or summary.
        let id = UUID()
        try Data(#"{"approvalMode":"auto","fontSize":15,"systemPrompt":"be brief","themeID":"crt-green"}"#.utf8)
            .write(to: workspace.appendingPathComponent("settings.json"))
        try Data("""
            {"id":"\(id.uuidString)","title":"old","createdAt":"2026-01-02T03:04:05Z","updatedAt":"2026-01-02T03:04:06Z",
             "messages":[{"role":"user","content":"hi"}],"transcript":[]}
            """.utf8).write(to: workspace.appendingPathComponent("sessions/\(id.uuidString).json"))

        var settings = storage.loadSettings()
        XCTAssertEqual(settings.themeID, "crt-green")
        XCTAssertEqual(settings.fontSize, 15)
        XCTAssertEqual(settings.approvalMode, .auto)
        XCTAssertEqual(settings.systemPrompt, "be brief")
        XCTAssertEqual(settings.mode, .terminal)
        XCTAssertEqual(settings.contextLimit, AppSettings.defaultContextLimit)
        XCTAssertTrue(settings.autoCompact)
        XCTAssertNil(settings.coworkFolder)

        let old = try XCTUnwrap(storage.loadSession(id: id))
        XCTAssertEqual(old.kind, .terminal)
        XCTAssertNil(old.summary)
        XCTAssertEqual(old.messages, [ChatMessage(role: .user, content: "hi")])

        settings.mode = .cowork
        settings.contextLimit = 32_000
        settings.autoCompact = false
        settings.coworkFolder = Data([1, 2, 3])
        storage.saveSettings(settings)
        XCTAssertEqual(storage.loadSettings(), settings)

        // A compacted session has no messages left but is still worth keeping, and each chat lists its own.
        let compacted = Session(kind: .cowork, title: "tidy", createdAt: Date(timeIntervalSince1970: 1_900_000_000),
                                updatedAt: Date(timeIntervalSince1970: 1_900_000_100), summary: "Sorted the photos.")
        XCTAssertFalse(compacted.isEmpty)
        storage.saveSession(compacted)
        XCTAssertEqual(storage.loadSession(id: compacted.id), compacted)
        XCTAssertEqual(storage.sessionSummaries().map(\.title), ["tidy", "old"])
        XCTAssertEqual(storage.sessionSummaries(kind: .cowork).map(\.title), ["tidy"])
        XCTAssertEqual(storage.sessionSummaries(kind: .terminal).map(\.title), ["old"])
    }

    // MARK: Live HTTP (needs a mock server; see Tests/mock_server.py)

    func testLiveStreamingAgainstMockServer() async throws {
        guard let base = ProcessInfo.processInfo.environment["TERMAI_TEST_BASEURL"] else {
            throw XCTSkip("set TERMAI_TEST_BASEURL to run")
        }
        let client = OpenAIClient()
        let models = try await client.listModels(baseURL: base, apiKey: "test-key")
        XCTAssertEqual(models, ["mock-a", "mock-b"])

        let recorder = Recorder()
        let agent = Agent(client: client, tools: ToolBox(workspace: workspace, shell: FakeShell()))
        try await agent.run(
            request: ChatRequest(baseURL: base, apiKey: "test-key", model: "mock-a", messages: [ChatMessage(role: .user, content: "go")]),
            approve: { _, _ in .allow }, emit: { await recorder.record($0) })
        let messages = await recorder.messages
        XCTAssertEqual(messages.map(\.role), [.assistant, .tool, .assistant])
        XCTAssertEqual(messages[1].content, "ran: echo hi\n\n[exit 0]")
        XCTAssertEqual(messages[2].content, "héllo ✓ done")

        do {
            for try await _ in client.streamChat(ChatRequest(baseURL: base, apiKey: "wrong", model: "m", messages: [])) {}
            XCTFail("expected 401")
        } catch {
            XCTAssertEqual(error as? APIError, APIError(status: 401, message: "bad key"))
        }
    }
}
