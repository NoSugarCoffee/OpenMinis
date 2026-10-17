import Crypto
import Foundation
import NIOCore
import NIOPosix
import XCTest
@preconcurrency import Citadel
@testable import MinisRemote

private func waitForPort(_ port: Int) throws {
    for _ in 0..<50 {
        if (try? runTool("/usr/bin/nc", ["-z", "127.0.0.1", String(port)])) != nil { return }
        Thread.sleep(forTimeInterval: 0.2)
    }
    XCTFail("Port \(port) did not come back")
}

private func randomHostKeyLine() -> String {
    RemoteKeyStore.publicKeyLine(of: Curve25519.Signing.PrivateKey(), comment: "wrong")
}

private func docker(_ arguments: [String]) throws {
    try runTool("/usr/bin/env", ["docker"] + arguments)
}

/// Accepts TCP connections and never speaks, like a host whose sshd stalls before key exchange.
private func startSilentListener() async throws -> (Channel, Int) {
    let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .childChannelInitializer { _ in MultiThreadedEventLoopGroup.singleton.next().makeSucceededVoidFuture() }
        .bind(host: "127.0.0.1", port: 0)
        .get()
    let port = try XCTUnwrap(channel.localAddress?.port)
    return (channel, port)
}

/// Answers every connection with `reply` and closes it, like a host whose sshd dies or is not SSH.
private final class ReplyAndClose: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    let reply: String

    init(reply: String) { self.reply = reply }

    func channelActive(context: ChannelHandlerContext) {
        let channel = context.channel
        channel.writeAndFlush(channel.allocator.buffer(string: reply)).whenComplete { _ in channel.close(promise: nil) }
    }
}

private func startReplyingListener(reply: String) async throws -> (Channel, Int) {
    let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .childChannelInitializer { child in child.pipeline.addHandler(ReplyAndClose(reply: reply)) }
        .bind(host: "127.0.0.1", port: 0)
        .get()
    let port = try XCTUnwrap(channel.localAddress?.port)
    return (channel, port)
}

private func silentHostPool(port: Int, connectTimeout: Duration) -> SSHConnectionPool {
    let config = RemoteHostConfig(
        name: "mini", address: "127.0.0.1", port: port, user: "dev", keyRef: "k",
        pinnedHostKey: randomHostKeyLine(), os: nil)
    return SSHConnectionPool(
        directory: FixedHostDirectory(hosts: [config], key: Curve25519.Signing.PrivateKey()),
        connectTimeout: connectTimeout)
}

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?
    var error: Error? { lock.withLock { stored } }
    func set(_ error: Error) { lock.withLock { stored = error } }
}

final class SSHConnectionPoolTests: XCTestCase {
    // MARK: Backoff

    func testBackoffDelaysCappedByRemaining() {
        XCTAssertEqual(SSHConnectionPool.backoffDelays(remaining: .seconds(10)), [.seconds(1), .seconds(2), .seconds(4)])
    }

    func testBackoffDelaysFull() {
        XCTAssertEqual(
            SSHConnectionPool.backoffDelays(remaining: .seconds(60)),
            [.seconds(1), .seconds(2), .seconds(4), .seconds(8)])
    }

    func testBackoffDelaysEmptyWhenNoTimeLeft() {
        XCTAssertEqual(SSHConnectionPool.backoffDelays(remaining: .milliseconds(500)), [])
        XCTAssertEqual(SSHConnectionPool.backoffDelays(remaining: .seconds(3)), [.seconds(1), .seconds(2)])
    }

    // MARK: Errors

    func testUserMessagesMatchSpec() {
        XCTAssertEqual(
            RemoteHostError.unreachable(host: "mini").userMessage,
            "Host `mini` unreachable — is Tailscale on?")
        XCTAssertEqual(
            RemoteHostError.authFailed(host: "mini").userMessage,
            "Host `mini` rejected this device's SSH key. Add the key shown in Settings → Remote Hosts → mini → Public Key to ~/.ssh/authorized_keys on the host.")
        XCTAssertEqual(
            RemoteHostError.hostKeyMismatch(host: "mini", presented: "SHA256:abc", presentedKey: "ssh-ed25519 AAAA").userMessage,
            "Host `mini` presented a different host key (SHA256:abc); connection refused. If the host was reinstalled, re-trust it in Settings → Remote Hosts → mini after checking the new fingerprint.")
        XCTAssertEqual(
            RemoteHostError.hostKeyUnpinned(host: "mini", presented: "SHA256:abc", presentedKey: "ssh-ed25519 AAAA").userMessage,
            "Host `mini` is not trusted yet (host key SHA256:abc). Check the fingerprint and trust it in Settings → Remote Hosts → mini.")
        XCTAssertEqual(
            RemoteHostError.notConfigured(host: "mini").userMessage,
            "Host `mini` is not configured. Add it in Settings → Remote Hosts.")
    }

