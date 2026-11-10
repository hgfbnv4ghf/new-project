import Citadel
import Crypto
import Foundation
import NIOCore
import NIOSSH
import TermCore

public struct SSHCredentials: Sendable {
    public enum Secret: Sendable {
        case password(String)
        case privateKey(pem: String, passphrase: String?)
    }

    public var host: String
    public var port: Int
    public var username: String
    public var secret: Secret

    public init(host: String, port: Int = 22, username: String, secret: Secret) {
        self.host = host
        self.port = port
        self.username = username
        self.secret = secret
    }
}

public enum SSHError: LocalizedError, Equatable {
    case hostKeyMismatch(expected: String, received: String)
    case unsupportedKey(String)
    case timedOut(seconds: Int)

    public var errorDescription: String? {
        switch self {
        case .hostKeyMismatch(let expected, let received):
            return "HOST KEY CHANGED. Expected \(SSHKeys.fingerprint(ofOpenSSHKey: expected)), server sent \(SSHKeys.fingerprint(ofOpenSSHKey: received)). Refusing to connect; if the server was reinstalled, forget its key in settings."
        case .unsupportedKey(let detail):
            return "unsupported private key: \(detail). Use an Ed25519 or RSA key in OpenSSH format."
        case .timedOut(let seconds):
            return "timed out after \(seconds)s; the command may still be running on the host"
        }
    }
}

public enum SSHKeys {
    /// `SHA256:…` fingerprint in the same form `ssh-keygen -lf` prints.
    public static func fingerprint(ofOpenSSHKey key: String) -> String {
        let parts = key.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "(unreadable key)" }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    static func authentication(for credentials: SSHCredentials) throws -> SSHAuthenticationMethod {
        switch credentials.secret {
        case .password(let password):
            return .passwordBased(username: credentials.username, password: password)
        case .privateKey(let pem, let passphrase):
            let key = pem.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            let decryptionKey = passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
            let type: SSHKeyType
            do {
                type = try SSHKeyDetection.detectPrivateKeyType(from: key)
            } catch {
                throw SSHError.unsupportedKey(error.localizedDescription)
            }
            if type == .ed25519 {
                return .ed25519(username: credentials.username,
                                privateKey: try .init(sshEd25519: key, decryptionKey: decryptionKey))
            }
            if type == .rsa {
                return .rsa(username: credentials.username,
                            privateKey: try .init(sshRsa: key, decryptionKey: decryptionKey))
            }
            throw SSHError.unsupportedKey(type.description)
        }
    }
}

/// Trust on first use: records the key the server presents and rejects it if a different one was stored earlier.
private final class HostKeyRecorder: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let trusted: String?
    private let lock = NSLock()
    private var _received: String?

    init(trusted: String?) {
        self.trusted = trusted
    }

    var received: String? {
        lock.lock()
        defer { lock.unlock() }
        return _received
    }

    var mismatch: SSHError? {
        guard let trusted, let received, trusted != received else { return nil }
        return .hostKeyMismatch(expected: trusted, received: received)
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = String(openSSHPublicKey: hostKey)
        lock.lock()
        _received = key
        lock.unlock()
        if let mismatch {
            validationCompletePromise.fail(mismatch)
        } else {
            validationCompletePromise.succeed(())
        }
    }
}

public final class SSHConnection: RemoteShell, @unchecked Sendable {
    public let label: String
    /// The server's host key in OpenSSH format, to be stored and required on later connects.
    public let hostKey: String
    private let client: SSHClient

    private init(client: SSHClient, label: String, hostKey: String) {
        self.client = client
        self.label = label
        self.hostKey = hostKey
    }

    public static func connect(_ credentials: SSHCredentials, label: String, trustedHostKey: String?) async throws -> SSHConnection {
        let recorder = HostKeyRecorder(trusted: trustedHostKey)
        let authentication = try SSHKeys.authentication(for: credentials)
        do {
            let client = try await SSHClient.connect(
                host: credentials.host,
                port: credentials.port,
                authenticationMethod: authentication,
                hostKeyValidator: .custom(recorder),
                reconnect: .never)
            return SSHConnection(client: client, label: label, hostKey: recorder.received ?? "")
        } catch {
            // The handshake surfaces a generic failure; report the precise reason when it was the host key.
            if let mismatch = recorder.mismatch { throw mismatch }
            throw error
        }
    }

    public var isConnected: Bool { client.isConnected }

    public func close() async {
        try? await client.close()
    }

    public func run(command: String, timeout: TimeInterval, onOutput: @escaping @Sendable (String) -> Void) async throws -> Int {
        let client = self.client
        return try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask {
                do {
                    for try await chunk in try await client.executeCommandStream(command) {
                        switch chunk {
                        case .stdout(let buffer), .stderr(let buffer):
                            onOutput(String(buffer: buffer))
                        }
                    }
                    try Task.checkCancellation()
                    return 0
                } catch let failure as SSHClient.CommandFailed {
                    return failure.exitCode
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw SSHError.timedOut(seconds: Int(timeout))
            }
            defer { group.cancelAll() }
            guard let code = try await group.next() else { throw CancellationError() }
            return code
        }
    }
}
