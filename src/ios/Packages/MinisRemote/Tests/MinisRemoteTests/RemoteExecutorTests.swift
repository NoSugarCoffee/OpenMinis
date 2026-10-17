import Crypto
import Foundation
import XCTest
@testable import MinisRemote

private final class OutputLog: @unchecked Sendable {
    private let lock = NSLock()
    private var pieces: [String] = []

    var joined: String { lock.withLock { pieces.joined() } }

    func append(_ piece: String) { lock.withLock { pieces.append(piece) } }
}

/// Lets a test delete the host mid-run, as a rename or removal in Settings would.
private final class RemovableHostDirectory: RemoteHostDirectory, @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [RemoteHostConfig]
    private let key: Curve25519.Signing.PrivateKey

    init(hosts: [RemoteHostConfig], key: Curve25519.Signing.PrivateKey) {
        self.hosts = hosts
        self.key = key
    }

    func remove(named name: String) { lock.withLock { hosts.removeAll { $0.name == name } } }

    func config(named name: String) async -> RemoteHostConfig? {
        lock.withLock { hosts.first { $0.name == name } }
    }

    func privateKey(for config: RemoteHostConfig) async throws -> Curve25519.Signing.PrivateKey {
        key
    }
}

private func runShell(_ shell: String, _ command: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-c", command]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, "\(shell) exited \(process.terminationStatus)")
    return String(decoding: data, as: UTF8.self)
}

final class RemoteExecutorTests: XCTestCase {
    // MARK: Transport wrapper

    func testTransportScriptIsBase64PipedIntoSh() {
        XCTAssertEqual(
            RemoteExecutor.transportScript("echo hi\n"),
            "printf '%s' ZWNobyBoaQo= | /bin/sh -c 'base64 -d 2>/dev/null || base64 -D' | /bin/sh")
    }

    func testTransportScriptDeliversScriptByteForByteInPosixShells() throws {
        let payload = "a'b\"c $HOME `id` \\n \\\\ tab\there\nzweite Zeile ü 漢字 🚀"
        let script = "cat <<'MINIS_EOF'\n\(payload)\nMINIS_EOF\n"
        for shell in ["/bin/sh", "/bin/bash", "/bin/zsh"] {
            XCTAssertEqual(try runShell(shell, RemoteExecutor.transportScript(script)), payload + "\n", shell)
        }
    }

    // MARK: Output framing

    func testFramedScriptPrintsMarkerBeforeTheScript() throws {
        let framed = RemoteExecutor.framedTransportScript("echo body\n", marker: "__M__")
        XCTAssertEqual(try runShell("/bin/sh", "echo login-noise; " + framed), "login-noise\n\n__M__\nbody\n")
    }

    func testUnframeDropsEverythingThroughTheMarker() {
        XCTAssertEqual(
            RemoteExecutor.unframe(Array("noise\n__M__ text\n\n__M__\nrunning 1\n".utf8), marker: "__M__"),
            Array("running 1\n".utf8))
        XCTAssertEqual(RemoteExecutor.unframe(Array("\n__M__\n".utf8), marker: "__M__"), [])
    }

    func testMissingFrameIsNotData() {
        XCTAssertNil(RemoteExecutor.unframe([], marker: "__M__"))
        XCTAssertNil(RemoteExecutor.unframe(Array("running 1\n".utf8), marker: "__M__"))
    }

    func testFrameMarkersAreUnique() {
        XCTAssertNotEqual(RemoteExecutor.makeFrameMarker(), RemoteExecutor.makeFrameMarker())
    }

    // MARK: Launcher exits

    func testConfirmedLaunchIsNotAnError() {
        XCTAssertNil(
            RemoteExecutor.launchError(
                exitStatus: 0, stdout: "minis-launched\n", stderr: "", workdir: "/w", host: "mini"))
    }