    func testConnectErrorsMapToSpecCases() {
        XCTAssertEqual(
            SSHConnectionPool.mapConnectError(ChannelError.connectTimeout(.seconds(10)), host: "mini") as? RemoteHostError,
            .unreachable(host: "mini"))
        XCTAssertEqual(
            SSHConnectionPool.mapConnectError(IOError(errnoCode: ECONNREFUSED, reason: "connect"), host: "mini") as? RemoteHostError,
            .unreachable(host: "mini"))
        XCTAssertEqual(
            SSHConnectionPool.mapConnectError(SSHHandshakeTimedOut(), host: "mini") as? RemoteHostError,
            .unreachable(host: "mini"))
        XCTAssertEqual(
            SSHConnectionPool.mapConnectError(SSHClientError.allAuthenticationOptionsFailed, host: "mini") as? RemoteHostError,
            .authFailed(host: "mini"))
        XCTAssertEqual(
            SSHConnectionPool.mapConnectError(SSHClientError.unsupportedPrivateKeyAuthentication, host: "mini") as? RemoteHostError,
            .authFailed(host: "mini"))
        XCTAssertEqual(
            SSHConnectionPool.mapConnectError(RemoteHostError.hostKeyMismatch(host: "mini", presented: "SHA256:x", presentedKey: "k"), host: "mini") as? RemoteHostError,
            .hostKeyMismatch(host: "mini", presented: "SHA256:x", presentedKey: "k"))
        XCTAssertEqual(
            SSHConnectionPool.mapConnectError(RemoteKeyStoreError.keyNotFound(account: "k"), host: "mini") as? RemoteKeyStoreError,
            .keyNotFound(account: "k"))
    }

    // MARK: Host-key verdicts

    func testNilPinIsUnpinnedWithFingerprint() throws {
        let presented = randomHostKeyLine()
        XCTAssertThrowsError(try verifyHostKey(host: "mini", pinned: nil, presented: presented)) { error in
            XCTAssertEqual(
                error as? RemoteHostError,
                .hostKeyUnpinned(
                    host: "mini", presented: try! HostKeyFingerprint.sha256(openSSHPublicKey: presented),
                    presentedKey: presented))
        }
    }

    func testDifferentPinIsMismatch() throws {
        let presented = randomHostKeyLine()
        XCTAssertThrowsError(try verifyHostKey(host: "mini", pinned: randomHostKeyLine(), presented: presented)) { error in
            XCTAssertEqual(
                error as? RemoteHostError,
                .hostKeyMismatch(
                    host: "mini", presented: try! HostKeyFingerprint.sha256(openSSHPublicKey: presented),
                    presentedKey: presented))
        }
    }

    func testSamePinMatchesIgnoringComment() throws {
        let line = randomHostKeyLine()
        let withoutComment = line.split(separator: " ").prefix(2).joined(separator: " ")
        XCTAssertNoThrow(try verifyHostKey(host: "mini", pinned: line, presented: withoutComment))
    }

    // MARK: Directory and local failures

    func testUnknownHostIsNotConfigured() async {
        let pool = SSHConnectionPool(
            directory: FixedHostDirectory(hosts: [], key: Curve25519.Signing.PrivateKey()),
            connectTimeout: .seconds(10))
        do {
            _ = try await pool.exec(host: "gone", script: "true", timeout: .seconds(5))
            XCTFail("Expected notConfigured")
        } catch {
            XCTAssertEqual(error as? RemoteHostError, .notConfigured(host: "gone"))
        }
    }

