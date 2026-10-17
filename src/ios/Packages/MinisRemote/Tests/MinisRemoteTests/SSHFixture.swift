import Crypto
import Foundation
import XCTest
@testable import MinisRemote

struct FixedHostDirectory: RemoteHostDirectory {
    let hosts: [RemoteHostConfig]
    let key: Curve25519.Signing.PrivateKey

    func config(named name: String) async -> RemoteHostConfig? {
        hosts.first { $0.name == name }
    }

    func privateKey(for config: RemoteHostConfig) async throws -> Curve25519.Signing.PrivateKey {
        key
    }
}

struct SSHFixture {
    let address: String
    let port: Int
    let user: String
    let key: Curve25519.Signing.PrivateKey

    static func fromEnvironment() throws -> SSHFixture {
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
        return SSHFixture(
            address: try XCTUnwrap(host), port: port, user: try XCTUnwrap(user),
            key: try Curve25519.Signing.PrivateKey(sshEd25519: keyText))
    }

    func config(pinnedHostKey: String?) -> RemoteHostConfig {
        RemoteHostConfig(
            name: "mini", address: address, port: port, user: user, keyRef: "fixture",
            pinnedHostKey: pinnedHostKey, os: nil)
    }

    func pool(pinnedHostKey: String?, key: Curve25519.Signing.PrivateKey) -> SSHConnectionPool {
        SSHConnectionPool(
            directory: FixedHostDirectory(hosts: [config(pinnedHostKey: pinnedHostKey)], key: key),
            connectTimeout: .seconds(10))
    }

    /// Asks an unpinned pool for the presented fingerprint, then picks the matching `ssh-keyscan` line,
    /// which also checks our fingerprint against OpenSSH's view of the same key.
    func pinnedHostKeyLine() async throws -> String {
        let presented = try await presentedFingerprint()
        let scan = try runTool("/usr/bin/ssh-keyscan", ["-p", String(port), address])
        let lines = scan.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") }
        for line in lines {
            let keyLine = line.split(separator: " ").dropFirst().joined(separator: " ")
            if (try? HostKeyFingerprint.sha256(openSSHPublicKey: keyLine)) == presented {
                return keyLine
            }
        }
        XCTFail("No ssh-keyscan line has fingerprint \(presented); got:\n\(scan)")
        throw RemoteHostError.notConfigured(host: "mini")
    }

    func presentedFingerprint() async throws -> String {
        let pool = pool(pinnedHostKey: nil, key: key)
        do {
            _ = try await execRetryingFixtureRace(pool, script: "true")
            XCTFail("Expected hostKeyUnpinned")
            throw RemoteHostError.notConfigured(host: "mini")
        } catch RemoteHostError.hostKeyUnpinned(let host, let presented, let presentedKey) {
            XCTAssertEqual(try HostKeyFingerprint.sha256(openSSHPublicKey: presentedKey), presented)
            XCTAssertEqual(host, "mini")
            return presented
        }
    }
}

/// up.sh only waits for the TCP port, so sshd may not answer the very first connect yet.
func execRetryingFixtureRace(_ pool: SSHConnectionPool, script: String) async throws -> ExecResult {
    do {
        return try await pool.exec(host: "mini", script: script, timeout: .seconds(20))
    } catch RemoteHostError.unreachable {
        try await Task.sleep(for: .seconds(1))
        return try await pool.exec(host: "mini", script: script, timeout: .seconds(20))
    }
}

@discardableResult
func runTool(_ path: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "SSHFixture", code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "\(path) \(arguments) exited \(process.terminationStatus)"])
    }
    return String(decoding: data, as: UTF8.self)
}
