import Foundation
import os

public struct RemoteRunHandle: Codable, Sendable {
    public let host: String
    public let runId: String
    public var offset: Int

    public init(host: String, runId: String, offset: Int) {
        self.host = host
        self.runId = runId
        self.offset = offset
    }

    public var outputPath: String { "~/.minis/runs/\(runId)/out" }
    public var exitPath: String { "~/.minis/runs/\(runId)/exit" }
}

public enum RemoteExecResult: Sendable {
    case finished(output: String, outcome: RemoteRunOutcome, handle: RemoteRunHandle)
    case detached(handle: RemoteRunHandle)
    /// The command may still be running on the host; `handle.offset` is where reading stopped.
    case disconnected(partialOutput: String, handle: RemoteRunHandle)
    /// Following the run failed for a reason other than losing the host (host removed, key rejected after
    /// a reconnect, …). The command may still be running; the handle lets the caller report or recover it.
    case failed(partialOutput: String, handle: RemoteRunHandle, error: RemoteRunFailure)
}

/// Keeps `RemoteExecResult` Sendable while carrying an arbitrary underlying error.
public struct RemoteRunFailure: Error, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

/// Launcher exits 96/97/98 (`RemoteRunScripts.launch`) and any other non-zero launch. No run was started,
/// so there is no handle to poll.
public enum RemoteRunError: Error, Equatable, Sendable {
    case runDirectoryUnavailable(host: String, detail: String)
    case workingDirectoryNotFound(path: String, host: String)
    case commandDecodeFailed(host: String)
    case launchFailed(host: String, exitStatus: Int, detail: String)
    /// The launch exec exited 0 without printing its confirmation, so nothing may have started.
    case launchNotConfirmed(host: String, detail: String)
    case homeDirectoryUnknown(host: String, detail: String)
    /// The exec's stdout lacked the frame marker printed first by every control script: the script never ran.
    case outputFrameMissing(host: String, exitStatus: Int, detail: String)
    case commandTooLarge(encodedBytes: Int, limit: Int)

    /// The 97 wording is from spec §8; every message names the next step.
    public var userMessage: String {
        switch self {
        case .runDirectoryUnavailable(let host, let detail):
            return "Could not create ~/.minis/runs on `\(host)` (\(detail)). Check that the home directory on the host is writable and has free space."
        case .workingDirectoryNotFound(let path, let host):
            return "working directory `\(path)` not found on `\(host)`. Create it on the host or switch the session to an existing directory."
        case .commandDecodeFailed(let host):
            return "`\(host)` could not decode the command with `base64 -d` or `base64 -D`. Check that `base64` is installed on the host."
        case .launchFailed(let host, let exitStatus, let detail):
            return "Starting the command on `\(host)` failed with exit status \(exitStatus) (\(detail)). Check that `nohup`, `mkdir` and `base64` work in a login shell on the host."
        case .launchNotConfirmed(let host, let detail):
            return "Starting the command on `\(host)` could not be confirmed: the launch script did not finish (\(detail)). Nothing may be running; check that `/bin/sh` and `base64 -d` (or `base64 -D`) work on the host."
        case .homeDirectoryUnknown(let host, let detail):
            return "Could not read $HOME on `\(host)` to resolve the working directory (\(detail)). Use an absolute working directory."
        case .outputFrameMissing(let host, let exitStatus, let detail):
            return "`\(host)` did not run the Minis control script (exit status \(exitStatus), \(detail)). Check that `/bin/sh` and `base64 -d` (or `base64 -D`) work on the host and that its login files do not exit."
        case .commandTooLarge(let encodedBytes, let limit):
            return "The command is too large to send over SSH (\(encodedBytes) bytes once encoded; the limit is \(limit)). Write it to a script file on the host with file_write and run that file instead."
        }
    }
}

/// What `RemoteRunScripts.claimUnlaunched` found for a launch whose reply was lost.
enum LaunchProbeVerdict: Equatable, Sendable {
    case launched
    /// The command had not started; the run is now marked cancelled, so it never will.
    case claimed
}

enum RemoteStatusVerdict: Equatable, Sendable {
    case running
    case finished(RemoteRunOutcome)
    /// Empty or garbled status output from a flaky exec; poll again rather than report the run as abnormal.
    case transient
}