    func testRefusedPortIsUnreachable() async {
        let config = RemoteHostConfig(
            name: "mini", address: "127.0.0.1", port: 1, user: "dev", keyRef: "k",
            pinnedHostKey: randomHostKeyLine(), os: nil)
        let pool = SSHConnectionPool(
            directory: FixedHostDirectory(hosts: [config], key: Curve25519.Signing.PrivateKey()),
            connectTimeout: .seconds(10))
        do {
            _ = try await pool.exec(host: "mini", script: "true", timeout: .seconds(5))
            XCTFail("Expected unreachable")
        } catch {
            XCTAssertEqual(error as? RemoteHostError, .unreachable(host: "mini"))
        }
    }

    @MainActor
    func testStoreBackedDirectoryReadsHostAndKey() async throws {
        let secrets = InMemorySecretStore()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pool-dir-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = try RemoteHostStore(fileURL: fileURL, secrets: secrets, onHostAdded: { _ in })
        let publicLine = try RemoteKeyStore.generateEd25519(store: secrets, account: "k1", comment: "c")
        let config = RemoteHostConfig(
            name: "mini", address: "a", port: 22, user: "u", keyRef: "k1", pinnedHostKey: nil, os: nil)
        try store.add(config)
        let directory = StoreBackedHostDirectory(store: store, secrets: secrets)

        let found = await directory.config(named: "mini")
        let missing = await directory.config(named: "other")
        let key = try await directory.privateKey(for: config)

        XCTAssertEqual(found, config)
        XCTAssertNil(missing)
        XCTAssertEqual(RemoteKeyStore.publicKeyLine(of: key, comment: "c"), publicLine)
    }

    // MARK: Opt-in, against Tests/Fixtures/sshd

    func testUnpinnedHostKeyIsReported() async throws {
        let fixture = try SSHFixture.fromEnvironment()
        let presented = try await fixture.presentedFingerprint()
        XCTAssertTrue(presented.hasPrefix("SHA256:"), presented)
        XCTAssertFalse(presented.hasSuffix("="), presented)
    }

    func testMismatchedHostKeyIsRejected() async throws {
        let fixture = try SSHFixture.fromEnvironment()
        let pool = fixture.pool(pinnedHostKey: randomHostKeyLine(), key: fixture.key)
        do {
            _ = try await execRetryingFixtureRace(pool, script: "true")
            XCTFail("Expected hostKeyMismatch")
        } catch RemoteHostError.hostKeyMismatch(let host, let presented, _) {
            XCTAssertEqual(host, "mini")
            XCTAssertTrue(presented.hasPrefix("SHA256:"), presented)
        }
    }

    func testWrongClientKeyIsAuthFailed() async throws {
        let fixture = try SSHFixture.fromEnvironment()
        let pinned = try await fixture.pinnedHostKeyLine()
        let pool = fixture.pool(pinnedHostKey: pinned, key: Curve25519.Signing.PrivateKey())
        do {
            _ = try await execRetryingFixtureRace(pool, script: "true")
            XCTFail("Expected authFailed")
        } catch {
            XCTAssertEqual(error as? RemoteHostError, .authFailed(host: "mini"))
        }
    }

    func testExecReturnsStdoutStderrAndExitStatus() async throws {
        let fixture = try SSHFixture.fromEnvironment()
        let pool = fixture.pool(pinnedHostKey: try await fixture.pinnedHostKeyLine(), key: fixture.key)

        let failed = try await execRetryingFixtureRace(pool, script: "printf 'out é'; printf 'err' >&2; exit 97")
        let succeeded = try await pool.exec(host: "mini", script: "echo ok", timeout: .seconds(20))

        XCTAssertEqual(failed, ExecResult(stdout: Array("out é".utf8), stderr: Array("err".utf8), exitStatus: 97))
        XCTAssertEqual(succeeded.stdoutText, "ok\n")
        XCTAssertEqual(succeeded.exitStatus, 0)
    }

    func testExecTimeoutThrows() async throws {
        let fixture = try SSHFixture.fromEnvironment()
        let pool = fixture.pool(pinnedHostKey: try await fixture.pinnedHostKeyLine(), key: fixture.key)
        _ = try await execRetryingFixtureRace(pool, script: "true")
        do {
            _ = try await pool.exec(host: "mini", script: "sleep 5", timeout: .seconds(1))
            XCTFail("Expected timedOut")
        } catch {
            XCTAssertEqual(error as? RemoteExecError, .timedOut(host: "mini", after: .seconds(1)))
        }
    }