    func testUnconfirmedLaunchIsAnError() {
        XCTAssertEqual(
            RemoteExecutor.launchError(exitStatus: 0, stdout: "", stderr: "base64: invalid\n", workdir: "/w", host: "mini"),
            .launchNotConfirmed(host: "mini", detail: "base64: invalid"))
    }

    func testLauncherExitsMapToDistinctErrors() {
        XCTAssertEqual(
            RemoteExecutor.launchError(exitStatus: 96, stdout: "", stderr: "mkdir: denied\n", workdir: "/w", host: "mini"),
            .runDirectoryUnavailable(host: "mini", detail: "mkdir: denied"))
        XCTAssertEqual(
            RemoteExecutor.launchError(exitStatus: 97, stdout: "", stderr: "cd: no such file\n", workdir: "/w x", host: "mini"),
            .workingDirectoryNotFound(path: "/w x", host: "mini"))
        XCTAssertEqual(
            RemoteExecutor.launchError(
                exitStatus: 98, stdout: "", stderr: "minis: cannot decode command\n", workdir: "/w", host: "mini"),
            .commandDecodeFailed(host: "mini"))
        XCTAssertEqual(
            RemoteExecutor.launchError(exitStatus: 127, stdout: "", stderr: "sh: nohup: not found\n", workdir: "/w", host: "mini"),
            .launchFailed(host: "mini", exitStatus: 127, detail: "sh: nohup: not found"))
    }

    // MARK: Launch with an unknown outcome

    func testLaunchOutcomeIsUnknownOnlyForCancellationAndTransportFailures() {
        XCTAssertTrue(RemoteExecutor.isLaunchOutcomeUnknown(CancellationError()))
        XCTAssertTrue(RemoteExecutor.isLaunchOutcomeUnknown(RemoteHostError.unreachable(host: "mini")))
        XCTAssertTrue(RemoteExecutor.isLaunchOutcomeUnknown(RemoteExecError.timedOut(host: "mini", after: .seconds(10))))
        XCTAssertFalse(RemoteExecutor.isLaunchOutcomeUnknown(RemoteHostError.authFailed(host: "mini")))
        XCTAssertFalse(RemoteExecutor.isLaunchOutcomeUnknown(RemoteRunError.commandDecodeFailed(host: "mini")))
    }

    func testLaunchProbeVerdicts() {
        XCTAssertEqual(
            RemoteExecutor.launchProbeVerdict(ExecResult(stdout: Array("launched\n".utf8), stderr: [], exitStatus: 0)),
            .launched)
        XCTAssertEqual(
            RemoteExecutor.launchProbeVerdict(ExecResult(stdout: Array("claimed\n".utf8), stderr: [], exitStatus: 0)),
            .claimed)
        XCTAssertNil(RemoteExecutor.launchProbeVerdict(ExecResult(stdout: [], stderr: [], exitStatus: 0)))
        XCTAssertNil(
            RemoteExecutor.launchProbeVerdict(ExecResult(stdout: Array("claimed\n".utf8), stderr: [], exitStatus: 1)))
    }

    // MARK: Launch size

    func testCommandWithinBoundIsAccepted() throws {
        let transported = try RemoteExecutor.launchTransportScript(
            runId: RemoteExecutor.makeRunId(), workdir: "/w", command: String(repeating: "a", count: 50_000),
            marker: RemoteExecutor.makeFrameMarker())
        XCTAssertLessThanOrEqual(transported.utf8.count, RemoteExecutor.maxTransportedScriptBytes)
    }

    func testOversizedCommandIsRefusedWithFileWriteAdvice() {
        XCTAssertThrowsError(
            try RemoteExecutor.launchTransportScript(
                runId: RemoteExecutor.makeRunId(), workdir: "/w", command: String(repeating: "a", count: 60_000),
                marker: RemoteExecutor.makeFrameMarker())
        ) { error in
            guard case .commandTooLarge(let encodedBytes, let limit) = error as? RemoteRunError else {
                return XCTFail("Expected commandTooLarge, got \(error)")
            }
            XCTAssertGreaterThan(encodedBytes, limit)
            XCTAssertEqual(limit, 100_000)
            XCTAssertTrue((error as? RemoteRunError)?.userMessage.contains("file_write") == true)
        }
    }

