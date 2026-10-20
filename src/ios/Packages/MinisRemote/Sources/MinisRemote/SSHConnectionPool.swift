@preconcurrency import Citadel
import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH
import os

public enum RemoteHostError: Error, Equatable, Sendable {
    case unreachable(host: String)
    case authFailed(host: String)
    /// `presented` is the `SHA256:` fingerprint shown to the user; `presentedKey` is the OpenSSH line to pin.
    case hostKeyMismatch(host: String, presented: String, presentedKey: String)
    case hostKeyUnpinned(host: String, presented: String, presentedKey: String)
    case notConfigured(host: String)

    /// Wording from spec §8; every message names the next step.
    public var userMessage: String {
        switch self {
        case .unreachable(let host):
            return "Host `\(host)` unreachable — is Tailscale on?"
        case .authFailed(let host):
            return "Host `\(host)` rejected this device's SSH key. Add the key shown in Settings → Remote Hosts → \(host) → Public Key to ~/.ssh/authorized_keys on the host."
        case .hostKeyMismatch(let host, let presented, _):
            return "Host `\(host)` presented a different host key (\(presented)); connection refused. If the host was reinstalled, re-trust it in Settings → Remote Hosts → \(host) after checking the new fingerprint."
        case .hostKeyUnpinned(let host, let presented, _):
            return "Host `\(host)` is not trusted yet (host key \(presented)). Check the fingerprint and trust it in Settings → Remote Hosts → \(host)."
        case .notConfigured(let host):
            return "Host `\(host)` is not configured. Add it in Settings → Remote Hosts."
        }
    }
}

public enum RemoteExecError: Error, Equatable, Sendable {
    /// The channel is left to finish on the host: Citadel does not expose it for closing.
    case timedOut(host: String, after: Duration)
}

/// A non-zero exit is a result, not an error, because callers branch on it (launcher exits 96/97/98).
/// stdout stays raw bytes so run output split mid-UTF-8 can go through `RemoteOutputBuffer` intact.
/// A command killed by a signal reports 0: Citadel only surfaces `exit-status`, not `exit-signal`.
public struct ExecResult: Equatable, Sendable {
    public let stdout: [UInt8]
    public let stderr: [UInt8]
    public let exitStatus: Int

    public init(stdout: [UInt8], stderr: [UInt8], exitStatus: Int) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitStatus = exitStatus
    }

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

public protocol RemoteHostDirectory: Sendable {
    func config(named name: String) async -> RemoteHostConfig?
    func privateKey(for config: RemoteHostConfig) async throws -> Curve25519.Signing.PrivateKey
}

public struct StoreBackedHostDirectory: RemoteHostDirectory {
    private let store: RemoteHostStore
    private let secrets: RemoteSecretStore

    public init(store: RemoteHostStore, secrets: RemoteSecretStore) {
        self.store = store
        self.secrets = secrets
    }

    public func config(named name: String) async -> RemoteHostConfig? {
        await MainActor.run { store.hosts.first { $0.name == name } }
    }

    public func privateKey(for config: RemoteHostConfig) async throws -> Curve25519.Signing.PrivateKey {
        try RemoteKeyStore.privateKey(store: secrets, account: config.keyRef)
    }
}

/// Throws `hostKeyUnpinned` / `hostKeyMismatch` with the presented key's `SHA256:` fingerprint.
/// Only the type and key fields are compared, so a comment on either line does not matter.
func verifyHostKey(host: String, pinned: String?, presented: String) throws {
    let fingerprint = try HostKeyFingerprint.sha256(openSSHPublicKey: presented)
    guard let pinned else {
        throw RemoteHostError.hostKeyUnpinned(host: host, presented: fingerprint, presentedKey: presented)
    }
    guard keyFields(of: pinned) == keyFields(of: presented) else {
        throw RemoteHostError.hostKeyMismatch(host: host, presented: fingerprint, presentedKey: presented)
    }
}

private func keyFields(of openSSHPublicKey: String) -> [Substring] {
    Array(openSSHPublicKey.split(separator: " ", omittingEmptySubsequences: true).prefix(2))
}

private struct PinnedHostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
    let host: String
    let pinned: String?

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        do {
            try verifyHostKey(host: host, pinned: pinned, presented: String(openSSHPublicKey: hostKey))
            validationCompletePromise.succeed(())
        } catch {
            validationCompletePromise.fail(error)
        }
    }
}

/// Lets the exec timeout cover channel opening, which Citadel bounds only by its own 15s. With
/// `reconnect: .never` Citadel never reassigns `session`, and opening a channel only reads it and hops to
/// the connection's event loop, so using the client from the exec's worker task is safe.
private struct ExecChannelOpener: @unchecked Sendable {
    let client: SSHClient
}

