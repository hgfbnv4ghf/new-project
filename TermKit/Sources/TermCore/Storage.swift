import Foundation

/// Holds API keys, passwords and private keys. The app backs this with the Keychain.
public protocol SecretStore: AnyObject {
    func secret(for key: String) -> String?
    func setSecret(_ value: String?, for key: String)
}

public final class InMemorySecretStore: SecretStore {
    private var values: [String: String] = [:]
    public init() {}
    public func secret(for key: String) -> String? { values[key] }
    public func setSecret(_ value: String?, for key: String) { values[key] = value }
}

/// JSON files under one directory: profiles, hosts, settings and one file per session.
public final class Storage {
    public let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL) {
        self.directory = directory
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
    }

    private var sessionsDirectory: URL { directory.appendingPathComponent("sessions", isDirectory: true) }

    private func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to name: String) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    public func loadProfiles() -> [Profile] { read([Profile].self, from: "profiles.json") ?? [] }
    public func saveProfiles(_ profiles: [Profile]) { write(profiles, to: "profiles.json") }

    public func loadHosts() -> [SSHHost] { read([SSHHost].self, from: "hosts.json") ?? [] }
    public func saveHosts(_ hosts: [SSHHost]) { write(hosts, to: "hosts.json") }

    public func loadSettings() -> AppSettings { read(AppSettings.self, from: "settings.json") ?? AppSettings() }
    public func saveSettings(_ settings: AppSettings) { write(settings, to: "settings.json") }

    public func saveSession(_ session: Session) {
        guard !session.isEmpty else { return }
        write(session, to: "sessions/\(session.id.uuidString).json")
    }

    public func loadSession(id: UUID) -> Session? {
        read(Session.self, from: "sessions/\(id.uuidString).json")
    }

    public func deleteSession(id: UUID) {
        try? FileManager.default.removeItem(at: sessionsDirectory.appendingPathComponent("\(id.uuidString).json"))
    }

    /// Most recently updated first.
    public func sessionSummaries() -> [SessionSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url -> SessionSummary? in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url),
                  let session = try? decoder.decode(Session.self, from: data) else { return nil }
            return SessionSummary(id: session.id, title: session.title, updatedAt: session.updatedAt)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }
}