    // MARK: Failures after launch

    func testFailureAfterLaunchKeepsHandleAndOutput() {
        let handle = RemoteRunHandle(host: "mini", runId: "abc", offset: 6)
        let result = RemoteExecutor.failedResult(
            error: RemoteHostError.notConfigured(host: "mini"), partialOutput: "first\n", handle: handle)
        guard case .failed(let partialOutput, let kept, let error) = result else {
            return XCTFail("Expected .failed, got \(result)")
        }
        XCTAssertEqual(partialOutput, "first\n")
        XCTAssertEqual(kept.runId, "abc")
        XCTAssertEqual(kept.offset, 6)
        XCTAssertEqual(error.message, RemoteHostError.notConfigured(host: "mini").userMessage)
    }

    func testUnknownFailureKeepsItsDescription() {
        struct Odd: Error {}
        let result = RemoteExecutor.failedResult(
            error: Odd(), partialOutput: "", handle: RemoteRunHandle(host: "mini", runId: "abc", offset: 0))
        guard case .failed(_, _, let error) = result else { return XCTFail("Expected .failed, got \(result)") }
        XCTAssertTrue(error.message.contains("Odd"), error.message)
    }

    func testWorkingDirectoryNotFoundUsesSpecWording() {
        XCTAssertTrue(
            RemoteRunError.workingDirectoryNotFound(path: "/srv/app", host: "mini").userMessage
                .hasPrefix("working directory `/srv/app` not found on `mini`"))
    }

    // MARK: Status

    func testStatusVerdicts() {
        XCTAssertEqual(RemoteExecutor.statusVerdict(statusOutput: "running 1\n"), .running)
        XCTAssertEqual(RemoteExecutor.statusVerdict(statusOutput: "running 0\n"), .finished(.abnormal))
        XCTAssertEqual(RemoteExecutor.statusVerdict(statusOutput: "4\n"), .finished(.exited(4)))
        XCTAssertEqual(RemoteExecutor.statusVerdict(statusOutput: "cancelled"), .finished(.cancelled))
    }

    func testEmptyOrGarbledStatusIsTransient() {
        XCTAssertEqual(RemoteExecutor.statusVerdict(statusOutput: ""), .transient)
        XCTAssertEqual(RemoteExecutor.statusVerdict(statusOutput: "runn"), .transient)
    }

    // MARK: Run ids

