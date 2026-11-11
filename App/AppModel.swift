import Foundation
import Observation
import SwiftUI
import TermCore
import TermSSH
import UIKit

/// What is presented over the chats. A single value, so two sheets can never be asked for at once.
enum AppSheet: Identifiable {
    case settings
    case context
    case share(String)

    var id: String {
        switch self {
        case .settings: return "settings"
        case .context: return "context"
        case .share: return "share"
        }
    }
}

/// The `/setup` wizard: each step consumes one line of input.
enum SetupStep {
    case name
    case baseURL(name: String)
    case apiKey(name: String, baseURL: String)
    case model(name: String, baseURL: String, apiKey: String, models: [String])

    var placeholder: String {
        switch self {
        case .name: return "profile name"
        case .baseURL: return "base url"
        case .apiKey: return "api key (hidden)"
        case .model: return "model id"
        }
    }

    var isSecret: Bool {
        if case .apiKey = self { return true }
        return false
    }
}

private struct Failure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

@MainActor
@Observable
final class AppModel {
    var profiles: [Profile] = []
    var hosts: [SSHHost] = []
    var settings = AppSettings()
    var setup: SetupStep?
    var sheet: AppSheet?
    var showFolderPicker = false
    /// The folder Cowork works in once the user has picked one; nil means the app's own folder.
    var pickedFolder: URL?

    /// Each chat keeps its own state, so a run in one carries on while the other is on screen.
    @ObservationIgnored let terminal: ChatState
    @ObservationIgnored let cowork: ChatState
    @ObservationIgnored let storage: Storage
    @ObservationIgnored let secrets: SecretStore
    @ObservationIgnored let workspace: URL
    @ObservationIgnored private var connection: SSHConnection?
    @ObservationIgnored private var connectionHostID: UUID?
    /// Whether `pickedFolder` holds a security scope that has to be given back.
    @ObservationIgnored private var folderIsScoped = false

    init() {
        let files = FileManager.default
        let arguments = ProcessInfo.processInfo.arguments
        let isDemo = arguments.contains("-demo")
        let support: URL
        if isDemo {
            // Screenshot mode: sample content, nothing read from or written to real storage.
            let scratch = files.temporaryDirectory.appendingPathComponent("termai-demo-\(UUID().uuidString)")
            support = scratch.appendingPathComponent("support")
            workspace = scratch.appendingPathComponent("workspace")
            secrets = InMemorySecretStore()
        } else {
            support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TermAI")
            workspace = files.urls(for: .documentDirectory, in: .userDomainMask)[0]
            secrets = KeychainStore()
        }
        try? files.createDirectory(at: support, withIntermediateDirectories: true)
        try? files.createDirectory(at: workspace, withIntermediateDirectories: true)
        storage = Storage(directory: support)
        terminal = ChatState(kind: .terminal)
        cowork = ChatState(kind: .cowork)
        profiles = storage.loadProfiles()
        hosts = storage.loadHosts()
        settings = storage.loadSettings()

        if isDemo {
            loadDemo(arguments)
        } else {
            restoreFolder()
            terminal.info(profiles.isEmpty
                ? "TermAI\nno API profile yet. type /setup to add one, or /config for the settings screen."
                : "TermAI · /help for commands")
        }
    }

    // MARK: Derived state

    var theme: Theme { Theme.named(settings.themeID) }
    var palette: Palette { Palette(theme: theme, fontSize: settings.fontSize) }
    var mode: SessionKind { settings.mode }

    /// The chat on screen: the one input and commands go to.
    var chat: ChatState { settings.mode == .cowork ? cowork : terminal }

    var activeProfile: Profile? {
        profiles.first { $0.id == settings.activeProfileID } ?? profiles.first
    }

    var activeModel: String? {
        if let model = settings.activeModel, !model.isEmpty { return model }
        return activeProfile?.preferredModel
    }

    var activeHost: SSHHost? {
        hosts.first { $0.id == settings.activeHostID }
    }

    func suggestions(in chat: ChatState) -> [SlashCommand] {
        setup == nil && chat.pendingApproval == nil ? Commands.suggestions(for: chat.input) : []
    }

    var inputIsSecret: Bool { setup?.isSecret ?? false }

    func placeholder(in chat: ChatState) -> String {
        if let setup { return setup.placeholder }
        if chat.kind == .cowork {
            if chat.pendingApproval != nil { return "allow or deny the step above" }
            return chat.isRunning ? "working…" : "describe a task for this folder"
        }
        if chat.pendingApproval != nil { return "y / n / a" }
        return chat.isRunning ? "running… ^C to stop" : "message, /command or !shell"
    }

    func update(_ change: (inout AppSettings) -> Void) {
        change(&settings)
        storage.saveSettings(settings)
    }

    func info(_ text: String) { chat.info(text) }
    func fail(_ text: String) { chat.fail(text) }

    private func busyNote(_ chat: ChatState) -> String {
        chat.kind == .cowork ? "busy. stop the current task first" : "busy. ^C stops the current run"
    }

