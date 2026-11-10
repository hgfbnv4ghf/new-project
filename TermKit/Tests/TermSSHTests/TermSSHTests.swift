import XCTest
import TermCore
@testable import TermSSH

final class TermSSHTests: XCTestCase {
    func testFingerprintMatchesSSHKeygenFormat() {
        // SHA-256 of the three bytes "abc", base64 without padding.
        XCTAssertEqual(SSHKeys.fingerprint(ofOpenSSHKey: "ssh-ed25519 YWJj"),
                       "SHA256:ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0")
        XCTAssertEqual(SSHKeys.fingerprint(ofOpenSSHKey: "garbage"), "(unreadable key)")
    }

    func testRejectsUnreadablePrivateKey() {
        let credentials = SSHCredentials(host: "h", username: "u", secret: .privateKey(pem: "not a key", passphrase: nil))
        XCTAssertThrowsError(try SSHKeys.authentication(for: credentials))
    }

    // MARK: Live (needs an SSH server)

    private struct Target {
        var host: String
        var port: Int
        var user: String
        var secret: SSHCredentials.Secret
    }

    private func target() throws -> Target {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["TERMAI_SSH_HOST"], let user = env["TERMAI_SSH_USER"] else {
            throw XCTSkip("set TERMAI_SSH_HOST, TERMAI_SSH_USER and TERMAI_SSH_PASSWORD or TERMAI_SSH_KEYFILE to run")
        }
        let secret: SSHCredentials.Secret
        if let keyFile = env["TERMAI_SSH_KEYFILE"] {
            secret = .privateKey(pem: try String(contentsOfFile: keyFile, encoding: .utf8), passphrase: env["TERMAI_SSH_PASSPHRASE"])
        } else {
            secret = .password(env["TERMAI_SSH_PASSWORD"] ?? "")
        }
        return Target(host: host, port: Int(env["TERMAI_SSH_PORT"] ?? "22") ?? 22, user: user, secret: secret)
    }

    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func append(_ chunk: String) { lock.lock(); text += chunk; lock.unlock() }
        var value: String { lock.lock(); defer { lock.unlock() }; return text }
    }

    func testLiveExecExitCodesTimeoutAndHostKeyPinning() async throws {
        let target = try target()
        let credentials = SSHCredentials(host: target.host, port: target.port, username: target.user, secret: target.secret)

        let connection = try await SSHConnection.connect(credentials, label: "test", trustedHostKey: nil)
        XCTAssertTrue(connection.hostKey.hasPrefix("ssh-") || connection.hostKey.hasPrefix("ecdsa-"), connection.hostKey)
        if let expected = ProcessInfo.processInfo.environment["TERMAI_SSH_FINGERPRINT"] {
            XCTAssertEqual(SSHKeys.fingerprint(ofOpenSSHKey: connection.hostKey), expected)
        }

        let output = Output()
        let ok = try await connection.run(command: "echo out; echo err 1>&2", timeout: 20) { output.append($0) }
        XCTAssertEqual(ok, 0)
        XCTAssertTrue(output.value.contains("out"), output.value)
        XCTAssertTrue(output.value.contains("err"), output.value)

        let failed = try await connection.run(command: "exit 7", timeout: 20) { _ in }
        XCTAssertEqual(failed, 7)

        do {
            _ = try await connection.run(command: "sleep 30", timeout: 1) { _ in }
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? SSHError, .timedOut(seconds: 1))
        }

        // Through the tool layer, as the agent uses it.
        let tools = ToolBox(workspace: FileManager.default.temporaryDirectory, shell: connection)
        let result = await tools.run(ToolCall(id: "1", name: "ssh_exec", arguments: #"{"command":"printf hello; exit 2"}"#)) { _ in }
        XCTAssertEqual(result, ToolResult(text: "hello\n[exit 2]", isError: true))
        await connection.close()

        // The recorded key is accepted again; a different pinned key is refused.
        let again = try await SSHConnection.connect(credentials, label: "test", trustedHostKey: connection.hostKey)
        await again.close()
        do {
            _ = try await SSHConnection.connect(credentials, label: "test", trustedHostKey: "ssh-ed25519 YWJj")
            XCTFail("expected a host key mismatch")
        } catch {
            XCTAssertEqual(error as? SSHError, .hostKeyMismatch(expected: "ssh-ed25519 YWJj", received: connection.hostKey))
        }
    }

    func testLiveWrongPasswordFails() async throws {
        let target = try target()
        let credentials = SSHCredentials(host: target.host, port: target.port, username: target.user, secret: .password("definitely-wrong"))
        do {
            _ = try await SSHConnection.connect(credentials, label: "test", trustedHostKey: nil)
            XCTFail("expected authentication to fail")
        } catch {}
    }
}