struct SSHHandshakeTimedOut: Error {}

/// The host closed the connection before authentication finished.
struct SSHHandshakeClosed: Error {}

/// An SFTP request got no answer in time. Requests are small (one chunk), so this means the connection is dead.
struct SFTPRequestTimedOut: Error {}

/// Citadel's SFTP requests have no timeout of their own and ignore task cancellation, so a half-open
/// connection would hang them forever. The abandoned request fails once the connection is closed.
func withSFTPDeadline<T: Sendable>(
    _ timeout: Duration, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let outcome = FirstOutcome<T>()
    let work = Task {
        do {
            outcome.resolve(.success(try await operation()))
        } catch {
            outcome.resolve(.failure(error))
        }
    }
    let timer = Task {
        try await Task.sleep(for: timeout)
        outcome.resolve(.failure(SFTPRequestTimedOut()))
    }
    return try await withTaskCancellationHandler {
        defer {
            timer.cancel()
            work.cancel()
        }
        return try await outcome.wait()
    } onCancel: {
        outcome.resolve(.failure(CancellationError()))
    }
}

/// Thrown when an exec ended without an error but the connection was gone by then.
private struct ConnectionLostDuringExec: Error {}

/// Bounds and cleans up connect attempts, which Citadel leaves to us:
/// - Citadel ignores its `loginTimeout`, and `NIOSSHHandler` swallows `channelInactive`, so a host that accepts
///   TCP but stalls key exchange or auth would hang the connect forever. Firing an error reaches Citadel's
///   handshake handler and fails the connect.
/// - For the same reason a host that closes the connection mid-handshake would hang the connect, and the
///   deadline's error no longer reaches a closed pipeline, so the close itself is turned into an error.
/// - Citadel does not close the socket when a connect fails (host-key rejection, auth failure), which would
///   hold one of sshd's `MaxStartups` slots until `LoginGraceTime`.
/// Citadel may add this one instance to several attempt channels, hence the per-channel state behind a lock.
private final class ConnectAttemptGuard: ChannelInboundHandler, Sendable {
    typealias InboundIn = Any

    private struct Attempt {
        let channel: Channel
        let deadline: Scheduled<Void>
    }

    private struct State {
        var settled = false
        var attempts: [Attempt] = []
    }

    private let timeout: TimeAmount
    private let state = NIOLockedValueBox(State())

    init(timeout: TimeAmount) {
        self.timeout = timeout
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        let deadline = context.eventLoop.scheduleTask(in: timeout) {
            channel.pipeline.fireErrorCaught(SSHHandshakeTimedOut())
            channel.close(promise: nil)
        }
        let settled = state.withLockedValue { state in
            if !state.settled { state.attempts.append(Attempt(channel: channel, deadline: deadline)) }
            return state.settled
        }
        if settled { deadline.cancel() }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !state.withLockedValue({ $0.settled }) {
            context.fireErrorCaught(SSHHandshakeClosed())
        }
        context.fireChannelInactive()
    }

    func succeeded() {
        settle().forEach { $0.deadline.cancel() }
    }

    func failed() {
        settle().forEach { attempt in
            attempt.deadline.cancel()
            attempt.channel.close(promise: nil)
        }
    }

    private func settle() -> [Attempt] {
        state.withLockedValue { state in
            state.settled = true
            defer { state.attempts = [] }
            return state.attempts
        }
    }
}

/// Delivers whichever outcome arrives first and ignores the rest, without waiting for the losers: Citadel's
/// channel open and output stream wait on NIO futures that ignore task cancellation.
final class FirstOutcome<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private var early: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?

    /// Returns false when another outcome already won, so the caller knows its result was discarded.
    @discardableResult
    func resolve(_ result: Result<Value, Error>) -> Bool {
        let (accepted, waiter): (Bool, CheckedContinuation<Value, Error>?) = lock.withLock {
            guard !settled else { return (false, nil) }
            settled = true
            guard let continuation else {
                early = result
                return (true, nil)
            }
            self.continuation = nil
            return (true, continuation)
        }
        waiter?.resume(with: result)
        return accepted
    }

    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<Value, Error>? = lock.withLock {
                guard let early else {
                    self.continuation = continuation
                    return nil
                }
                return early
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}

