import Foundation
import Observation
import SwiftUI
import TermCore
import TermSSH
import UIKit

struct PendingApproval: Identifiable, Equatable {
    let id = UUID()
    let summary: String
}

struct ShareItem: Identifiable {
    let id = UUID()
    let text: String
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
    var session = Session()
    var input = ""
    var isRunning = false
    var pendingApproval: PendingApproval?
    var setup: SetupStep?
    var showSettings = false
    var shareItem: ShareItem?
    var usageLine: String?
    /// Bumped when the transcript should jump to the bottom.
    var scrollTick = 0

    @ObservationIgnored let storage: Storage
    @ObservationIgnored let secrets: SecretStore
    @ObservationIgnored let workspace: URL
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var approvalContinuation: CheckedContinuation<ApprovalDecision, Never>?
    @ObservationIgnored private var alwaysAllow = false
    @ObservationIgnored private var connection: SSHConnection?
    @ObservationIgnored private var connectionHostID: UUID?
    @ObservationIgnored private var assistantItemID: UUID?
    @ObservationIgnored private var toolItems: [String: UUID] = [:]
    @ObservationIgnored private var promptHistory: [String] = []
    @ObservationIgnored private var historyIndex: Int?
    @ObservationIgnored private var runStart = Date()
    @ObservationIgnored private var listedSessions: [SessionSummary] = []

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
        profiles = storage.loadProfiles()
        hosts = storage.loadHosts()
        settings = storage.loadSettings()