    // MARK: Chats

    func switchMode(_ kind: SessionKind) {
        guard kind != settings.mode else { return }
        // The wizard's questions belong to the chat it was started in.
        if setup != nil {
            setup = nil
            chat.info("setup cancelled")
        }
        update { $0.mode = kind }
        chat.scrollTick += 1
    }

    /// Where a chat's file tools work: the picked folder for Cowork, the app's own folder otherwise.
    func folder(for kind: SessionKind) -> URL {
        kind == .cowork ? (pickedFolder ?? workspace) : workspace
    }

    /// The app's own folder is listed in Files under the app's name.
    var coworkFolderName: String { pickedFolder?.lastPathComponent ?? "TermAI" }

    // MARK: Input

    func submit() {
        let chat = self.chat
        let raw = chat.input
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        chat.input = ""
        chat.historyIndex = nil
        chat.scrollTick += 1

        if let step = setup {
            advanceSetup(step, trimmed)
            return
        }
        if chat.pendingApproval != nil {
            switch trimmed.lowercased() {
            case "y", "yes": resolveApproval(.allow, in: chat)
            case "a", "always": allowAlways(in: chat)
            case "n", "no": resolveApproval(.deny, in: chat)
            default: break
            }
            return
        }

        let parsed = Commands.parse(raw)
        if parsed != .empty, chat.promptHistory.last != trimmed { chat.promptHistory.append(trimmed) }
        switch parsed {
        case .empty: break
        case .prompt(let text): send(text)
        case .shell(let command): runShell(command)
        case .command(let name, let args):
            chat.append(.user, trimmed)
            runCommand(name, args)
        }
    }

    func historyUp() {
        let chat = self.chat
        guard !chat.promptHistory.isEmpty else { return }
        let index = max((chat.historyIndex ?? chat.promptHistory.count) - 1, 0)
        chat.historyIndex = index
        chat.input = chat.promptHistory[index]
    }

    func historyDown() {
        let chat = self.chat
        guard let current = chat.historyIndex else { return }
        if current + 1 < chat.promptHistory.count {
            chat.historyIndex = current + 1
            chat.input = chat.promptHistory[current + 1]
        } else {
            chat.historyIndex = nil
            chat.input = ""
        }
    }

    func completeSuggestion() {
        let chat = self.chat
        if let first = suggestions(in: chat).first { chat.input = "/\(first.name) " }
    }

    func escape() {
        if setup != nil {
            setup = nil
            chat.info("setup cancelled")
        }
        chat.input = ""
        chat.historyIndex = nil
    }

    // MARK: Agent runs

    private func send(_ text: String) {
        let chat = self.chat
        guard !chat.isRunning else { return chat.info(busyNote(chat)) }
        guard let profile = activeProfile else { return chat.fail("no API profile. run /setup") }
        guard let model = activeModel else { return chat.fail("no model selected. use /model <id>") }
        chat.append(.user, text)
        if chat.session.isEmpty { chat.session.title = String(text.prefix(48)) }
        chat.session.messages.append(ChatMessage(role: .user, content: text))
        startRun(chat, profile: profile, model: model)
    }

    private func systemPrompt(for chat: ChatState, hostLabel: String?) -> String {
        chat.kind == .cowork
            ? SystemPrompt.cowork(custom: settings.systemPrompt, folder: coworkFolderName)
            : SystemPrompt.build(custom: settings.systemPrompt, hostLabel: hostLabel)
    }

    private func startRun(_ chat: ChatState, profile: Profile, model: String) {
        chat.isRunning = true
        chat.usageLine = nil
        chat.runStart = Date()
        chat.assistantItemID = nil
        let apiKey = secrets.secret(for: profile.secretKey) ?? ""
        if profile.baseURL.lowercased().hasPrefix("http://"), !apiKey.isEmpty {
            chat.info("note: \(profile.name) uses plain http, so the API key is sent unencrypted")
        }
        // Only the terminal drives SSH; Cowork stays inside its folder.
        let host = chat.kind == .terminal ? activeHost : nil
        let endpoint = ChatRequest(baseURL: profile.baseURL, apiKey: apiKey, model: model, messages: [])

        chat.runTask = Task { [weak self] in
            guard let self else { return }
            do {
                var shell: SSHConnection?
                if let host {
                    do {
                        shell = try await self.connect(to: host, for: chat)
                    } catch {
                        chat.fail("ssh \(host.name): \(error.localizedDescription)")
                        chat.info("continuing without SSH")
                    }
                }
                try Task.checkCancellation()
                // A history that has outgrown its budget is summarised first; the prompt just typed stays as it is.
                if self.settings.autoCompact, self.usage(of: chat).isOverBudget {
                    do {
                        try await self.compress(chat, endpoint: endpoint, keep: 1, focus: "")
                    } catch {
                        try Task.checkCancellation()
                        chat.info("could not compress the context (\(error.localizedDescription)). sending it as it is")
                    }
                }
                let prompt = self.systemPrompt(for: chat, hostLabel: shell == nil ? nil : host?.address)
                var request = endpoint
                request.messages = [ChatMessage(role: .system, content: SystemPrompt.withSummary(prompt, summary: chat.session.summary))]
                    + chat.session.messages
                var agent = Agent(client: OpenAIClient(), tools: ToolBox(workspace: self.folder(for: chat.kind), shell: shell))
                if self.settings.autoCompact {
                    agent.trimAbove = Int(Double(self.settings.contextLimit) * Compaction.threshold)
                }
                try await agent.run(
                    request: request,
                    approve: { [weak self] _, summary in await self?.requestApproval(summary, in: chat) ?? .deny },
                    emit: { [weak self] event in await self?.handle(event, in: chat) })
            } catch {
                self.report(error, in: chat)
            }
            self.finishRun(chat)
        }
    }

