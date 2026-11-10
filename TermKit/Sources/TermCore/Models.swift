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

public struct Session: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [ChatMessage]
    public var transcript: [TranscriptItem]

    public init(id: UUID = UUID(), title: String = "new session", createdAt: Date = Date(), updatedAt: Date = Date(),
                messages: [ChatMessage] = [], transcript: [TranscriptItem] = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.transcript = transcript
    }

    public var isEmpty: Bool { messages.isEmpty }
}

public struct SessionSummary: Identifiable, Equatable, Sendable {
    public var id: UUID
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

    public init(activeProfileID: UUID? = nil, activeModel: String? = nil, activeHostID: UUID? = nil,
                themeID: String = Theme.minimalDark.id, fontSize: Double = 13,
                approvalMode: ApprovalMode = .ask, systemPrompt: String = "") {
        self.activeProfileID = activeProfileID
        self.activeModel = activeModel
        self.activeHostID = activeHostID
        self.themeID = themeID
        self.fontSize = fontSize
        self.approvalMode = approvalMode
        self.systemPrompt = systemPrompt
    }
}
