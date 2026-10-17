import Crypto
import Foundation
import XCTest
@preconcurrency import Citadel

final class RemoteSSHSmokeTests: XCTestCase {
    func testConnectAndEcho() async throws {
        let env = ProcessInfo.processInfo.environment
        let host = env["MINIS_TEST_SSH_HOST"]
        let portText = env["MINIS_TEST_SSH_PORT"]
        let user = env["MINIS_TEST_SSH_USER"]
        let keyPath = env["MINIS_TEST_SSH_KEY"]
        try XCTSkipUnless(
            host != nil && portText != nil && user != nil && keyPath != nil,
            "Set MINIS_TEST_SSH_* (see Tests/Fixtures/sshd/up.sh) to run"
        )
        let port = try XCTUnwrap(portText.flatMap(Int.init), "MINIS_TEST_SSH_PORT is not an integer")

        let keyText = try String(contentsOfFile: try XCTUnwrap(keyPath), encoding: .utf8)
        let privateKey = try Curve25519.Signing.PrivateKey(sshEd25519: keyText)

        let client = try await SSHClient.connect(
            host: try XCTUnwrap(host),
            port: port,
            authenticationMethod: .ed25519(username: try XCTUnwrap(user), privateKey: privateKey),
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )

        let output = try await client.executeCommand("echo minis-ok")
        try await client.close()

        XCTAssertEqual(String(buffer: output).trimmingCharacters(in: .whitespacesAndNewlines), "minis-ok")
    }
}