        if isDemo {
            loadDemo(withApproval: arguments.contains("-demoApproval"))
            showSettings = arguments.contains("-demoSettings")
        } else if profiles.isEmpty {
            info("TermAI\nno API profile yet. type /setup to add one, or /config for the settings screen.")
        } else {
            info("TermAI · /help for commands")
        }
    }

    // MARK: Derived state

    var theme: Theme { Theme.named(settings.themeID) }
    var palette: Palette { Palette(theme: theme, fontSize: settings.fontSize) }

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

    var suggestions: [SlashCommand] {
        setup == nil && pendingApproval == nil ? Commands.suggestions(for: input) : []
    }

    var inputIsSecret: Bool { setup?.isSecret ?? false }

    var placeholder: String {
        if let setup { return setup.placeholder }
        if pendingApproval != nil { return "y / n / a" }
        return isRunning ? "running… ^C to stop" : "message, /command or !shell"
    }

    func update(_ change: (inout AppSettings) -> Void) {
        change(&settings)
        storage.saveSettings(settings)
    }

    // MARK: Transcript

    @discardableResult
    private func append(_ kind: TranscriptItem.Kind, _ text: String, title: String? = nil,
                        status: TranscriptItem.Status? = nil) -> UUID {
        let item = TranscriptItem(kind: kind, text: text, title: title, status: status)
        session.transcript.append(item)
        return item.id
    }

    func info(_ text: String) { append(.info, text) }
    func fail(_ text: String) { append(.error, text) }

    private func mutateItem(_ id: UUID?, _ change: (inout TranscriptItem) -> Void) {
        guard let id, let index = session.transcript.lastIndex(where: { $0.id == id }) else { return }
        change(&session.transcript[index])
    }

    private func appendOutput(_ id: UUID?, _ chunk: String) {
        mutateItem(id) { item in
            item.text += chunk
            // Only the tail is shown; keep the stored text bounded for long-running commands.
            if item.text.count > 24_000 { item.text = String(item.text.suffix(16_000)) }
        }
    }

    // MARK: Input

    func submit() {
        let raw = input
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        input = ""
        historyIndex = nil
        scrollTick += 1

        if let step = setup {
            advanceSetup(step, trimmed)
            return
        }
        if pendingApproval != nil {
            switch trimmed.lowercased() {
            case "y", "yes": resolveApproval(.allow)
            case "a", "always": allowAlways()
            case "n", "no": resolveApproval(.deny)
            default: break
            }
            return
        }

        let parsed = Commands.parse(raw)
        if parsed != .empty, promptHistory.last != trimmed { promptHistory.append(trimmed) }
        switch parsed {
        case .empty: break
        case .prompt(let text): send(text)
        case .shell(let command): runShell(command)
        case .command(let name, let args):
            append(.user, trimmed)
            runCommand(name, args)
        }
    }

    func historyUp() {
        guard !promptHistory.isEmpty else { return }
        let index = max((historyIndex ?? promptHistory.count) - 1, 0)
        historyIndex = index
        input = promptHistory[index]
    }

    func historyDown() {
        guard let current = historyIndex else { return }
        if current + 1 < promptHistory.count {
            historyIndex = current + 1
            input = promptHistory[current + 1]
        } else {
            historyIndex = nil
            input = ""
        }
    }

    func completeSuggestion() {
        if let first = suggestions.first { input = "/\(first.name) " }
    }

    func escape() {
        if setup != nil {
            setup = nil
            info("setup cancelled")
        }
        input = ""
        historyIndex = nil
    }

    // MARK: Agent runs

    private func send(_ text: String) {
        guard !isRunning else { return info("busy. ^C stops the current run") }
        guard let profile = activeProfile else { return fail("no API profile. run /setup") }
        guard let model = activeModel else { return fail("no model selected. use /model <id>") }
        append(.user, text)
        if session.messages.isEmpty { session.title = String(text.prefix(48)) }
        session.messages.append(ChatMessage(role: .user, content: text))
        startRun(profile: profile, model: model)
    }

    private func startRun(profile: Profile, model: String) {
        isRunning = true
        usageLine = nil
        runStart = Date()
        assistantItemID = nil
        let apiKey = secrets.secret(for: profile.secretKey) ?? ""
        if profile.baseURL.lowercased().hasPrefix("http://"), !apiKey.isEmpty {
            info("note: \(profile.name) uses plain http, so the API key is sent unencrypted")
        }
        let history = session.messages
        let host = activeHost

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                var shell: SSHConnection?
                if let host {
                    do {
                        shell = try await self.connect(to: host)
                    } catch {
                        self.fail("ssh \(host.name): \(error.localizedDescription)")
                        self.info("continuing without SSH")
                    }
                }
                try Task.checkCancellation()
                let system = SystemPrompt.build(custom: self.settings.systemPrompt, hostLabel: shell == nil ? nil : host?.address)
                let request = ChatRequest(
                    baseURL: profile.baseURL, apiKey: apiKey, model: model,
                    messages: [ChatMessage(role: .system, content: system)] + history)
                let agent = Agent(client: OpenAIClient(), tools: ToolBox(workspace: self.workspace, shell: shell))
                try await agent.run(
                    request: request,
                    approve: { [weak self] _, summary in await self?.requestApproval(summary) ?? .deny },
                    emit: { [weak self] event in await self?.handle(event) })
            } catch {
                if error is CancellationError || Task.isCancelled {
                    self.info("^C")
                } else {
                    self.fail(error.localizedDescription)
                }
            }
            self.finishRun()
        }
    }

    private func finishRun() {
        for index in session.transcript.indices where session.transcript[index].status == .running {
            session.transcript[index].status = .failed
        }
        isRunning = false
        runTask = nil
        assistantItemID = nil
        toolItems = [:]
        session.updatedAt = Date()
        storage.saveSession(session)
    }

    private func handle(_ event: AgentEvent) {
        switch event {
        case .assistantDelta(let delta):
            if assistantItemID == nil { assistantItemID = append(.assistant, "") }
            mutateItem(assistantItemID) { $0.text += delta }
        case .message(let message):
            session.messages.append(message)
            if message.role == .assistant { assistantItemID = nil }
        case .toolStarted(let call, let summary):
            toolItems[call.id] = append(.tool, "", title: summary, status: .running)
        case .toolOutput(let id, let chunk):
            appendOutput(toolItems[id], chunk)
        case .toolFinished(let id, let result, let denied):
            mutateItem(toolItems[id]) { item in
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
            let seconds = Int(Date().timeIntervalSince(runStart).rounded())
            usageLine = "\(Self.compact(input)) in · \(Self.compact(output)) out · \(seconds)s"
        }
    }

    static func compact(_ count: Int) -> String {
        count >= 1_000 ? String(format: "%.1fk", Double(count) / 1_000) : "\(count)"
    }

    func cancel() {
        guard isRunning else { return }
        runTask?.cancel()
        if pendingApproval != nil { resolveApproval(.deny) }
    }

    // MARK: Approval

    private func requestApproval(_ summary: String) async -> ApprovalDecision {
        if settings.approvalMode == .auto || alwaysAllow { return .allow }
        if Task.isCancelled { return .deny }
        pendingApproval = PendingApproval(summary: summary)
        scrollTick += 1
        return await withCheckedContinuation { approvalContinuation = $0 }
    }

    func resolveApproval(_ decision: ApprovalDecision) {
        pendingApproval = nil
        approvalContinuation?.resume(returning: decision)
        approvalContinuation = nil
    }

    func allowAlways() {
        alwaysAllow = true
        info("auto-approving tool calls for the rest of this session")
        resolveApproval(.allow)
    }

    // MARK: SSH

    private func connect(to host: SSHHost) async throws -> SSHConnection {
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
        info("connecting to \(host.address)…")
        let new = try await SSHConnection.connect(credentials, label: host.name, trustedHostKey: host.trustedHostKey)
        if host.trustedHostKey == nil, !new.hostKey.isEmpty, let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index].trustedHostKey = new.hostKey
            storage.saveHosts(hosts)
            info("first connection: trusting host key \(SSHKeys.fingerprint(ofOpenSSHKey: new.hostKey))")
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
        guard !isRunning else { return info("busy. ^C stops the current run") }
        guard let host = activeHost else {
            return fail("no SSH host selected. add one in /config, then pick it with /host <name>")
        }
        isRunning = true
        runTask = Task { [weak self] in
            guard let self else { return }
            var itemID: UUID?
            do {
                let shell = try await self.connect(to: host)
                let id = self.append(.tool, "", title: "ssh \(host.name) $ \(command)", status: .running)
                itemID = id
                let (output, continuation) = AsyncStream<String>.makeStream()
                let forwarder = Task { [weak self] in
                    for await chunk in output { self?.appendOutput(id, chunk) }
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
                self.mutateItem(id) { $0.status = code == 0 ? .ok : .failed }
                if code != 0 { self.appendOutput(id, "[exit \(code)]") }
                let text = self.session.transcript.first { $0.id == id }?.text ?? ""
                self.session.messages.append(ChatMessage(
                    role: .user,
                    content: "[I ran this on \(host.address) myself]\n$ \(command)\n\(Truncate.middle(text, limit: 4_000))\n[exit \(code)]"))
            } catch {
                self.mutateItem(itemID) { $0.status = .failed }
                if error is CancellationError || Task.isCancelled {
                    self.info("^C")
                } else {
                    self.fail("ssh \(host.name): \(error.localizedDescription)")
                }
            }
            self.finishRun()
        }
    }

    // MARK: Commands

    private func runCommand(_ name: String, _ args: String) {
        let changesSession = ["new", "sessions", "retry", "clear", "setup"].contains(name)
        if isRunning, changesSession, !(name == "sessions" && args.isEmpty) {
            return info("busy. ^C stops the current run")
        }
        switch name {
        case "help":
            let width = Commands.all.map(\.usage.count).max() ?? 0
            let lines = Commands.all.map { $0.usage.padding(toLength: width + 2, withPad: " ", startingAt: 0) + $0.help }
            info(lines.joined(separator: "\n") + "\n\n!<command>  run a command on the SSH host yourself\n^C          stop the current run")
        case "setup":
            setup = .name
            info("new API profile. esc cancels.\nprofile name (e.g. openrouter):")
        case "config":
            showSettings = true
        case "model": modelCommand(args)
        case "profile": profileCommand(args)
        case "host": hostCommand(args)
        case "approve":
            if let mode = ApprovalMode(rawValue: args.lowercased()) {
                update { $0.approvalMode = mode }
                if mode == .ask { alwaysAllow = false }
            } else if !args.isEmpty {
                return fail("usage: /approve ask|auto")
            }
            info(settings.approvalMode == .ask
                 ? "approval: ask before commands, file writes and web requests"
                 : "approval: auto. tool calls run without asking")
        case "theme":
            if args.isEmpty {
                info(Theme.all.map { ($0.id == theme.id ? "* " : "  ") + $0.id.padding(toLength: 11, withPad: " ", startingAt: 0) + $0.name }
                    .joined(separator: "\n"))
            } else if let match = Theme.all.first(where: { $0.id == args.lowercased() || $0.name.lowercased().hasPrefix(args.lowercased()) }) {
                update { $0.themeID = match.id }
                info("theme: \(match.name)")
            } else {
                fail("unknown theme. options: " + Theme.all.map(\.id).joined(separator: ", "))
            }
        case "system":
            if args.isEmpty {
                info(settings.systemPrompt.isEmpty ? "no custom system prompt. /system <text> sets one" : settings.systemPrompt)
            } else {
                update { $0.systemPrompt = args.lowercased() == "reset" ? "" : args }
                info(settings.systemPrompt.isEmpty ? "system prompt reset" : "system prompt set")
            }
        case "new":
            startNewSession()
        case "sessions": sessionsCommand(args)
        case "retry":
            guard let index = session.messages.lastIndex(where: { $0.role == .user }) else { return fail("nothing to retry") }
            guard let profile = activeProfile, let model = activeModel else { return fail("no profile or model selected") }
            session.messages.removeSubrange((index + 1)...)
            startRun(profile: profile, model: model)
        case "copy":
            guard let last = session.transcript.last(where: { $0.kind == .assistant }) else { return fail("no answer to copy") }
            UIPasteboard.general.string = last.text
            info("copied \(last.text.count) characters")
        case "export":
            guard !session.isEmpty else { return fail("nothing to export yet") }
            shareItem = ShareItem(text: Markdown.export(session))
        case "clear":
            session.transcript.removeAll()
        default:
            fail("unknown command: /\(name)")
        }
    }

    private func startNewSession() {
        storage.saveSession(session)
        session = Session()
        alwaysAllow = false
        usageLine = nil
        info("new session")
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
        if args.isEmpty {
            listedSessions = Array(storage.sessionSummaries().prefix(20))
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d HH:mm"
            let lines = listedSessions.enumerated().map { index, summary in
                "\(index + 1)".padding(toLength: 4, withPad: " ", startingAt: 0) + formatter.string(from: summary.updatedAt) + "  " + summary.title
            }
            return info(lines.isEmpty ? "no saved sessions" : lines.joined(separator: "\n") + "\n\n/sessions <n> resumes one")
        }
        guard let number = Int(args), listedSessions.indices.contains(number - 1),
              let loaded = storage.loadSession(id: listedSessions[number - 1].id) else {
            return fail("run /sessions first, then /sessions <n>")
        }
        storage.saveSession(session)
        session = loaded
        alwaysAllow = false
        usageLine = nil
        info("resumed: \(loaded.title)")
    }

    // MARK: Setup wizard

    private func advanceSetup(_ step: SetupStep, _ value: String) {
        switch step {
        case .name:
            guard !value.isEmpty else { return info("profile name:") }
            append(.user, value)
            setup = .baseURL(name: value)
            info("base URL (e.g. https://api.openai.com/v1):")
        case .baseURL(let name):
            guard let url = URL(string: value), url.scheme?.hasPrefix("http") == true, url.host != nil else {
                return info("that is not an http(s) URL. base URL:")
            }
            append(.user, value)
            setup = .apiKey(name: name, baseURL: value)
            info("API key (hidden, stored in the Keychain; empty for none):")
        case .apiKey(let name, let baseURL):
            append(.user, value.isEmpty ? "(none)" : String(repeating: "•", count: min(value.count, 16)))
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
            append(.user, chosen)
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

    private func loadDemo(withApproval: Bool) {
        let profile = Profile(name: "openrouter", baseURL: "https://openrouter.ai/api/v1",
                              models: ["anthropic/claude-sonnet-5", "openai/gpt-6-luna"], defaultModel: "anthropic/claude-sonnet-5")
        let host = SSHHost(name: "web1", host: "10.0.0.12", username: "deploy")
        profiles = [profile]
        hosts = [host]
        settings = AppSettings(activeProfileID: profile.id, activeModel: profile.defaultModel, activeHostID: host.id,
                               themeID: UserDefaults.standard.string(forKey: "theme") ?? Theme.minimalDark.id)
        session = Session(title: "demo", messages: [ChatMessage(role: .user, content: "demo")])
        append(.info, "TermAI · /help for commands")
        append(.user, "why is nginx down on web1?")
        append(.assistant, "Checking the service state first.")
        append(.tool, "× nginx.service - A high performance web server\n     Active: failed (Result: exit-code)\nnginx: [emerg] unknown directive \"servr_name\"\n  in /etc/nginx/sites-enabled/app:4\n[exit 3]",
               title: "ssh web1 $ systemctl status nginx --no-pager", status: .failed)
        append(.assistant, "There is a typo in the site config, line 4:\n\n```nginx\nservr_name example.com;\n```\n\nIt should be `server_name`. I can fix it and reload:")
        if withApproval {
            append(.tool, "", title: "ssh web1 $ sudo sed -i 's/servr_name/server_name/' /etc/nginx/sites-enabled/app && sudo nginx -t && sudo systemctl reload nginx", status: .running)
            isRunning = true
            pendingApproval = PendingApproval(summary: "ssh web1 $ sudo sed -i 's/servr_name/server_name/' /etc/nginx/sites-enabled/app && sudo nginx -t && sudo systemctl reload nginx")
        } else {
            append(.tool, "nginx: configuration file /etc/nginx/nginx.conf test is successful",
                   title: "ssh web1 $ sudo sed -i 's/servr_name/server_name/' /etc/nginx/sites-enabled/app && sudo nginx -t && sudo systemctl reload nginx", status: .ok)
            append(.assistant, "Fixed. nginx is serving again.")
            usageLine = "2.4k in · 312 out · 9s"
        }
    }
}