    func testRunIdIsTwelveLowercaseCharacters() {
        let ids = (0..<20).map { _ in RemoteExecutor.makeRunId() }
        for id in ids {
            XCTAssertEqual(id.count, 12)
            XCTAssertNil(id.range(of: "[^a-z0-9-]", options: .regularExpression), id)
        }
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testHandleNamesOutputPath() {
        XCTAssertEqual(RemoteRunHandle(host: "mini", runId: "abc", offset: 0).outputPath, "~/.minis/runs/abc/out")
    }

    // MARK: Against the fixture (opt-in)

    private func makeExecutor() async throws -> (RemoteExecutor, SSHConnectionPool) {
        let fixture = try SSHFixture.fromEnvironment()
        return try await makeExecutor(
            pool: fixture.pool(pinnedHostKey: try await fixture.pinnedHostKeyLine(), key: fixture.key))
    }

    private func makeExecutor(pool: SSHConnectionPool) async throws -> (RemoteExecutor, SSHConnectionPool) {
        _ = try await execRetryingFixtureRace(pool, script: "true")
        return (RemoteExecutor(pool: pool), pool)
    }

    func testForgetHomeMakesTheNextLookupReadHomeAgain() async throws {
        let (executor, _) = try await makeExecutor()
        let home = try await executor.homeDirectory(host: "mini")
        let cachedBefore = await executor.cachedHomeHostNames
        await executor.forgetHome(host: "mini")
        let cachedAfterForget = await executor.cachedHomeHostNames
        let reread = try await executor.homeDirectory(host: "mini")

        XCTAssertEqual(home, "/home/dev")
        XCTAssertEqual(cachedBefore, ["mini"])
        XCTAssertEqual(cachedAfterForget, [])
        XCTAssertEqual(reread, home)
    }

    func testRunReturnsOutputAndExitCode() async throws {
        let (executor, _) = try await makeExecutor()
        let log = OutputLog()
        let result = try await executor.run(
            host: "mini", workdir: "~", command: "echo a; exit 4", timeout: .seconds(30), detach: false,
            onOutput: { log.append($0) })
        guard case .finished(let output, let outcome, let handle) = result else {
            return XCTFail("Expected .finished, got \(result)")
        }
        XCTAssertEqual(output, "a\n")
        XCTAssertEqual(outcome, .exited(4))
        XCTAssertEqual(handle.offset, 2)
        XCTAssertEqual(log.joined, "a\n")
    }

    func testDetachReturnsImmediately() async throws {
        let (executor, pool) = try await makeExecutor()
        let started = ContinuousClock.now
        let result = try await executor.run(
            host: "mini", workdir: "~", command: "sleep 5", timeout: .seconds(30), detach: true,
            onOutput: { _ in })
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        guard case .detached(let handle) = result else {
            return XCTFail("Expected .detached, got \(result)")
        }
        let status = try await pool.exec(
            host: "mini", script: RemoteRunScripts.status(runId: handle.runId), timeout: .seconds(10))
        XCTAssertEqual(status.stdoutText, "running 1\n")
    }

    func testCallerCancellationReturnsHandleAndPartialOutput() async throws {
        let (executor, pool) = try await makeExecutor()
        let streamed = OutputLog()
        let run = Task {
            try await executor.run(
                host: "mini", workdir: "~", command: "echo started; sleep 300", timeout: .seconds(60),
                detach: false, onOutput: { streamed.append($0) })
        }
        let deadline = ContinuousClock.now + .seconds(20)
        while !streamed.joined.contains("started"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        run.cancel()
        let result = try await run.value

        guard case .finished(let output, let outcome, let handle) = result else {
            return XCTFail("Expected .finished, got \(result)")
        }
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(output.contains("started"), output)
        let exitFile = try await pool.exec(
            host: "mini", script: "cat ~/.minis/runs/\(handle.runId)/exit", timeout: .seconds(10))
        XCTAssertEqual(exitFile.stdoutText, "cancelled")
    }

    func testTimeoutCancelsTree() async throws {
        let (executor, pool) = try await makeExecutor()
        let result = try await executor.run(
            host: "mini", workdir: "~", command: "sleep 300 & sleep 300 & wait", timeout: .seconds(2),
            detach: false, onOutput: { _ in })
        guard case .finished(_, let outcome, let handle) = result else {
            return XCTFail("Expected .finished, got \(result)")
        }
        XCTAssertEqual(outcome, .cancelled)
        let exitFile = try await pool.exec(
            host: "mini", script: "cat ~/.minis/runs/\(handle.runId)/exit", timeout: .seconds(10))
        XCTAssertEqual(exitFile.stdoutText, "cancelled")
        let tree = try await pool.exec(
            host: "mini", script: "cat ~/.minis/runs/\(handle.runId)/tree", timeout: .seconds(10))
        let treePids = Set(tree.stdoutText.split(whereSeparator: \.isWhitespace))
        XCTAssertGreaterThanOrEqual(treePids.count, 3, "root shell and both sleeps: \(tree.stdoutText)")
        // Scoped to this run's tree so `sleep 300` left by another test cannot fail or mask this one.
        let processes = try await pool.exec(host: "mini", script: "ps -o pid,args", timeout: .seconds(10))
        let survivors = processes.stdoutText.split(separator: "\n").filter { line in
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            return fields.count == 2 && treePids.contains(fields[0]) && fields[1].contains("sleep 300")
        }
        XCTAssertEqual(survivors, [], processes.stdoutText)
    }

    func testResumeAfterDropReadsFromOffset() async throws {
        let fixture = try SSHFixture.fromEnvironment()
        let (executor, pool) = try await makeExecutor(
            pool: SSHConnectionPool(
                directory: FixedHostDirectory(
                    hosts: [fixture.config(pinnedHostKey: try await fixture.pinnedHostKeyLine())], key: fixture.key),
                connectTimeout: .seconds(2)))
        let log = OutputLog()
        // Invalidating alone is healed by the pool's lazy reconnect on the next poll. Pausing the container for
        // longer than the connect timeout makes that reconnect fail, so the run has to go through the backoff.
        let dropper = Task {
            try await Task.sleep(for: .milliseconds(2500))
            await pool.invalidate(host: "mini")
            try runTool("/usr/bin/env", ["docker", "pause", "minis-sshtest"])
            defer { _ = try? runTool("/usr/bin/env", ["docker", "unpause", "minis-sshtest"]) }
            try await Task.sleep(for: .seconds(4))
        }
        let result = try await executor.run(
            host: "mini", workdir: "~",
            command: "i=1; while [ $i -le 5 ]; do echo tick$i; i=$((i+1)); sleep 1; done",
            timeout: .seconds(60), detach: false, onOutput: { log.append($0) })
        try await dropper.value
        let expected = "tick1\ntick2\ntick3\ntick4\ntick5\n"
        guard case .finished(let output, let outcome, _) = result else {
            return XCTFail("Expected .finished, got \(result)")
        }
        XCTAssertEqual(outcome, .exited(0))
        XCTAssertEqual(output, expected)
        XCTAssertEqual(log.joined, expected)
    }

    func testWorkdirMissingMapsToError() async throws {
        let (executor, _) = try await makeExecutor()
        do {
            let result = try await executor.run(
                host: "mini", workdir: "/nonexistent/minis dir", command: "true", timeout: .seconds(30),
                detach: false, onOutput: { _ in })
            XCTFail("Expected an error, got \(result)")
        } catch let error as RemoteRunError {
            XCTAssertEqual(error, .workingDirectoryNotFound(path: "/nonexistent/minis dir", host: "mini"))
            XCTAssertTrue(error.userMessage.contains("working directory"), error.userMessage)
        }
    }

    func testHostRemovedMidRunKeepsHandleAndOutput() async throws {
        let fixture = try SSHFixture.fromEnvironment()
        let pinned = try await fixture.pinnedHostKeyLine()
        let directory = RemovableHostDirectory(hosts: [fixture.config(pinnedHostKey: pinned)], key: fixture.key)
        let pool = SSHConnectionPool(directory: directory, connectTimeout: .seconds(10))
        let (executor, _) = try await makeExecutor(pool: pool)
        let log = OutputLog()
        let remover = Task {
            try await Task.sleep(for: .milliseconds(2500))
            directory.remove(named: "mini")
            await pool.invalidate(host: "mini")
        }
        let result = try await executor.run(
            host: "mini", workdir: "~", command: "echo first; sleep 30", timeout: .seconds(60), detach: false,
            onOutput: { log.append($0) })
        try await remover.value
        guard case .failed(let partialOutput, let handle, let error) = result else {
            return XCTFail("Expected .failed, got \(result)")
        }
        addTeardownBlock {
            let cleanup = fixture.pool(pinnedHostKey: pinned, key: fixture.key)
            _ = try await cleanup.exec(
                host: "mini", script: RemoteRunScripts.cancelTree(runId: handle.runId, signal: "KILL"),
                timeout: .seconds(10))
        }
        XCTAssertEqual(partialOutput, "first\n")
        XCTAssertEqual(log.joined, "first\n")
        XCTAssertEqual(handle.offset, 6)
        XCTAssertEqual(handle.runId.count, 12)
        XCTAssertEqual(error.message, RemoteHostError.notConfigured(host: "mini").userMessage)
    }

    // MARK: Launch with an unknown outcome (fixture)

    private func runDirectories(_ pool: SSHConnectionPool) async throws -> Set<String> {
        let listing = try await pool.exec(
            host: "mini", script: "ls -1 ~/.minis/runs 2>/dev/null; true", timeout: .seconds(10))
        return Set(listing.stdoutText.split(separator: "\n").map(String.init))
    }

    /// Before the fix the launch exec was sent once the slow connect finished, although the caller had already
    /// stopped: the command ran while the tool reported it cancelled.
    func testStopDuringASlowConnectStartsNothing() async throws {
        let fixture = try SSHFixture.fromEnvironment()
        let (executor, pool) = try await makeExecutor(
            pool: SSHConnectionPool(
                directory: FixedHostDirectory(
                    hosts: [fixture.config(pinnedHostKey: try await fixture.pinnedHostKeyLine())], key: fixture.key),
                connectTimeout: .seconds(10)))
        let before = try await runDirectories(pool)
        await pool.invalidate(host: "mini")
        try runTool("/usr/bin/env", ["docker", "pause", "minis-sshtest"])
        let run = Task {
            try await executor.run(
                host: "mini", workdir: "/tmp", command: "echo ran", timeout: .seconds(30), detach: false,
                onOutput: { _ in })
        }
        try await Task.sleep(for: .milliseconds(500))
        run.cancel()
        try await Task.sleep(for: .milliseconds(500))
        try runTool("/usr/bin/env", ["docker", "unpause", "minis-sshtest"])
        let outcome = await run.result
        try await Task.sleep(for: .seconds(1))
        let after = try await runDirectories(pool)

        switch outcome {
        case .success(let result):
            XCTFail("Expected CancellationError, got \(result)")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(after.subtracting(before), [], "a stopped call must not start the command")
    }

    private func launchDirectly(
        _ pool: SSHConnectionPool, runId: String, command: String
    ) async throws -> RemoteRunHandle {
        let launch = try await pool.exec(
            host: "mini",
            script: RemoteRunScripts.launch(
                runId: runId, workdir: "/tmp", commandBase64: Data(command.utf8).base64EncodedString()),
            timeout: .seconds(10))
        XCTAssertEqual(launch.exitStatus, 0, launch.stderrText)
        return RemoteRunHandle(host: "mini", runId: runId, offset: 0)
    }

    /// The launch reached the host but its reply was lost: the run is followed like any other, not reported as
    /// "nothing ran", which would invite a second run.
    func testLaunchWhoseReplyWasLostIsFollowed() async throws {
        let (executor, pool) = try await makeExecutor()
        let handle = try await launchDirectly(pool, runId: RemoteExecutor.makeRunId(), command: "echo hi; exit 3")
        let log = OutputLog()

        let result = try await executor.recoverUnconfirmedLaunch(
            handle, cause: RemoteHostError.unreachable(host: "mini"), deadline: .now + .seconds(30), detach: false,
            onOutput: { log.append($0) })

        guard case .finished(let output, let outcome, let kept) = result else {
            return XCTFail("Expected .finished, got \(result)")
        }
        XCTAssertEqual(kept.runId, handle.runId)
        XCTAssertEqual(output, "hi\n")
        XCTAssertEqual(outcome, .exited(3))
        XCTAssertEqual(log.joined, "hi\n")
    }

    func testDetachedLaunchWhoseReplyWasLostReturnsTheHandle() async throws {
        let (executor, pool) = try await makeExecutor()
        let handle = try await launchDirectly(pool, runId: RemoteExecutor.makeRunId(), command: "sleep 3")

        let result = try await executor.recoverUnconfirmedLaunch(
            handle, cause: RemoteExecError.timedOut(host: "mini", after: .seconds(10)), deadline: .now + .seconds(30),
            detach: true, onOutput: { _ in })

        guard case .detached(let kept) = result else { return XCTFail("Expected .detached, got \(result)") }
        XCTAssertEqual(kept.runId, handle.runId)
    }

    func testLaunchThatNeverReachedTheHostIsClaimedSoALateLaunchCannotStart() async throws {
        let (executor, pool) = try await makeExecutor()
        let runId = RemoteExecutor.makeRunId()
        let handle = RemoteRunHandle(host: "mini", runId: runId, offset: 0)

        do {
            let result = try await executor.recoverUnconfirmedLaunch(
                handle, cause: RemoteHostError.unreachable(host: "mini"), deadline: .now + .seconds(30),
                detach: false, onOutput: { _ in })
            XCTFail("Expected the launch error, got \(result)")
        } catch let error as RemoteHostError {
            XCTAssertEqual(error, .unreachable(host: "mini"))
        }
        let lateLaunch = try await pool.exec(
            host: "mini",
            script: RemoteRunScripts.launch(
                runId: runId, workdir: "/tmp", commandBase64: Data("echo late".utf8).base64EncodedString()),
            timeout: .seconds(10))
        XCTAssertEqual(lateLaunch.exitStatus, 95)
    }

    func testStopDuringAnUnconfirmedLaunchCancelsTheRunOnTheHost() async throws {
        let (executor, pool) = try await makeExecutor()
        let handle = try await launchDirectly(pool, runId: RemoteExecutor.makeRunId(), command: "sleep 300")

        let stopped = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await executor.recoverUnconfirmedLaunch(
                handle, cause: CancellationError(), deadline: .now + .seconds(30), detach: false, onOutput: { _ in })
        }
        let result = try await stopped.value

        guard case .finished(_, let outcome, let kept) = result else {
            return XCTFail("Expected .finished, got \(result)")
        }
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(kept.runId, handle.runId)
        let exitFile = try await pool.exec(
            host: "mini", script: "cat ~/.minis/runs/\(handle.runId)/exit", timeout: .seconds(10))
        XCTAssertEqual(exitFile.stdoutText, "cancelled")
    }

    /// sshd prints `~/.ssh/rc` output before every exec's own output, like a chatty `.bashrc` on hosts whose
    /// bash sources it for SSH commands (Alpine's bash does not, so the fixture uses `~/.ssh/rc`).
    func testLoginNoiseDoesNotLeakIntoOutputOrOffsets() async throws {
        let (executor, _) = try await makeExecutor()
        try runTool("/usr/bin/env", ["docker", "exec", "-u", "dev", "minis-sshtest", "sh", "-c", "echo 'echo banner-noise' > ~/.ssh/rc"])
        addTeardownBlock {
            try runTool("/usr/bin/env", ["docker", "exec", "-u", "dev", "minis-sshtest", "rm", "-f", "/home/dev/.ssh/rc"])
        }
        let log = OutputLog()
        let result = try await executor.run(
            host: "mini", workdir: "~", command: "printf 'out1\\n'; sleep 2; printf 'out2\\n'; exit 3",
            timeout: .seconds(30), detach: false, onOutput: { log.append($0) })
        guard case .finished(let output, let outcome, let handle) = result else {
            return XCTFail("Expected .finished, got \(result)")
        }
        XCTAssertEqual(output, "out1\nout2\n")
        XCTAssertEqual(log.joined, "out1\nout2\n")
        XCTAssertEqual(outcome, .exited(3))
        XCTAssertEqual(handle.offset, 10)
    }
}