    func testSFTPOpensOnPooledConnection() async throws {
        let fixture = try SSHFixture.fromEnvironment()
        let pool = fixture.pool(pinnedHostKey: try await fixture.pinnedHostKeyLine(), key: fixture.key)
        _ = try await execRetryingFixtureRace(pool, script: "true")
        let sftp = try await pool.sftp(host: "mini")
        let home = try await sftp.getRealPath(atPath: ".")
        try await sftp.close()
        XCTAssertEqual(home, "/home/\(fixture.user)")
    }

    func testReconnectAfterDrop() async throws {
        let fixture = try SSHFixture.fromEnvironment()
        let pool = fixture.pool(pinnedHostKey: try await fixture.pinnedHostKeyLine(), key: fixture.key)
        let before = try await execRetryingFixtureRace(pool, script: "echo before")
        XCTAssertEqual(before.stdoutText, "before\n")

        try runTool("/usr/bin/env", ["docker", "restart", "-t", "0", "minis-sshtest"])
        try waitForPort(fixture.port)

        let after = try await execRetryingFixtureRace(pool, script: "echo after")
        XCTAssertEqual(after.stdoutText, "after\n")
    }

    /// Covers `onDisconnect` and `invalidateClosed` together: Citadel usually reports the drop first, so
    /// `invalidateClosed` alone cannot be isolated against a real server.
    func testDroppedConnectionLeavesPool() async throws {
        let fixture = try SSHFixture.fromEnvironment()
        let pool = fixture.pool(pinnedHostKey: try await fixture.pinnedHostKeyLine(), key: fixture.key)
        _ = try await execRetryingFixtureRace(pool, script: "true")
        let connected = await pool.cachedHostNames
        XCTAssertEqual(connected, ["mini"])

        try runTool("/usr/bin/env", ["docker", "restart", "-t", "0", "minis-sshtest"])
        try waitForPort(fixture.port)
        await pool.invalidateClosed()

        let afterDrop = await pool.cachedHostNames
        XCTAssertEqual(afterDrop, [])
    }

    func testInvalidateClosesAndNextUseReconnects() async throws {
        let fixture = try SSHFixture.fromEnvironment()
        let pool = fixture.pool(pinnedHostKey: try await fixture.pinnedHostKeyLine(), key: fixture.key)
        _ = try await execRetryingFixtureRace(pool, script: "true")

        await pool.invalidate(host: "mini")
        let afterInvalidate = await pool.cachedHostNames
        let next = try await pool.exec(host: "mini", script: "echo again", timeout: .seconds(20))
        let afterReconnect = await pool.cachedHostNames

        XCTAssertEqual(afterInvalidate, [])
        XCTAssertEqual(next.stdoutText, "again\n")
        XCTAssertEqual(afterReconnect, ["mini"])
    }

    func testNewConnectionRunsRetention() async throws {
        let fixture = try SSHFixture.fromEnvironment()
        let pool = fixture.pool(pinnedHostKey: try await fixture.pinnedHostKeyLine(), key: fixture.key)
        let seeded = try await execRetryingFixtureRace(
            pool,
            script: "mkdir -p ~/.minis/runs/stale ~/.minis/runs/fresh && touch -d '2000-01-01 00:00' ~/.minis/runs/stale")
        XCTAssertEqual(seeded.exitStatus, 0, seeded.stderrText)

        await pool.invalidate(host: "mini")
        var remaining = ""
        for _ in 0..<20 {
            remaining = try await pool.exec(host: "mini", script: "ls ~/.minis/runs", timeout: .seconds(20)).stdoutText
            if !remaining.contains("stale") { break }
            try await Task.sleep(for: .milliseconds(250))
        }

        let entries = remaining.split(separator: "\n")
        XCTAssertFalse(entries.contains("stale"), remaining)
        XCTAssertTrue(entries.contains("fresh"), remaining)
    }

    // MARK: Fix round 1: dropped, stalled and half-open connections