/// Starts detached runs on a host and follows their output by byte offset. The command runs under `nohup`
/// on the host, so losing the connection, timing out on reconnect or detaching never stops it; only
/// `cancel` (or the run's own timeout) does.
public actor RemoteExecutor {
    private static let logger = Logger(subsystem: "app.minis.remote", category: "RemoteExecutor")
    private static let pollInterval: Duration = .seconds(1)
    private static let cancelGrace: Duration = .seconds(5)
    /// Bounds each control exec (launch, status, read, cancel), which are all quick on a healthy host.
    private static let controlExecTimeout: Duration = .seconds(10)
    /// Reconnect budget for learning whether a launch whose reply was lost started the command.
    private static let launchProbeWindow: Duration = .seconds(7)
    private static let readChunkBytes = 256 * 1024
    /// Linux caps one exec argument at 128 KiB (MAX_ARG_STRLEN) and sshd passes the whole transported script
    /// as one `-c` argument; the command is base64-encoded twice on the way (about 1.78x).
    static let maxTransportedScriptBytes = 100_000
    private static let launchConfirmation = "minis-launched"

    private let pool: SSHConnectionPool
    private let clock = ContinuousClock()
    private var homeDirectories: [String: String] = [:]

    public init(pool: SSHConnectionPool) {
        self.pool = pool
    }

    /// Launch failures throw `RemoteRunError`; connect failures before the launch throw the pool's errors.
    /// Once launched, every result carries the handle (spec §4.4): a timeout cancels the run (spec §4.3),
    /// losing the host past the backoff returns `.disconnected`, and any other error returns `.failed`.
    /// Cancelling the calling task once the run is launched cancels it on the host and returns `.finished` with
    /// outcome `.cancelled`, the handle and the output read so far; cancelling before the launch throws
    /// `CancellationError`. A thrown error therefore always means the command did not and will not start.
    public func run(
        host: String, workdir: String, command: String, timeout: Duration, detach: Bool,
        onOutput: @Sendable (String) -> Void
    ) async throws -> RemoteExecResult {
        let deadline = clock.now + timeout
        let resolvedWorkdir = try await resolveWorkdir(workdir, host: host)
        let handle = RemoteRunHandle(host: host, runId: Self.makeRunId(), offset: 0)
        let marker = Self.makeFrameMarker()
        let transported = try Self.launchTransportScript(
            runId: handle.runId, workdir: resolvedWorkdir, command: command, marker: marker)
        try await pool.connect(host: host)
        try Task.checkCancellation()
        do {
            try await launch(handle, transported: transported, marker: marker, workdir: resolvedWorkdir)
        } catch where Self.isLaunchOutcomeUnknown(error) {
            return try await recoverUnconfirmedLaunch(
                handle, cause: error, deadline: deadline, detach: detach, onOutput: onOutput)
        }
        if detach { return .detached(handle: handle) }
        return try await follow(handle, deadline: deadline, onOutput: onOutput)
    }

    /// The launch exec may have reached the host before the reply was lost, so "nothing ran" would invite a
    /// second run, and a stop would leave the first one going. The run directory says which happened.
    func recoverUnconfirmedLaunch(
        _ handle: RemoteRunHandle, cause: Error, deadline: ContinuousClock.Instant, detach: Bool,
        onOutput: @Sendable (String) -> Void
    ) async throws -> RemoteExecResult {
        let stopped = cause is CancellationError || Task.isCancelled
        Self.logger.error(
            "Launch of run \(handle.runId, privacy: .public) on \(handle.host, privacy: .public) unconfirmed: \(String(describing: cause), privacy: .public)")
        let verdict = await probeLaunch(handle, deadline: stopped ? clock.now : min(deadline, clock.now + Self.launchProbeWindow))
        switch verdict {
        case .claimed:
            throw stopped || Task.isCancelled ? CancellationError() : cause
        case .launched:
            if stopped {
                await cancelOutsideCallerTask(handle)
                return .finished(output: "", outcome: .cancelled, handle: handle)
            }
            if detach { return .detached(handle: handle) }
            return try await follow(handle, deadline: deadline, onOutput: onOutput)
        case nil:
            guard stopped else { return .disconnected(partialOutput: "", handle: handle) }
            return .failed(
                partialOutput: "", handle: handle,
                error: RemoteRunFailure(
                    message: "Stopped while the command was starting on `\(handle.host)`, which could not be reached to cancel it."))
        }
    }

    /// Runs outside the caller's task: a stopped caller still needs the answer. nil means the host stayed silent.
    private func probeLaunch(_ handle: RemoteRunHandle, deadline: ContinuousClock.Instant) async -> LaunchProbeVerdict? {
        let probing = Task {
            try await self.reconnecting(
                host: handle.host, deadline: deadline, script: RemoteRunScripts.claimUnlaunched(runId: handle.runId))
        }
        do {
            return try await probing.value.flatMap(Self.launchProbeVerdict)
        } catch {
            Self.logger.error(
                "Probing launch of run \(handle.runId, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Spec §4.5: TERM the tree, wait the grace period, KILL the saved and fresh tree, then mark the run cancelled.
    public func cancel(_ handle: RemoteRunHandle) async throws {
        Self.logger.info("Cancelling run \(handle.runId, privacy: .public) on \(handle.host, privacy: .public)")
        _ = try await control(host: handle.host, script: RemoteRunScripts.cancelTree(runId: handle.runId, signal: "TERM"))
        try await Task.sleep(for: Self.cancelGrace)
        _ = try await control(host: handle.host, script: RemoteRunScripts.cancelTree(runId: handle.runId, signal: "KILL"))
        _ = try await control(host: handle.host, script: RemoteRunScripts.writeCancelled(runId: handle.runId))
    }

    // MARK: Pure helpers

    /// sshd hands exec commands to the user's login shell, which may be fish. Only the base64 alphabet and
    /// a single-quoted literal reach that shell; fish rejects `( … )` in command position, so the decode
    /// fallback runs inside `/bin/sh -c`.
    static func transportScript(_ script: String) -> String {
        let encoded = Data(script.utf8).base64EncodedString()
        return "printf '%s' \(encoded) | /bin/sh -c 'base64 -d 2>/dev/null || base64 -D' | /bin/sh"
    }

    /// Login files (`~/.ssh/rc`, a `.bashrc` some bash builds source for SSH commands) can print before the
    /// script runs. The marker line lets `unframe` drop that noise, and its absence proves the script never ran.
    static func framedTransportScript(_ script: String, marker: String) -> String {
        transportScript("printf '\\n%s\\n' '\(marker)'\n" + script)
    }

    static func unframe(_ stdout: [UInt8], marker: String) -> [UInt8]? {
        let frame = Array("\n\(marker)\n".utf8)
        guard stdout.count >= frame.count else { return nil }
        for start in 0...(stdout.count - frame.count) where stdout[start..<(start + frame.count)].elementsEqual(frame) {
            return Array(stdout[(start + frame.count)...])
        }
        return nil
    }

    static func makeFrameMarker() -> String {
        "__MINIS_BEGIN_\(makeRunId())__"
    }

    static func launchTransportScript(runId: String, workdir: String, command: String, marker: String) throws -> String {
        let script = RemoteRunScripts.launch(
            runId: runId, workdir: workdir, commandBase64: Data(command.utf8).base64EncodedString())
            + "printf '%s\\n' \(launchConfirmation)\n"
        let transported = framedTransportScript(script, marker: marker)
        let encodedBytes = transported.utf8.count
        guard encodedBytes <= maxTransportedScriptBytes else {
            throw RemoteRunError.commandTooLarge(encodedBytes: encodedBytes, limit: maxTransportedScriptBytes)
        }
        return transported
    }

    static func isLaunchOutcomeUnknown(_ error: Error) -> Bool {
        error is CancellationError || isTransportFailure(error)
    }

    static func launchProbeVerdict(_ result: ExecResult) -> LaunchProbeVerdict? {
        guard result.exitStatus == 0 else { return nil }
        switch result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "launched": return .launched
        case "claimed": return .claimed
        default: return nil
        }
    }

    static func launchError(
        exitStatus: Int, stdout: String, stderr: String, workdir: String, host: String
    ) -> RemoteRunError? {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        switch exitStatus {
        case 0:
            let confirmed = stdout.split(separator: "\n").contains { $0 == launchConfirmation }
            return confirmed ? nil : .launchNotConfirmed(host: host, detail: detail)
        case 96: return .runDirectoryUnavailable(host: host, detail: detail)
        case 97: return .workingDirectoryNotFound(path: workdir, host: host)
        case 98: return .commandDecodeFailed(host: host)
        default: return .launchFailed(host: host, exitStatus: exitStatus, detail: detail)
        }
    }

    /// Only `running 0` from a successful status exec means the process is gone without an exit file.
    static func statusVerdict(statusOutput: String) -> RemoteStatusVerdict {
        let trimmed = statusOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "running 0" { return .finished(.abnormal) }
        switch RemoteRunState.classify(statusOutput: trimmed) {
        case .running: return .running
        case .abnormal: return .transient
        case let outcome: return .finished(outcome)
        }
    }

    static func makeRunId() -> String {
        String(UUID().uuidString.lowercased().prefix(12))
    }

    static func failedResult(error: Error, partialOutput: String, handle: RemoteRunHandle) -> RemoteExecResult {
        let message: String
        switch error {
        case let hostError as RemoteHostError: message = hostError.userMessage
        case let runError as RemoteRunError: message = runError.userMessage
        default: message = String(describing: error)
        }
        return .failed(partialOutput: partialOutput, handle: handle, error: RemoteRunFailure(message: message))
    }

    // MARK: Launch

    private func resolveWorkdir(_ workdir: String, host: String) async throws -> String {
        guard !workdir.hasPrefix("/") else { return workdir }
        let home = try await homeDirectory(host: host)
        return RemoteRouting.resolveRemotePath(workdir, workdir: home, home: home)
    }

    /// `$HOME` on the host, cached per host name; file tools resolve relative paths against it.
    public func homeDirectory(host: String) async throws -> String {
        if let cached = homeDirectories[host] { return cached }
        let result = try await control(host: host, script: #"printf '%s' "$HOME""#)
        let home = result.stdoutText
        guard result.exitStatus == 0, home.hasPrefix("/") else {
            throw RemoteRunError.homeDirectoryUnknown(
                host: host, detail: "exit \(result.exitStatus), output `\(home)` \(result.stderrText)")
        }
        homeDirectories[host] = home
        return home
    }

    /// The cache is keyed by host name, so an edited or re-added host would otherwise keep the old machine's $HOME.
    public func forgetHome(host: String) {
        homeDirectories[host] = nil
    }

    var cachedHomeHostNames: [String] { homeDirectories.keys.sorted() }

    private func launch(_ handle: RemoteRunHandle, transported: String, marker: String, workdir: String) async throws {
        let host = handle.host
        let result = try await framedExec(host: host, transported: transported, marker: marker)
        if let error = Self.launchError(
            exitStatus: result.exitStatus, stdout: result.stdoutText, stderr: result.stderrText,
            workdir: workdir, host: host) {
            Self.logger.error(
                "Launch of run \(handle.runId, privacy: .public) on \(host, privacy: .public) exited \(result.exitStatus)")
            throw error
        }
        Self.logger.info("Launched run \(handle.runId, privacy: .public) on \(host, privacy: .public)")
    }

    // MARK: Following a run

    private func follow(
        _ launched: RemoteRunHandle, deadline: ContinuousClock.Instant, onOutput: @Sendable (String) -> Void
    ) async throws -> RemoteExecResult {
        var handle = launched
        var buffer = RemoteOutputBuffer()
        var output = ""
        func deliver(_ text: String) {
            guard !text.isEmpty else { return }
            output += text
            onOutput(text)
        }

        do {
            while true {
                if clock.now >= deadline {
                    return try await timeOut(handle, buffer: buffer, output: output, onOutput: onOutput)
                }
                let statusScript = RemoteRunScripts.status(runId: handle.runId)
                guard let status = try await reconnecting(host: handle.host, deadline: deadline, script: statusScript)
                else {
                    return .disconnected(partialOutput: output, handle: handle)
                }
                let verdict: RemoteStatusVerdict =
                    status.exitStatus == 0 ? Self.statusVerdict(statusOutput: status.stdoutText) : .transient
                guard let drained = try await drain(handle, buffer: buffer, deadline: deadline) else {
                    return .disconnected(partialOutput: output, handle: handle)
                }
                buffer = drained.buffer
                handle.offset = buffer.offset
                deliver(drained.text)
                if case .finished(let outcome) = verdict {
                    deliver(buffer.flush())
                    Self.logger.info("Run \(handle.runId, privacy: .public) finished: \(String(describing: outcome), privacy: .public)")
                    return .finished(output: output, outcome: outcome, handle: handle)
                }
                try await Task.sleep(for: min(Self.pollInterval, max(deadline - clock.now, .zero)))
            }
        } catch where error is CancellationError || Task.isCancelled {
            // The result keeps the run id, so a stopped run's partial output reaches the model like any other.
            await cancelOutsideCallerTask(handle)
            return .finished(output: output, outcome: .cancelled, handle: handle)
        } catch {
            Self.logger.error(
                "Following run \(handle.runId, privacy: .public) on \(handle.host, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return Self.failedResult(error: error, partialOutput: output, handle: handle)
        }
    }

    /// Reads everything written since `buffer.offset`. Returns nil when the host stayed unreachable.
    private func drain(
        _ handle: RemoteRunHandle, buffer: RemoteOutputBuffer, deadline: ContinuousClock.Instant
    ) async throws -> (buffer: RemoteOutputBuffer, text: String)? {
        var buffer = buffer
        var text = ""
        while true {
            let script = RemoteRunScripts.readChunk(
                runId: handle.runId, offset: buffer.offset, maxBytes: Self.readChunkBytes)
            guard let chunk = try await reconnecting(host: handle.host, deadline: deadline, script: script) else {
                return nil
            }
            text += buffer.append(chunk.stdout)
            if chunk.stdout.count < Self.readChunkBytes { return (buffer, text) }
        }
    }

    private func timeOut(
        _ handle: RemoteRunHandle, buffer: RemoteOutputBuffer, output: String, onOutput: @Sendable (String) -> Void
    ) async throws -> RemoteExecResult {
        Self.logger.info("Run \(handle.runId, privacy: .public) on \(handle.host, privacy: .public) timed out")
        do {
            try await cancel(handle)
        } catch where Self.isTransportFailure(error) {
            Self.logger.error(
                "Cancel of run \(handle.runId, privacy: .public) lost the host: \(String(describing: error), privacy: .public)")
            return .disconnected(partialOutput: output, handle: handle)
        }
        let graceDeadline = clock.now + Self.controlExecTimeout
        guard let drained = try await drain(handle, buffer: buffer, deadline: graceDeadline) else {
            return .disconnected(partialOutput: output, handle: handle)
        }
        var buffer = drained.buffer
        let tail = drained.text + buffer.flush()
        if !tail.isEmpty { onOutput(tail) }
        var finalHandle = handle
        finalHandle.offset = buffer.offset
        return .finished(output: output + tail, outcome: .cancelled, handle: finalHandle)
    }

    /// The caller's task is already cancelled, which would cancel the cancel sequence's own execs and sleep.
    private func cancelOutsideCallerTask(_ handle: RemoteRunHandle) async {
        let cancelling = Task { try await self.cancel(handle) }
        do {
            try await cancelling.value
        } catch {
            Self.logger.error(
                "Cancel of run \(handle.runId, privacy: .public) on \(handle.host, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Execs

    func control(host: String, script: String) async throws -> ExecResult {
        let marker = Self.makeFrameMarker()
        return try await framedExec(
            host: host, transported: Self.framedTransportScript(script, marker: marker), marker: marker)
    }

    private func framedExec(host: String, transported: String, marker: String) async throws -> ExecResult {
        let raw = try await pool.exec(host: host, script: transported, timeout: Self.controlExecTimeout)
        guard let stdout = Self.unframe(raw.stdout, marker: marker) else {
            throw RemoteRunError.outputFrameMissing(
                host: host, exitStatus: raw.exitStatus,
                detail: raw.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return ExecResult(stdout: stdout, stderr: raw.stderr, exitStatus: raw.exitStatus)
    }

    /// Retries transport failures with the pool's backoff, capped by the time left. Reads and status checks
    /// are idempotent, so a retry never re-runs anything with side effects. Returns nil when retries run out.
    private func reconnecting(
        host: String, deadline: ContinuousClock.Instant, script: String
    ) async throws -> ExecResult? {
        do {
            return try await control(host: host, script: script)
        } catch where Self.isTransportFailure(error) {
            Self.logger.error("Lost \(host, privacy: .public) while following a run: \(String(describing: error), privacy: .public)")
        }
        for delay in SSHConnectionPool.backoffDelays(remaining: deadline - clock.now) {
            try await Task.sleep(for: delay)
            do {
                let result = try await control(host: host, script: script)
                Self.logger.info("Reconnected to \(host, privacy: .public)")
                return result
            } catch where Self.isTransportFailure(error) {
                Self.logger.error("Retry on \(host, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        return nil
    }

    private static func isTransportFailure(_ error: Error) -> Bool {
        switch error {
        case RemoteHostError.unreachable, RemoteExecError.timedOut: return true
        default: return false
        }
    }
}
