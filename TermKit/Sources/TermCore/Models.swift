import Foundation

/// An API endpoint: base URL plus the model IDs available on it. The API key lives in the secret store.
public struct Profile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var baseURL: String
    public var models: [String]
    public var defaultModel: String?

    public init(id: UUID = UUID(), name: String, baseURL: String, models: [String] = [], defaultModel: String? = nil) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.models = models
        self.defaultModel = defaultModel
    }

    public var secretKey: String { "profile.\(id.uuidString).apikey" }
    public var preferredModel: String? { defaultModel ?? models.first }
}

public struct SSHHost: Codable, Identifiable, Equatable, Sendable {
    public enum Auth: String, Codable, Sendable, CaseIterable {
        case password
        case privateKey
    }

    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var auth: Auth
    /// OpenSSH-format host key recorded on first connect; later connects must match it.
    public var trustedHostKey: String?

    public init(id: UUID = UUID(), name: String, host: String, port: Int = 22, username: String,
                auth: Auth = .password, trustedHostKey: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.trustedHostKey = trustedHostKey
    }

    public var secretKey: String { "host.\(id.uuidString).secret" }
    public var passphraseKey: String { "host.\(id.uuidString).passphrase" }
    public var address: String { "\(username)@\(host)" + (port == 22 ? "" : ":\(port)") }
}

public struct ToolCall: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// Raw JSON object string as produced by the model.
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    public var argumentValues: [String: Any] {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    public func string(_ key: String) -> String? { argumentValues[key] as? String }

    public func number(_ key: String) -> Double? {
        let value = argumentValues[key]
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    public func bool(_ key: String) -> Bool? {
        let value = argumentValues[key]
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        // Some models quote their booleans.
        if let string = value as? String { return ["true", "yes", "1"].contains(string.lowercased()) }
        return nil
    }
}

public struct ChatMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant, tool
    }

    public var role: Role
    public var content: String
    public var toolCalls: [ToolCall]?
    public var toolCallID: String?

    public init(role: Role, content: String, toolCalls: [ToolCall]? = nil, toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }
}

/// One block in the on-screen transcript.
public struct TranscriptItem: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case user, assistant, tool, info, error
    }

    public enum Status: String, Codable, Sendable {
        case running, ok, failed, denied
    }

    public var id: UUID
    public var kind: Kind
    public var text: String
    /// Tool blocks only: the one-line description, e.g. `ssh web1 $ uptime`.
    public var title: String?
    public var status: Status?

    public init(id: UUID = UUID(), kind: Kind, text: String, title: String? = nil, status: Status? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.title = title
        self.status = status
    }
}

/// Which of the app's two chats a session belongs to.
public enum SessionKind: String, Codable, Sendable, CaseIterable {
    /// The terminal: SSH hosts and the app's own file workspace.
    case terminal
    /// Cowork: the agent works on the files in a folder the user picked.
    case cowork
}

public struct Session: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: SessionKind
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [ChatMessage]
    public var transcript: [TranscriptItem]
    /// Stands in for the messages that were dropped when the conversation was compacted.
    public var summary: String?

    public init(id: UUID = UUID(), kind: SessionKind = .terminal, title: String = "new session",
                createdAt: Date = Date(), updatedAt: Date = Date(),
                messages: [ChatMessage] = [], transcript: [TranscriptItem] = [], summary: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.transcript = transcript
        self.summary = summary
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        // Sessions saved before Cowork existed carry no kind.
        kind = try values.decodeIfPresent(SessionKind.self, forKey: .kind) ?? .terminal
        title = try values.decode(String.self, forKey: .title)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        messages = try values.decode([ChatMessage].self, forKey: .messages)
        transcript = try values.decode([TranscriptItem].self, forKey: .transcript)
        summary = try values.decodeIfPresent(String.self, forKey: .summary)
    }

    /// Nothing has been said yet. A compacted session has no messages but is not empty.
    public var isEmpty: Bool { messages.isEmpty && (summary ?? "").isEmpty }
}

public struct SessionSummary: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: SessionKind
    public var title: String
    public var updatedAt: Date
}

public enum ApprovalMode: String, Codable, Sendable, CaseIterable {
    /// Ask before anything that changes state or leaves the device.
    case ask
    /// Run every tool call without asking.
    case auto
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var activeProfileID: UUID?
    public var activeModel: String?
    public var activeHostID: UUID?
    public var themeID: String
    public var fontSize: Double
    public var approvalMode: ApprovalMode
    public var systemPrompt: String
    /// The chat that was open last, shown again at launch.
    public var mode: SessionKind
    /// Tokens a conversation may fill. The context meter is measured against it.
    public var contextLimit: Int
    /// Trim and summarise without being asked once a conversation nears the limit.
    public var autoCompact: Bool
    /// Bookmark of the folder Cowork works in; nil for the app's own folder.
    public var coworkFolder: Data?

    public static let defaultContextLimit = 64_000

    public init(activeProfileID: UUID? = nil, activeModel: String? = nil, activeHostID: UUID? = nil,
                themeID: String = Theme.minimalDark.id, fontSize: Double = 13,
                approvalMode: ApprovalMode = .ask, systemPrompt: String = "",
                mode: SessionKind = .terminal, contextLimit: Int = AppSettings.defaultContextLimit,
                autoCompact: Bool = true, coworkFolder: Data? = nil) {
        self.activeProfileID = activeProfileID
        self.activeModel = activeModel
        self.activeHostID = activeHostID
        self.themeID = themeID
        self.fontSize = fontSize
        self.approvalMode = approvalMode
        self.systemPrompt = systemPrompt
        self.mode = mode
        self.contextLimit = contextLimit
        self.autoCompact = autoCompact
        self.coworkFolder = coworkFolder
    }

    public init(from decoder: Decoder) throws {
        // Every key is optional, so a settings file written by an older version keeps what it has.
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        activeProfileID = try values.decodeIfPresent(UUID.self, forKey: .activeProfileID)
        activeModel = try values.decodeIfPresent(String.self, forKey: .activeModel)
        activeHostID = try values.decodeIfPresent(UUID.self, forKey: .activeHostID)
        themeID = try values.decodeIfPresent(String.self, forKey: .themeID) ?? defaults.themeID
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? defaults.fontSize
        approvalMode = try values.decodeIfPresent(ApprovalMode.self, forKey: .approvalMode) ?? defaults.approvalMode
        systemPrompt = try values.decodeIfPresent(String.self, forKey: .systemPrompt) ?? defaults.systemPrompt
        mode = try values.decodeIfPresent(SessionKind.self, forKey: .mode) ?? defaults.mode
        contextLimit = try values.decodeIfPresent(Int.self, forKey: .contextLimit) ?? defaults.contextLimit
        autoCompact = try values.decodeIfPresent(Bool.self, forKey: .autoCompact) ?? defaults.autoCompact
        coworkFolder = try values.decodeIfPresent(Data.self, forKey: .coworkFolder)
    }
}