    func testStalledHandshakeIsUnreachableWithinConnectTimeout() async throws {
        let (listener, port) = try await startSilentListener()
        defer { listener.close(promise: nil) }
        let pool = silentHostPool(port: port, connectTimeout: .seconds(1))
        let failure = ErrorBox()
        let finished = expectation(description: "exec returns")
        let started = ContinuousClock.now
        Task {
            do {
                _ = try await pool.exec(host: "mini", script: "true", timeout: .seconds(30))
            } catch {
                failure.set(error)
            }
            finished.fulfill()
        }

        await fulfillment(of: [finished], timeout: 5)

        XCTAssertEqual(failure.error as? RemoteHostError, .unreachable(host: "mini"))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(4))
    }

    /// The handshake ends before key exchange; the next connect may well succeed, so the error must be the one
    /// callers retry.
    func testHostClosingDuringHandshakeIsUnreachable() async throws {
        for reply in ["SSH-2.0-OpenSSH_9.6\r\n", "HTTP/1.1 400 Bad Request\r\n\r\n", "SSH-2.0-OpenSSH_9.6\r\n\u{0}\u{0}\u{0}\u{5}garbage"] {
            let (listener, port) = try await startReplyingListener(reply: reply)
            let pool = silentHostPool(port: port, connectTimeout: .seconds(3))
            do {
                let result = try await pool.exec(host: "mini", script: "true", timeout: .seconds(10))
                XCTFail("Expected unreachable, got \(result)")
            } catch {
                XCTAssertEqual(error as? RemoteHostError, .unreachable(host: "mini"), "\(reply.debugDescription): \(error)")
            }
            try await listener.close()
        }
    }

    func testHandshakeHandlerDisconnectIsUnreachable() {
        struct Disconnected: Error {}
        XCTAssertEqual(
            SSHConnectionPool.mapConnectError(Disconnected(), host: "mini") as? RemoteHostError, .unreachable(host: "mini"))
    }

    func testInvalidateDropsPendingConnect() async throws {
        let (listener, port) = try await startSilentListener()
        defer { listener.close(promise: nil) }
        let pool = silentHostPool(port: port, connectTimeout: .seconds(2))
        let stalledEnded = expectation(description: "stalled exec returns")
        Task {
            _ = try? await pool.exec(host: "mini", script: "true", timeout: .seconds(30))
            stalledEnded.fulfill()
        }
        try await Task.sleep(for: .milliseconds(300))
        let pendingBefore = await pool.pendingHostNames

        await pool.invalidate(host: "mini")
        let pendingAfter = await pool.pendingHostNames
        await fulfillment(of: [stalledEnded], timeout: 5)
        let cachedAfterStalledConnectEnds = await pool.cachedHostNames

        XCTAssertEqual(pendingBefore, ["mini"])
        XCTAssertEqual(pendingAfter, [])
        XCTAssertEqual(cachedAfterStalledConnectEnds, [])
    }

    func testDropDuringExecIsUnreachableNotExitZero() async throws {
        let fixture = try SSHFixture.fromEnvironment()
        let pool = fixture.pool(pinnedHostKey: try await fixture.pinnedHostKeyLine(), key: fixture.key)
        _ = try await execRetryingFixtureRace(pool, script: "true")

        let running = Task { try await pool.exec(host: "mini", script: "sleep 5", timeout: .seconds(20)) }
        try await Task.sleep(for: .seconds(1))
        // SIGKILL on the session's sshd closes TCP cleanly (FIN) with no exit-status; a container
        // restart resets the connection instead, which Citadel already reports as an error.
        try docker(["exec", "minis-sshtest", "pkill", "-KILL", "-f", "sshd: dev"])
        let outcome = await running.result

        switch outcome {
        case .success(let result):
            XCTFail("Expected unreachable, got \(result)")
        case .failure(let error):
            XCTAssertEqual(error as? RemoteHostError, .unreachable(host: "mini"))
        }
    }

    func testHalfOpenConnectionIsDroppedAsUnreachable() async throws {
        let fixture = try SSHFixture.fromEnvironment()
        let pool = fixture.pool(pinnedHostKey: try await fixture.pinnedHostKeyLine(), key: fixture.key)
        _ = try await execRetryingFixtureRace(pool, script: "true")

        try docker(["pause", "minis-sshtest"])
        let outcome: Result<ExecResult, Error>
        do {
            outcome = .success(try await pool.exec(host: "mini", script: "true", timeout: .seconds(30)))
        } catch {
            outcome = .failure(error)
        }
        let cached = await pool.cachedHostNames
        try docker(["unpause", "minis-sshtest"])

        switch outcome {
        case .success(let result):
            XCTFail("Expected unreachable, got \(result)")
        case .failure(let error):
            XCTAssertEqual(error as? RemoteHostError, .unreachable(host: "mini"))
        }
        XCTAssertEqual(cached, [])
    }

    func testChannelOpenCountsAgainstExecTimeout() async throws {
        let fixture = try SSHFixture.fromEnvironment()
        let pool = fixture.pool(pinnedHostKey: try await fixture.pinnedHostKeyLine(), key: fixture.key)
        _ = try await execRetryingFixtureRace(pool, script: "true")

        try docker(["pause", "minis-sshtest"])
        let started = ContinuousClock.now
        let outcome: Result<ExecResult, Error>
        do {
            outcome = .success(try await pool.exec(host: "mini", script: "true", timeout: .seconds(2)))
        } catch {
            outcome = .failure(error)
        }
        let elapsed = ContinuousClock.now - started
        try docker(["unpause", "minis-sshtest"])

        switch outcome {
        case .success(let result):
            XCTFail("Expected timedOut, got \(result)")
        case .failure(let error):
            XCTAssertEqual(error as? RemoteExecError, .timedOut(host: "mini", after: .seconds(2)))
        }
        XCTAssertLessThan(elapsed, .seconds(5))
    }

    func testCancelledExecThrowsInsteadOfPartialSuccess() async throws {
        let fixture = try SSHFixture.fromEnvironment()
        let pool = fixture.pool(pinnedHostKey: try await fixture.pinnedHostKeyLine(), key: fixture.key)
        _ = try await execRetryingFixtureRace(pool, script: "true")

        let running = Task { try await pool.exec(host: "mini", script: "echo partial; sleep 5", timeout: .seconds(20)) }
        try await Task.sleep(for: .milliseconds(500))
        running.cancel()
        let outcome = await running.result

        switch outcome {
        case .success(let result):
            XCTFail("Expected CancellationError, got \(result)")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testExecCancelledDuringItsConnectSendsNothing() async throws {
        let fixture = try SSHFixture.fromEnvironment()
        let pool = fixture.pool(pinnedHostKey: try await fixture.pinnedHostKeyLine(), key: fixture.key)
        _ = try await execRetryingFixtureRace(pool, script: "true")
        let marker = "/tmp/minis-sent-\(UUID().uuidString)"
        await pool.invalidate(host: "mini")

        try docker(["pause", "minis-sshtest"])
        let running = Task { try await pool.exec(host: "mini", script: "touch \(marker)", timeout: .seconds(20)) }
        try await Task.sleep(for: .milliseconds(500))
        running.cancel()
        try await Task.sleep(for: .milliseconds(500))
        try docker(["unpause", "minis-sshtest"])
        let outcome = await running.result
        try await Task.sleep(for: .seconds(1))
        let check = try await pool.exec(host: "mini", script: "test -e \(marker)", timeout: .seconds(10))

        switch outcome {
        case .success(let result):
            XCTFail("Expected CancellationError, got \(result)")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(check.exitStatus, 1, "the cancelled exec must not reach the host")
    }

    func testTimedOutExecOnHalfOpenConnectionStillDropsClient() async throws {
        let fixture = try SSHFixture.fromEnvironment()
        let pool = fixture.pool(pinnedHostKey: try await fixture.pinnedHostKeyLine(), key: fixture.key)
        _ = try await execRetryingFixtureRace(pool, script: "true")

        try docker(["pause", "minis-sshtest"])
        let outcome: Result<ExecResult, Error>
        do {
            outcome = .success(try await pool.exec(host: "mini", script: "true", timeout: .seconds(2)))
        } catch {
            outcome = .failure(error)
        }
        let cachedAfterTimeout = await pool.cachedHostNames
        var cached = cachedAfterTimeout
        let deadline = ContinuousClock.now + .seconds(17)
        while !cached.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
            cached = await pool.cachedHostNames
        }
        try docker(["unpause", "minis-sshtest"])

        switch outcome {
        case .success(let result):
            XCTFail("Expected timedOut, got \(result)")
        case .failure(let error):
            XCTAssertEqual(error as? RemoteExecError, .timedOut(host: "mini", after: .seconds(2)))
        }
        XCTAssertEqual(cachedAfterTimeout, ["mini"], "a timeout alone must not drop the client")
        XCTAssertEqual(cached, [], "the late channel-open failure must drop the half-open client")
    }
}