    private func report(_ error: Error, in chat: ChatState) {
        if error is CancellationError || Task.isCancelled {
            chat.info(chat.kind == .cowork ? "stopped" : "^C")
        } else {
            chat.fail(error.localizedDescription)
            if (error as? APIError)?.isContextOverflow == true {
                chat.info("the conversation no longer fits the model. /compact shrinks it, and /context <n> sets a lower limit so that happens sooner")
            }
        }
    }

    private func finishRun(_ chat: ChatState) {
        for index in chat.session.transcript.indices where chat.session.transcript[index].status == .running {
            chat.session.transcript[index].status = .failed
        }
        chat.isRunning = false
        chat.runTask = nil
        chat.assistantItemID = nil
        chat.toolItems = [:]
        chat.session.updatedAt = Date()
        storage.saveSession(chat.session)
    }

    private func handle(_ event: AgentEvent, in chat: ChatState) {
        switch event {
        case .assistantDelta(let delta):
            if chat.assistantItemID == nil { chat.assistantItemID = chat.append(.assistant, "") }
            chat.mutateItem(chat.assistantItemID) { $0.text += delta }
        case .message(let message):
            chat.session.messages.append(message)
            if message.role == .assistant { chat.assistantItemID = nil }
        case .toolStarted(let call, let summary):
            chat.toolItems[call.id] = chat.append(.tool, "", title: summary, status: .running)
        case .toolOutput(let id, let chunk):
            chat.appendOutput(chat.toolItems[id], chunk)
        case .toolFinished(let id, let result, let denied):
            chat.mutateItem(chat.toolItems[id]) { item in
                item.status = denied ? .denied : (result.isError ? .failed : .ok)
                if denied {
                    item.text = "declined"
                } else if item.text.isEmpty {
                    item.text = String(result.text.prefix(2_000))
                } else if result.isError, let last = result.text.split(separator: "\n").last {
                    if !item.text.hasSuffix("\n") { item.text += "\n" }
                    item.text += last
                }
            }
        case .usage(let input, let output):
            let seconds = Int(Date().timeIntervalSince(chat.runStart).rounded())
            chat.reportedInput = input
            chat.usageLine = "\(Tokens.format(input)) in · \(Tokens.format(output)) out · \(seconds)s"
        case .trimmed(let messages, let saved):
            chat.session.messages = messages
            chat.info("trimmed old tool output · about \(Tokens.format(saved)) tokens saved")
        }
    }

    func cancel() {
        let chat = self.chat
        guard chat.isRunning else { return }
        chat.runTask?.cancel()
        if chat.pendingApproval != nil { resolveApproval(.deny, in: chat) }
    }

    // MARK: Approval

    private func requestApproval(_ summary: String, in chat: ChatState) async -> ApprovalDecision {
        if settings.approvalMode == .auto || chat.alwaysAllow { return .allow }
        if Task.isCancelled { return .deny }
        chat.pendingApproval = PendingApproval(summary: summary)
        chat.scrollTick += 1
        return await withCheckedContinuation { chat.approvalContinuation = $0 }
    }

    func resolveApproval(_ decision: ApprovalDecision, in chat: ChatState) {
        chat.pendingApproval = nil
        chat.approvalContinuation?.resume(returning: decision)
        chat.approvalContinuation = nil
    }

    func allowAlways(in chat: ChatState) {
        chat.alwaysAllow = true
        chat.info("auto-approving tool calls for the rest of this session")
        resolveApproval(.allow, in: chat)
    }

    // MARK: Context

    /// What the next request in `chat` would weigh.
    func usage(of chat: ChatState) -> ContextUsage {
        let host = chat.kind == .terminal ? activeHost : nil
        return ContextUsage(
            system: systemPrompt(for: chat, hostLabel: host?.address),
            tools: ToolBox.specs(shell: host != nil),
            summary: chat.session.summary,
            messages: chat.session.messages,
            limit: settings.contextLimit)
    }

    var contextUsage: ContextUsage { usage(of: chat) }

    var canCompact: Bool {
        !chat.isRunning && !chat.session.messages.isEmpty && activeProfile != nil && activeModel != nil
    }