/// One long-lived SSH connection per host. Connections are opened lazily, dropped when Citadel reports a
/// disconnect, and re-opened on next use. Reconnect backoff is driven by the caller (`backoffDelays`),
/// because only the caller knows the tool's remaining timeout.
public actor SSHConnectionPool {
    private static let logger = Logger(subsystem: "app.minis.remote", category: "SSHConnectionPool")
    private static let backoffSteps: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8)]
    private static let retentionTimeout: Duration = .seconds(60)

    private let directory: any RemoteHostDirectory
    private let connectTimeout: Duration
    private var clients: [String: SSHClient] = [:]
    private var pendingConnects: [String: Task<Void, Error>] = [:]

    public init(directory: any RemoteHostDirectory, connectTimeout: Duration) {
        self.directory = directory
        self.connectTimeout = connectTimeout
    }

    var cachedHostNames: [String] { clients.keys.sorted() }
    var pendingHostNames: [String] { pendingConnects.keys.sorted() }

    /// Opens (or reuses) the host's connection without running anything, so a caller can tell a failure or
    /// cancellation before anything was sent from one during its exec.
    public func connect(host: String) async throws {
        _ = try await client(for: host)
    }

    /// `timeout` covers opening the channel and running the script, not connecting.
    public func exec(host: String, script: String, timeout: Duration) async throws -> ExecResult {
        let client = try await client(for: host)
        // A connect does not observe the caller's cancellation; a stopped caller must not send the script.
        try Task.checkCancellation()
        let result: ExecResult
        do {
            let opener = ExecChannelOpener(client: client)
            result = try await Self.run(
                script, on: opener, host: host, timeout: timeout,
                onLateFailure: { [weak self] error in
                    await self?.lateExecFailure(error, host: host, failedOn: opener)
                })
        } catch let timedOut as RemoteExecError {
            throw timedOut
        } catch let cancelled as CancellationError {
            throw cancelled
        } catch {
            throw await transportFailure(error, host: host, client: client)
        }
        guard client.isConnected else {
            throw await transportFailure(ConnectionLostDuringExec(), host: host, client: client)
        }
        return result
    }

    public func sftp(host: String) async throws -> SFTPClient {
        let client = try await client(for: host)
        do {
            return try await client.openSFTP()
        } catch {
            throw await transportFailure(error, host: host, client: client)
        }
    }

    /// Runs `body` on a fresh SFTP channel and closes it afterwards. Opening the channel is bounded by
    /// `openTimeout`; a half-open connection would otherwise wait Citadel's own 15s. Failures map like exec
    /// failures: a dead connection is dropped and reported as `unreachable` so callers can reconnect.
    public func withSFTP<T: Sendable>(
        host: String, openTimeout: Duration, _ body: @Sendable (SFTPClient) async throws -> T
    ) async throws -> T {
        let client = try await client(for: host)
        let opener = ExecChannelOpener(client: client)
        let sftp: SFTPClient
        do {
            sftp = try await withSFTPDeadline(openTimeout) { try await opener.client.openSFTP() }
        } catch let cancelled as CancellationError {
            throw cancelled
        } catch {
            throw await transportFailure(error, host: host, client: client)
        }
        defer { Self.closeInBackground(sftp, host: host) }
        do {
            return try await body(sftp)
        } catch let cancelled as CancellationError {
            throw cancelled
        } catch let timedOut as RemoteExecError {
            throw timedOut
        } catch let hostError as RemoteHostError {
            throw hostError
        } catch {
            throw await transportFailure(error, host: host, client: client)
        }
    }

    /// A3: a `direct-tcpip` channel to `127.0.0.1:<port>` on the host, so the host's VNC server is reached
    /// without listening anywhere new.
    public func openTunnel(
        host: String, port: Int, initialize: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) async throws -> Channel {
        let client = try await client(for: host)
        let target = SSHChannelType.DirectTCPIP(
            targetHost: "127.0.0.1", targetPort: port,
            originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0))
        do {
            return try await client.createDirectTCPIPChannel(using: target, initialize: initialize)
        } catch let rejected as NIOSSHError where rejected.type == .channelSetupRejected {
            throw ScreenTunnelError.from(rejection: String(describing: rejected), host: host, port: port)
        } catch {
            throw await transportFailure(error, host: host, client: client)
        }
    }

    /// Not awaited: closing waits for the peer, which a half-open connection never answers.
    private static func closeInBackground(_ sftp: SFTPClient, host: String) {
        Task {
            do {
                try await sftp.close()
            } catch {
                logger.error(
                    "Closing SFTP channel on \(host, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Also abandons an in-flight connect, so callers start a fresh one instead of awaiting a stalled one.
    public func invalidate(host: String) async {
        if let pending = pendingConnects.removeValue(forKey: host) {
            pending.cancel()
            Self.logger.info("Abandoned pending connect to \(host, privacy: .public)")
        }
        guard let client = clients.removeValue(forKey: host) else { return }
        Self.logger.info("Invalidated connection to \(host, privacy: .public)")
        await close(client, host: host)
    }

    public func invalidateClosed() {
        let closed = clients.filter { !$0.value.isConnected }.map(\.key)
        for host in closed {
            clients[host] = nil
            Self.logger.info("Dropped closed connection to \(host, privacy: .public)")
        }
    }

    /// Delays whose running total fits in `remaining`, so the last attempt still has time to run.
    public static func backoffDelays(remaining: Duration) -> [Duration] {
        var total: Duration = .zero
        return backoffSteps.prefix { step in
            total += step
            return total <= remaining
        }
    }

    static func mapConnectError(_ error: Error, host: String) -> Error {
        switch error {
        case let hostError as RemoteHostError:
            return hostError
        case is NIOConnectionError, is IOError, is SSHHandshakeTimedOut, is SSHHandshakeClosed:
            return RemoteHostError.unreachable(host: host)
        case let sshError as NIOSSHError where transientHandshakeErrors.contains(sshError.type):
            return RemoteHostError.unreachable(host: host)
        case let channelError as ChannelError:
            switch channelError {
            case .connectTimeout, .eof, .ioOnClosedChannel, .alreadyClosed:
                return RemoteHostError.unreachable(host: host)
            default:
                return error
            }
        case let clientError as SSHClientError:
            switch clientError {
            case .allAuthenticationOptionsFailed, .unsupportedPrivateKeyAuthentication,
                 .unsupportedPasswordAuthentication, .unsupportedHostBasedAuthentication:
                return RemoteHostError.authFailed(host: host)
            case .channelCreationFailed:
                return error
            }
        default:
            // Citadel's handshake handler fails a connect it abandons with a function-local `Disconnected`,
            // which no other module can name.
            guard String(describing: type(of: error)) == "Disconnected" else { return error }
            return RemoteHostError.unreachable(host: host)
        }
    }

    /// Garbled or cut-off key exchange: what a dying sshd, a middlebox or a non-SSH listener produces. A retry
    /// may succeed, so they map to `unreachable` like a refused connection.
    private static let transientHandshakeErrors: Set<NIOSSHError.ErrorType> = [
        .keyExchangeNegotiationFailure, .tcpShutdown, .protocolViolation, .invalidSSHMessage, .invalidPacketFormat,
        .unsupportedVersion, .excessiveVersionLength, .invalidEncryptedPacketLength, .invalidDecryptedPlaintextLength,
        .insufficientPadding, .excessPadding,
    ]

    private func client(for host: String) async throws -> SSHClient {
        if let existing = clients[host] {
            if existing.isConnected { return existing }
            clients[host] = nil
        }
        if let pending = pendingConnects[host] {
            try await awaitConnect(pending, host: host)
        } else {
            let connecting = Task { try await self.connectAndStore(host: host) }
            pendingConnects[host] = connecting
            defer {
                if pendingConnects[host] == connecting { pendingConnects[host] = nil }
            }
            try await awaitConnect(connecting, host: host)
        }
        guard let connected = clients[host] else {
            throw RemoteHostError.unreachable(host: host)
        }
        return connected
    }

    /// A connect cancelled by `invalidate` is a lost host for callers that were not cancelled themselves.
    private func awaitConnect(_ connecting: Task<Void, Error>, host: String) async throws {
        do {
            try await connecting.value
        } catch is CancellationError where !Task.isCancelled {
            throw RemoteHostError.unreachable(host: host)
        }
    }

    private func connectAndStore(host: String) async throws {
        guard let config = await directory.config(named: host) else {
            throw RemoteHostError.notConfigured(host: host)
        }
        let key = try await directory.privateKey(for: config)
        let attemptGuard = ConnectAttemptGuard(timeout: TimeAmount(connectTimeout))
        let client: SSHClient
        do {
            client = try await SSHClient.connect(
                host: config.address,
                port: config.port,
                authenticationMethod: .ed25519(username: config.user, privateKey: key),
                hostKeyValidator: .custom(PinnedHostKeyValidator(host: host, pinned: config.pinnedHostKey)),
                reconnect: .never,
                group: .singleton,
                channelHandlers: [attemptGuard],
                connectTimeout: TimeAmount(connectTimeout))
        } catch {
            attemptGuard.failed()
            let mapped = Self.mapConnectError(error, host: host)
            Self.logger.error(
                "Connect to \(host, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw mapped
        }
        attemptGuard.succeeded()
        if Task.isCancelled {
            await close(client, host: host)
            throw CancellationError()
        }
        let id = ObjectIdentifier(client)
        client.onDisconnect { [weak self] in
            Task { await self?.dropClient(host: host, id: id) }
        }
        clients[host] = client
        Self.logger.info("Connected to \(host, privacy: .public)")
        startRetention(host: host)
    }

    private func dropClient(host: String, id: ObjectIdentifier) {
        guard let current = clients[host], ObjectIdentifier(current) == id else { return }
        clients[host] = nil
        Self.logger.info("Connection to \(host, privacy: .public) closed")
    }

    /// A failure on a connection that is gone, or that can no longer open channels (half-open: TCP still up
    /// but the peer never answers), is a lost host, which callers retry with backoff.
    private func transportFailure(_ error: Error, host: String, client: SSHClient) async -> Error {
        Self.logger.error(
            "Operation on \(host, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        guard !client.isConnected || Self.isDeadChannelError(error) else { return error }
        if let current = clients[host], current === client {
            clients[host] = nil
        }
        if client.isConnected {
            await close(client, host: host)
        }
        return RemoteHostError.unreachable(host: host)
    }

    /// Matches by identity (the opener keeps the old client alive, so its address cannot be reused) so a
    /// late failure from an old client never drops a newer one.
    private func lateExecFailure(_ error: Error, host: String, failedOn opener: ExecChannelOpener) async {
        guard Self.isDeadChannelError(error), let current = clients[host], current === opener.client
        else { return }
        clients[host] = nil
        Self.logger.error(
            "Dropped half-open connection to \(host, privacy: .public) after a timed-out exec: \(String(describing: error), privacy: .public)")
        await close(current, host: host)
    }

    /// `SFTPError.missingResponse` is Citadel's verdict when the SFTP subsystem never answers its open.
    private static func isDeadChannelError(_ error: Error) -> Bool {
        if error is SFTPRequestTimedOut { return true }
        if case SFTPError.missingResponse = error { return true }
        guard let citadelError = error as? CitadelError else { return false }
        return citadelError == .channelCreationFailed || citadelError == .channelFailure
    }

    /// Closing errors are logged, not thrown: the connection is discarded either way.
    private func close(_ client: SSHClient, host: String) async {
        do {
            try await client.close()
        } catch {
            Self.logger.error(
                "Closing \(host, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func startRetention(host: String) {
        Task {
            do {
                let result = try await self.exec(
                    host: host, script: RemoteRunScripts.retention, timeout: Self.retentionTimeout)
                if result.exitStatus != 0 {
                    Self.logger.error(
                        "Retention on \(host, privacy: .public) exited \(result.exitStatus): \(result.stderrText, privacy: .public)")
                }
            } catch {
                Self.logger.error(
                    "Retention on \(host, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// `onLateFailure` gets the worker's error when the timer or cancellation already won, because a half-open
    /// connection only reveals itself by Citadel's channel-open failure 15s later.
    private static func run(
        _ script: String, on opener: ExecChannelOpener, host: String, timeout: Duration,
        onLateFailure: @escaping @Sendable (Error) async -> Void
    ) async throws -> ExecResult {
        let outcome = FirstOutcome<ExecResult>()
        let work = Task {
            let output = try await opener.client.executeCommandStream(script)
            return try await drain(output)
        }
        let timer = Task {
            try await Task.sleep(for: timeout)
            outcome.resolve(.failure(RemoteExecError.timedOut(host: host, after: timeout)))
        }
        Task {
            let workResult = await work.result
            if !outcome.resolve(workResult), case .failure(let error) = workResult {
                await onLateFailure(error)
            }
        }
        return try await withTaskCancellationHandler {
            defer {
                timer.cancel()
                work.cancel()
            }
            return try await outcome.wait()
        } onCancel: {
            outcome.resolve(.failure(CancellationError()))
        }
    }

    private static func drain(_ output: AsyncThrowingStream<ExecCommandOutput, Error>) async throws -> ExecResult {
        var stdout: [UInt8] = []
        var stderr: [UInt8] = []
        do {
            for try await chunk in output {
                switch chunk {
                case .stdout(let buffer): stdout += buffer.readableBytesView
                case .stderr(let buffer): stderr += buffer.readableBytesView
                }
            }
            // A cancelled iteration ends like a finished command; never report that as exit 0.
            try Task.checkCancellation()
            return ExecResult(stdout: stdout, stderr: stderr, exitStatus: 0)
        } catch let failed as SSHClient.CommandFailed {
            return ExecResult(stdout: stdout, stderr: stderr, exitStatus: failed.exitCode)
        }
    }
}

extension SSHConnectionPool: ScreenTunnelOpener {}