    /// The Context sheet's button.
    func compactNow() {
        guard canCompact else { return }
        compactCommand("")
    }

    /// Replaces everything except the newest `keep` messages with a summary written by the model.
    private func compress(_ chat: ChatState, endpoint: ChatRequest, keep: Int, focus: String) async throws {
        let cut = max(chat.session.messages.count - keep, 0)
        let old = Array(chat.session.messages.prefix(cut))
        guard !old.isEmpty else { return }
        let before = usage(of: chat).total
        chat.info("compressing the context…")
        chat.scrollTick += 1
        let summary = try await Compaction.summarize(
            client: OpenAIClient(), endpoint: endpoint, summary: chat.session.summary, messages: old,
            focus: focus, limit: settings.contextLimit)
        try Task.checkCancellation()
        chat.session.summary = summary
        chat.session.messages.removeFirst(min(cut, chat.session.messages.count))
        chat.reportedInput = nil
        chat.info("context compressed · \(Tokens.format(before)) → \(Tokens.format(usage(of: chat).total)) tokens")
    }

    private func compactCommand(_ args: String) {
        let chat = self.chat
        guard let profile = activeProfile, let model = activeModel else { return chat.fail("no profile or model selected") }
        guard !chat.session.messages.isEmpty else { return chat.info("nothing to compress yet") }
        let endpoint = ChatRequest(baseURL: profile.baseURL, apiKey: secrets.secret(for: profile.secretKey) ?? "",
                                   model: model, messages: [])
        chat.isRunning = true
        chat.usageLine = nil
        chat.runTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.compress(chat, endpoint: endpoint, keep: 0, focus: args)
            } catch {
                self.report(error, in: chat)
            }
            self.finishRun(chat)
        }
    }

    private func contextCommand(_ args: String) {
        let value = args.lowercased()
        if value == "auto" || value == "off" {
            update { $0.autoCompact = value == "auto" }
        } else if let limit = Tokens.parse(value) {
            // The system prompt and tool definitions alone come to several hundred tokens.
            guard limit >= 4_000 else { return fail("the limit is counted in tokens and starts at 4k, e.g. /context 32k") }
            update { $0.contextLimit = limit }
        } else if !value.isEmpty {
            return fail("usage: /context [n|auto|off], e.g. /context 32k")
        }
        info(contextUsage.report(reported: chat.reportedInput, autoCompact: settings.autoCompact))
    }

    // MARK: Cowork folder

    /// The Files browser returned a folder.
    func folderPicked(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            releaseFolder()
            // The scope has to be open before a bookmark can be made, and stays open while the folder is in use.
            folderIsScoped = url.startAccessingSecurityScopedResource()
            pickedFolder = url
            update { $0.coworkFolder = try? url.bookmarkData() }
            noteFolder()
        case .failure(let error):
            cowork.fail("folder: \(error.localizedDescription)")
        }
    }

    /// Back to the app's own folder.
    func clearFolder() {
        releaseFolder()
        update { $0.coworkFolder = nil }
        noteFolder()
    }

    private func noteFolder() {
        // A Cowork chat that has not started yet shows the folder on its opening screen instead.
        if !cowork.session.transcript.isEmpty {
            cowork.info("folder: \(coworkFolderName)")
            cowork.scrollTick += 1
        }
        // /folder also works from the terminal, which has nowhere else to show the answer.
        if chat.kind == .terminal { chat.info("cowork folder: \(coworkFolderName)") }
    }

    private func releaseFolder() {
        if folderIsScoped { pickedFolder?.stopAccessingSecurityScopedResource() }
        folderIsScoped = false
        pickedFolder = nil
    }

    /// Reopens the folder picked in an earlier launch.
    private func restoreFolder() {
        guard let bookmark = settings.coworkFolder else { return }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale) else {
            // The folder was deleted or its provider is gone; fall back to the app's own folder.
            update { $0.coworkFolder = nil }
            return
        }
        folderIsScoped = url.startAccessingSecurityScopedResource()
        pickedFolder = url
        if isStale, let fresh = try? url.bookmarkData() {
            update { $0.coworkFolder = fresh }
        }
    }

    // MARK: SSH

    private func connect(to host: SSHHost, for chat: ChatState) async throws -> SSHConnection {
        if let connection, connectionHostID == host.id, connection.isConnected { return connection }
        await dropConnection()
        guard let secret = secrets.secret(for: host.secretKey), !secret.isEmpty else {
            throw Failure(message: "no password or key stored for this host; open /config")
        }
        let credentials = SSHCredentials(
            host: host.host, port: host.port, username: host.username,
            secret: host.auth == .password
                ? .password(secret)
                : .privateKey(pem: secret, passphrase: secrets.secret(for: host.passphraseKey)))
        chat.info("connecting to \(host.address)…")
        let new = try await SSHConnection.connect(credentials, label: host.name, trustedHostKey: host.trustedHostKey)
        if host.trustedHostKey == nil, !new.hostKey.isEmpty, let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index].trustedHostKey = new.hostKey
            storage.saveHosts(hosts)
            chat.info("first connection: trusting host key \(SSHKeys.fingerprint(ofOpenSSHKey: new.hostKey))")
        }
        connection = new
        connectionHostID = host.id
        return new
    }

    private func dropConnection() async {
        let old = connection
        connection = nil
        connectionHostID = nil
        await old?.close()
    }

    /// `!command`: run directly on the active host and tell the model what happened.
    private func runShell(_ command: String) {
        let chat = self.chat
        guard chat.kind == .terminal else {
            return chat.fail("!commands run on an SSH host, from the terminal chat. /terminal switches to it")
        }
        guard !chat.isRunning else { return chat.info(busyNote(chat)) }
        guard let host = activeHost else {
            return chat.fail("no SSH host selected. add one in /config, then pick it with /host <name>")
        }
        chat.isRunning = true
        chat.runTask = Task { [weak self] in
            guard let self else { return }
            var itemID: UUID?
            do {
                let shell = try await self.connect(to: host, for: chat)
                let id = chat.append(.tool, "", title: "ssh \(host.name) $ \(command)", status: .running)
                itemID = id
                let (output, continuation) = AsyncStream<String>.makeStream()
                let forwarder = Task {
                    for await chunk in output { chat.appendOutput(id, chunk) }
                }
                let code: Int
                do {
                    code = try await shell.run(command: command, timeout: 300) { continuation.yield($0) }
                } catch {
                    continuation.finish()
                    await forwarder.value
                    throw error
                }
                continuation.finish()
                await forwarder.value
                chat.mutateItem(id) { $0.status = code == 0 ? .ok : .failed }
                if code != 0 { chat.appendOutput(id, "[exit \(code)]") }
                let text = chat.session.transcript.first { $0.id == id }?.text ?? ""
                chat.session.messages.append(ChatMessage(
                    role: .user,
                    content: "[I ran this on \(host.address) myself]\n$ \(command)\n\(Truncate.middle(text, limit: 4_000))\n[exit \(code)]"))
            } catch {
                chat.mutateItem(itemID) { $0.status = .failed }
                if error is CancellationError || Task.isCancelled {
                    chat.info("^C")
                } else {
                    chat.fail("ssh \(host.name): \(error.localizedDescription)")
                }
            }
            self.finishRun(chat)
        }
    }

    // MARK: Commands

    private func runCommand(_ name: String, _ args: String) {
        let chat = self.chat
        let changesSession = ["new", "sessions", "retry", "clear", "setup", "compact"].contains(name)
        if chat.isRunning, changesSession, !(name == "sessions" && args.isEmpty) {
            return chat.info(busyNote(chat))
        }
        switch name {
        case "help":
            let width = Commands.all.map(\.usage.count).max() ?? 0
            let lines = Commands.all.map { $0.usage.padding(toLength: width + 2, withPad: " ", startingAt: 0) + $0.help }
            chat.info(lines.joined(separator: "\n") + "\n\n!<command>  run a command on the SSH host yourself\n^C          stop the current run")
        case "setup":
            setup = .name
            chat.info("new API profile. esc cancels.\nprofile name (e.g. openrouter):")
        case "config":
            sheet = .settings
        case "model": modelCommand(args)
        case "profile": profileCommand(args)
        case "host": hostCommand(args)
        case "approve":
            if let mode = ApprovalMode(rawValue: args.lowercased()) {
                update { $0.approvalMode = mode }
                if mode == .ask {
                    terminal.alwaysAllow = false
                    cowork.alwaysAllow = false
                }
            } else if !args.isEmpty {
                return chat.fail("usage: /approve ask|auto")
            }
            chat.info(settings.approvalMode == .ask
                ? "approval: ask before commands, file changes and web requests"
                : "approval: auto. tool calls run without asking")
        case "theme":
            if args.isEmpty {
                chat.info(Theme.all.map { ($0.id == theme.id ? "* " : "  ") + $0.id.padding(toLength: 11, withPad: " ", startingAt: 0) + $0.name }
                    .joined(separator: "\n"))
            } else if let match = Theme.all.first(where: { $0.id == args.lowercased() || $0.name.lowercased().hasPrefix(args.lowercased()) }) {
                update { $0.themeID = match.id }
                chat.info("theme: \(match.name)")
            } else {
                chat.fail("unknown theme. options: " + Theme.all.map(\.id).joined(separator: ", "))
            }
        case "system":
            if args.isEmpty {
                chat.info(settings.systemPrompt.isEmpty ? "no custom system prompt. /system <text> sets one" : settings.systemPrompt)
            } else {
                update { $0.systemPrompt = args.lowercased() == "reset" ? "" : args }
                chat.info(settings.systemPrompt.isEmpty ? "system prompt reset" : "system prompt set")
            }
        case "cowork":
            switchMode(.cowork)
        case "terminal":
            switchMode(.terminal)
        case "folder":
            if args.isEmpty {
                showFolderPicker = true
            } else if args.lowercased() == "reset" {
                clearFolder()
            } else {
                chat.fail("usage: /folder [reset]. the folder is picked in Files, not typed")
            }
        case "context": contextCommand(args)
        case "compact": compactCommand(args)
        case "new":
            startNewSession()
        case "sessions": sessionsCommand(args)
        case "retry":
            guard let index = chat.session.messages.lastIndex(where: { $0.role == .user }) else { return chat.fail("nothing to retry") }
            guard let profile = activeProfile, let model = activeModel else { return chat.fail("no profile or model selected") }
            chat.session.messages.removeSubrange((index + 1)...)
            startRun(chat, profile: profile, model: model)
        case "copy":
            guard let last = chat.session.transcript.last(where: { $0.kind == .assistant }) else { return chat.fail("no answer to copy") }
            UIPasteboard.general.string = last.text
            chat.info("copied \(last.text.count) characters")
        case "export":
            guard !chat.session.isEmpty else { return chat.fail("nothing to export yet") }
            sheet = .share(Markdown.export(chat.session))
        case "clear":
            chat.session.transcript.removeAll()
        default:
            chat.fail("unknown command: /\(name)")
        }
    }

    private func startNewSession() {
        let chat = self.chat
        storage.saveSession(chat.session)
        chat.show(Session(kind: chat.kind))
        // Cowork opens on its start screen; the terminal just says so.
        if chat.kind == .terminal { chat.info("new session") }
    }

    private func modelCommand(_ args: String) {
        guard let profile = activeProfile else { return fail("no API profile. run /setup") }
        if args.isEmpty {
            let current = activeModel
            let lines = profile.models.map { ($0 == current ? "* " : "  ") + $0 }
            info(lines.isEmpty ? "no models saved for \(profile.name). /model <id> adds one" : lines.joined(separator: "\n"))
            return
        }
        // Accept an exact ID, a unique substring of a saved ID, or a brand-new ID.
        let matches = profile.models.filter { $0.localizedCaseInsensitiveContains(args) }
        let chosen = profile.models.first { $0 == args } ?? (matches.count == 1 ? matches[0] : args)
        select(model: chosen, in: profile.id)
        info("model: \(chosen)")
    }

    func select(model: String, in profileID: UUID) {
        if let index = profiles.firstIndex(where: { $0.id == profileID }), !profiles[index].models.contains(model) {
            profiles[index].models.append(model)
            storage.saveProfiles(profiles)
        }
        update {
            $0.activeProfileID = profileID
            $0.activeModel = model
        }
    }

    private func profileCommand(_ args: String) {
        if args.isEmpty {
            let current = activeProfile?.id
            let lines = profiles.map { ($0.id == current ? "* " : "  ") + $0.name + "  " + $0.baseURL }
            return info(lines.isEmpty ? "no profiles. run /setup" : lines.joined(separator: "\n"))
        }
        guard let match = profiles.first(where: { $0.name.lowercased().hasPrefix(args.lowercased()) }) else {
            return fail("no profile named \(args)")
        }
        update {
            $0.activeProfileID = match.id
            $0.activeModel = match.preferredModel
        }
        info("profile: \(match.name) · \(match.preferredModel ?? "no model")")
    }

    private func hostCommand(_ args: String) {
        if args.isEmpty {
            let current = activeHost?.id
            let lines = hosts.map { ($0.id == current ? "* " : "  ") + $0.name + "  " + $0.address }
            return info(lines.isEmpty ? "no SSH hosts. add one in /config" : lines.joined(separator: "\n") + (current == nil ? "\n(none selected)" : ""))
        }
        if ["off", "none"].contains(args.lowercased()) {
            selectHost(nil)
            return info("ssh: off")
        }
        guard let match = hosts.first(where: { $0.name.lowercased().hasPrefix(args.lowercased()) }) else {
            return fail("no host named \(args)")
        }
        selectHost(match.id)
        info("ssh: \(match.name) (\(match.address)). connects on first use")
    }

    func selectHost(_ id: UUID?) {
        update { $0.activeHostID = id }
        if connectionHostID != id { Task { await dropConnection() } }
    }

    private func sessionsCommand(_ args: String) {
        let chat = self.chat
        if args.isEmpty {
            // Each chat lists and resumes its own sessions.
            chat.listedSessions = Array(storage.sessionSummaries(kind: chat.kind).prefix(20))
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d HH:mm"
            let lines = chat.listedSessions.enumerated().map { index, summary in
                "\(index + 1)".padding(toLength: 4, withPad: " ", startingAt: 0) + formatter.string(from: summary.updatedAt) + "  " + summary.title
            }
            return chat.info(lines.isEmpty ? "no saved sessions" : lines.joined(separator: "\n") + "\n\n/sessions <n> resumes one")
        }
        guard let number = Int(args), chat.listedSessions.indices.contains(number - 1),
              let loaded = storage.loadSession(id: chat.listedSessions[number - 1].id) else {
            return chat.fail("run /sessions first, then /sessions <n>")
        }
        storage.saveSession(chat.session)
        chat.show(loaded)
        chat.info("resumed: \(loaded.title)")
    }

    // MARK: Setup wizard

    private func advanceSetup(_ step: SetupStep, _ value: String) {
        switch step {
        case .name:
            guard !value.isEmpty else { return info("profile name:") }
            chat.append(.user, value)
            setup = .baseURL(name: value)
            info("base URL (e.g. https://api.openai.com/v1):")
        case .baseURL(let name):
            guard let url = URL(string: value), url.scheme?.hasPrefix("http") == true, url.host != nil else {
                return info("that is not an http(s) URL. base URL:")
            }
            chat.append(.user, value)
            setup = .apiKey(name: name, baseURL: value)
            info("API key (hidden, stored in the Keychain; empty for none):")
        case .apiKey(let name, let baseURL):
            chat.append(.user, value.isEmpty ? "(none)" : String(repeating: "•", count: min(value.count, 16)))
            info("fetching models…")
            Task { [weak self] in
                var models: [String] = []
                var problem: String?
                do {
                    models = try await OpenAIClient().listModels(baseURL: baseURL, apiKey: value)
                } catch {
                    problem = error.localizedDescription
                }
                guard let self, case .apiKey? = self.setup else { return }
                self.setup = .model(name: name, baseURL: baseURL, apiKey: value, models: models)
                if let problem {
                    self.fail("could not list models: \(problem)")
                    self.info("type a model ID to use anyway:")
                } else if models.isEmpty {
                    self.info("the endpoint listed no models. model ID:")
                } else {
                    let shown = models.prefix(12).joined(separator: "\n  ")
                    let more = models.count > 12 ? "\n  … \(models.count - 12) more" : ""
                    self.info("\(models.count) models:\n  \(shown)\(more)\ndefault model ID (enter for \(models[0])):")
                }
            }
        case .model(let name, let baseURL, let apiKey, let models):
            let chosen = value.isEmpty ? models.first : (models.first { $0 == value }
                ?? models.first { $0.localizedCaseInsensitiveContains(value) } ?? value)
            guard let chosen else { return info("model ID:") }
            chat.append(.user, chosen)
            var profile = Profile(name: name, baseURL: baseURL, models: models, defaultModel: chosen)
            if !profile.models.contains(chosen) { profile.models.insert(chosen, at: 0) }
            saveProfile(profile, apiKey: apiKey)
            update {
                $0.activeProfileID = profile.id
                $0.activeModel = chosen
            }
            setup = nil
            info("saved. \(name) · \(chosen) is active. say something.")
        }
    }

    // MARK: Settings screen support

    func apiKey(for profile: Profile) -> String { secrets.secret(for: profile.secretKey) ?? "" }

    func saveProfile(_ profile: Profile, apiKey: String) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        storage.saveProfiles(profiles)
        secrets.setSecret(apiKey, for: profile.secretKey)
        if settings.activeProfileID == nil || profiles.count == 1 {
            update {
                $0.activeProfileID = profile.id
                $0.activeModel = profile.preferredModel
            }
        } else if settings.activeProfileID == profile.id, let model = settings.activeModel, !profile.models.contains(model) {
            update { $0.activeModel = profile.preferredModel }
        }
    }

    func deleteProfile(_ profile: Profile) {
        profiles.removeAll { $0.id == profile.id }
        storage.saveProfiles(profiles)
        secrets.setSecret(nil, for: profile.secretKey)
        if settings.activeProfileID == profile.id {
            update {
                $0.activeProfileID = profiles.first?.id
                $0.activeModel = profiles.first?.preferredModel
            }
        }
    }

    func hostSecret(for host: SSHHost) -> String { secrets.secret(for: host.secretKey) ?? "" }
    func hostPassphrase(for host: SSHHost) -> String { secrets.secret(for: host.passphraseKey) ?? "" }

    func saveHost(_ host: SSHHost, secret: String, passphrase: String) {
        let isFirst = hosts.isEmpty
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        storage.saveHosts(hosts)
        secrets.setSecret(secret, for: host.secretKey)
        secrets.setSecret(passphrase, for: host.passphraseKey)
        if isFirst { update { $0.activeHostID = host.id } }
        // Reconnect with the new details on next use.
        if connectionHostID == host.id { Task { await dropConnection() } }
    }

    func deleteHost(_ host: SSHHost) {
        hosts.removeAll { $0.id == host.id }
        storage.saveHosts(hosts)
        secrets.setSecret(nil, for: host.secretKey)
        secrets.setSecret(nil, for: host.passphraseKey)
        if settings.activeHostID == host.id { selectHost(nil) }
    }

    // MARK: Demo content

    private func loadDemo(_ arguments: [String]) {
        let profile = Profile(name: "openrouter", baseURL: "https://openrouter.ai/api/v1",
                              models: ["anthropic/claude-sonnet-5", "openai/gpt-6-luna"], defaultModel: "anthropic/claude-sonnet-5")
        let host = SSHHost(name: "web1", host: "10.0.0.12", username: "deploy")
        profiles = [profile]
        hosts = [host]
        let opensCowork = arguments.contains("-demoCowork") || arguments.contains("-demoCoworkTask")
        settings = AppSettings(activeProfileID: profile.id, activeModel: profile.defaultModel, activeHostID: host.id,
                               themeID: UserDefaults.standard.string(forKey: "theme") ?? Theme.minimalDark.id,
                               mode: opensCowork ? .cowork : .terminal)
        loadTerminalDemo(withApproval: arguments.contains("-demoApproval"))

        // A folder of its own, so the header names it the way it names a picked folder.
        let folder = workspace.appendingPathComponent("Trip to Lisbon")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        pickedFolder = folder
        if arguments.contains("-demoCoworkTask") { loadCoworkDemo() }
        if arguments.contains("-demoContextReport") {
            terminal.append(.user, "/context")
            terminal.info(usage(of: terminal).report(reported: terminal.reportedInput, autoCompact: settings.autoCompact))
        }

        if arguments.contains("-demoSettings") { sheet = .settings }
        if arguments.contains("-demoContext") { sheet = .context }
        showFolderPicker = arguments.contains("-demoFolderPicker")
    }

    private func loadTerminalDemo(withApproval: Bool) {
        let chat = terminal
        let fix = "ssh web1 $ sudo sed -i 's/servr_name/server_name/' /etc/nginx/sites-enabled/app && sudo nginx -t && sudo systemctl reload nginx"
        // A history with some weight, so the context meter has something to show.
        let journal = String(repeating: "Nov 10 09:14:02 web1 nginx[812]: [emerg] unknown directive \"servr_name\" in /etc/nginx/sites-enabled/app:4\n", count: 520)
        chat.session = Session(title: "demo", messages: [
            ChatMessage(role: .user, content: "why is nginx down on web1?"),
            ChatMessage(role: .assistant, content: "Checking the service state first.",
                        toolCalls: [ToolCall(id: "demo1", name: "ssh_exec", arguments: "{\"command\":\"journalctl -u nginx --no-pager\"}")]),
            ChatMessage(role: .tool, content: journal, toolCallID: "demo1"),
            ChatMessage(role: .assistant, content: "There is a typo in the site config, line 4. It should be server_name. I can fix it and reload."),
        ])
        chat.append(.info, "TermAI · /help for commands")
        chat.append(.user, "why is nginx down on web1?")
        chat.append(.assistant, "Checking the service state first.")
        chat.append(.tool, "× nginx.service - A high performance web server\n     Active: failed (Result: exit-code)\nnginx: [emerg] unknown directive \"servr_name\"\n  in /etc/nginx/sites-enabled/app:4\n[exit 3]",
                    title: "ssh web1 $ systemctl status nginx --no-pager", status: .failed)
        chat.append(.assistant, "There is a typo in the site config, line 4:\n\n```nginx\nservr_name example.com;\n```\n\nIt should be `server_name`. I can fix it and reload:")
        if withApproval {
            chat.append(.tool, "", title: fix, status: .running)
            chat.isRunning = true
            chat.pendingApproval = PendingApproval(summary: fix)
        } else {
            chat.append(.tool, "nginx: configuration file /etc/nginx/nginx.conf test is successful", title: fix, status: .ok)
            chat.append(.assistant, "Fixed. nginx is serving again.")
            chat.usageLine = "2.4k in · 312 out · 9s"
            chat.reportedInput = 14_900
        }
    }

    private func loadCoworkDemo() {
        let chat = cowork
        chat.session = Session(kind: .cowork, title: "demo", messages: [ChatMessage(role: .user, content: "demo")])
        chat.append(.user, "Tidy this folder up and write a short index of what is in it.")
        chat.append(.assistant, "I'll look at what is here first.")
        chat.append(.tool, "Budget.xlsx  18220\nIMG_2291.jpg  2203114\nIMG_2292.jpg  1987330\nflights.pdf  241877\nideas.md  1204\nnotes.txt  612",
                    title: "ls .", status: .ok)
        chat.append(.assistant, "Six files: two photos, two documents and two notes. I'll put the photos in their own folder and add an index.")
        chat.append(.tool, "moved IMG_2291.jpg → Photos/IMG_2291.jpg", title: "move IMG_2291.jpg → Photos/IMG_2291.jpg", status: .ok)
        chat.append(.tool, "moved IMG_2292.jpg → Photos/IMG_2292.jpg", title: "move IMG_2292.jpg → Photos/IMG_2292.jpg", status: .ok)
        chat.append(.tool, "wrote 412 bytes", title: "write INDEX.md (412 bytes)", status: .ok)
        chat.append(.assistant, "Done. **Photos/** holds the two pictures, and `INDEX.md` lists every file with a line about what it is.")
        chat.usageLine = "3.1k in · 420 out · 14s"
    }
}
