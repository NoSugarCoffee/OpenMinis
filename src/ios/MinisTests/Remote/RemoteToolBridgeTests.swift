import Foundation
import MinisRemote
import XCTest
@testable import Minis

/// The app half of remote routing. Every case here is decided before any network call, so the tests need no
/// host: a call that reached the network would fail with "unreachable" instead of the asserted result.
@MainActor
final class RemoteToolBridgeTests: XCTestCase {
    /// Unique so a run never touches the permission of a real host named like the fixtures.
    private let host = "bridge-test-\(UUID().uuidString.prefix(8))"
    private let sessionId = "remote-bridge-test-session"
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteToolBridgeTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: RemoteAppWiring.permissionDefaultsKey(host: host))
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeWiring(boundTo binding: SessionHostBindingValue?) throws -> RemoteAppWiring {
        try makeWiring(boundTo: binding, os: nil)
    }

    private func makeWiring(boundTo binding: SessionHostBindingValue?, os: String?) throws -> RemoteAppWiring {
        let secrets = InMemorySecretStore()
        let store = try RemoteHostStore(
            fileURL: directory.appendingPathComponent("remote-hosts-\(UUID().uuidString).json"), secrets: secrets,
            onHostAdded: { _ in })
        try store.add(RemoteHostConfig(
            name: host, address: "192.0.2.1", port: 22, user: "dev", keyRef: "k", pinnedHostKey: nil, os: os))
        try store.setBinding(binding, sessionId: sessionId)
        return RemoteAppWiring(services: .success(RemoteServices.make(store: store, secrets: secrets)))
    }

    private func handle(
        _ toolName: String, _ argsJson: String, wiring: RemoteAppWiring
    ) async -> (output: String, success: Bool)? {
        await RemoteToolBridge.handle(
            toolName: toolName, argsJson: argsJson, sessionId: sessionId, onOutput: { _ in }, wiring: wiring)
    }

    // MARK: Result formatting

    func testResultAlwaysStartsWithRunIdAndPath() {
        let handle = RemoteRunHandle(host: host, runId: "r1", offset: 0)
        let results: [RemoteExecResult] = [
            .finished(output: "o", outcome: .exited(0), handle: handle),
            .finished(output: "o", outcome: .cancelled, handle: handle),
            .finished(output: "o", outcome: .abnormal, handle: handle),
            .detached(handle: handle),
            .disconnected(partialOutput: "o", handle: handle),
            .failed(partialOutput: "o", handle: handle, error: RemoteRunFailure(message: "lost")),
        ]
        for result in results {
            XCTAssertTrue(
                RemoteToolBridge.formatResult(result, limit: AIChatViewModel.kMaxToolResultChars)
                    .hasPrefix("run_id: r1\noutput: ~/.minis/runs/r1/out\n"),
                "\(result)")
        }
    }

    func testDisconnectedResultSaysMayStillBeRunning() {
        let text = RemoteToolBridge.formatResult(
            .disconnected(partialOutput: "half", handle: RemoteRunHandle(host: host, runId: "r2", offset: 4)),
            limit: AIChatViewModel.kMaxToolResultChars)
        XCTAssertTrue(text.contains("host disconnected; command may still be running"), text)
    }

    // MARK: System prompt

    func testSystemPromptLineFormat() {
        XCTAssertEqual(
            RemoteToolBridge.systemPromptLine(
                binding: SessionHostBindingValue(hostName: "mini", workdir: "/Users/x/code"), os: "Darwin"),
            "You are working on host `mini` (Darwin) in `/Users/x/code`.")
    }

    func testSystemPromptFragmentIsEmptyForUnboundSession() throws {
        let wiring = try makeWiring(boundTo: nil)
        XCTAssertEqual(wiring.systemPromptFragment(sessionId: sessionId), "")
    }

    func testSystemPromptFragmentUsesTheOSFromTheHostConfig() throws {
        let binding = SessionHostBindingValue(hostName: host, workdir: "~/code")
        XCTAssertEqual(
            try makeWiring(boundTo: binding, os: "Darwin").systemPromptFragment(sessionId: sessionId),
            RemoteToolOutput.systemPromptFragment(binding: binding, os: "Darwin"))
        XCTAssertTrue(
            try makeWiring(boundTo: binding, os: nil).systemPromptFragment(sessionId: sessionId)
                .contains("(OS not yet known)"))
    }

    // MARK: Tool schema

    func testSchemaAugmentAddsTargetAndDetachAfterExistingParameters() {
        let shell = AgentToolDefinition(
            name: "shell_execute", description: "d",
            parameters: ["command": AgentToolParam(type: .string, description: "c")],
            required: ["command"], propertyOrdering: ["command"])
        let other = AgentToolDefinition(
            name: "browser_use", description: "d", parameters: [:], required: [], propertyOrdering: ["action"])

        let augmented = RemoteAgentToolSchema.augment([shell, other], hostsConfigured: true, boundHost: nil)
        let withoutHosts = RemoteAgentToolSchema.augment([shell, other], hostsConfigured: false, boundHost: nil)

        XCTAssertEqual(augmented[0].propertyOrdering, ["command", "target", "detach"])
        XCTAssertEqual(augmented[0].parameters["target"]?.type, .string)
        XCTAssertEqual(augmented[0].parameters["detach"]?.type, .boolean)
        XCTAssertEqual(augmented[0].required, ["command"])
        XCTAssertEqual(augmented[1].propertyOrdering, ["action"])
        XCTAssertNil(augmented[1].parameters["target"])
        XCTAssertEqual(withoutHosts[0].propertyOrdering, ["command"])
        XCTAssertNil(withoutHosts[0].parameters["target"])
    }

    func testSchemaAugmentTellsABoundChatThatShellRunsOnTheHost() throws {
        let shell = AgentToolDefinition(
            name: "shell_execute", description: "Runs in iSH.",
            parameters: [:], required: [], propertyOrdering: ["command"])
        let read = AgentToolDefinition(
            name: "file_read", description: "Reads.", parameters: [:], required: [], propertyOrdering: ["path"])
        let binding = SessionHostBindingValue(hostName: "linux", workdir: "/home/dev/code/demo")

        let bound = RemoteAgentToolSchema.augment(
            [shell, read], hostsConfigured: true, boundHost: RemoteBoundHost(binding: binding, os: "Linux"))
        let unbound = RemoteAgentToolSchema.augment([shell, read], hostsConfigured: true, boundHost: nil)

        XCTAssertEqual(
            bound[0].description,
            "Runs in iSH. In this chat, commands do not run in iSH: they run on host `linux` (Linux) in `/home/dev/code/demo` unless `target: \"local\"` is set.")
        XCTAssertEqual(bound[1].description, "Reads.")
        XCTAssertEqual(unbound[0].description, "Runs in iSH.")
        let storedBinding = SessionHostBindingValue(hostName: host, workdir: "~/code")
        XCTAssertEqual(
            try makeWiring(boundTo: storedBinding, os: "Linux").boundHost(sessionId: sessionId),
            RemoteBoundHost(binding: storedBinding, os: "Linux"))
        XCTAssertNil(try makeWiring(boundTo: nil).boundHost(sessionId: sessionId))
    }

    // MARK: Permission sheet

    func testPermissionRowsShowTheWholeHostCommandAndTheFilePath() throws {
        let key = RemoteAppWiring.permissionKey(host: "linux")
        let command = "uname -a && pwd && git log --oneline"
        let commandRows = try XCTUnwrap(RemotePermissionRows.rows(commandName: key, fullCommand: command))
        XCTAssertEqual(commandRows.map(\.key), [RemoteHostL10n.string("Command")])
        XCTAssertEqual(commandRows.map(\.value), [command])

        let write = RemoteToolRequest.write(RemoteWriteRequest(path: "src/main.c", content: "x", append: false))
        let fileRows = try XCTUnwrap(RemotePermissionRows.rows(commandName: key, fullCommand: write.permissionSummary))
        XCTAssertEqual(fileRows.map(\.key), [RemoteHostL10n.string("Write file")])
        XCTAssertEqual(fileRows.map(\.value), ["src/main.c"])

        XCTAssertNil(RemotePermissionRows.rows(commandName: "apple-healthkit", fullCommand: "apple-healthkit query -a"))
    }

    // MARK: Stop button

    func testRegistryCancelsOnlyTheOwnersRunsAndReportsTheStop() async {
        let registry = RemoteRunRegistry()
        let owner = ObjectIdentifier(self)
        XCTAssertFalse(registry.cancelAll(owner: owner))
        let key = RemoteRunRegistry.Key(owner: owner, msgIdx: 0, blockIdx: 1)
        let run = Task<(output: String, success: Bool)?, Never> {
            try? await Task.sleep(for: .seconds(30))
            return Task.isCancelled ? ("stopped", false) : nil
        }
        registry.register(run, key: key)

        XCTAssertFalse(registry.cancelAll(owner: ObjectIdentifier(RemoteRunRegistry.shared)))
        XCTAssertTrue(registry.cancelAll(owner: owner))

        let result = await run.value
        XCTAssertEqual(result?.output, "stopped")
        XCTAssertTrue(registry.finish(key: key))
        XCTAssertFalse(registry.finish(key: key))
    }

    // MARK: Routing

    func testHandleReturnsNilForUnboundSession() async throws {
        let wiring = try makeWiring(boundTo: nil)
        let shell = await handle("shell_execute", #"{"command":"echo hi"}"#, wiring: wiring)
        XCTAssertNil(shell)
        let read = await handle("file_read", #"{"path":"notes.txt"}"#, wiring: wiring)
        XCTAssertNil(read)
    }

    func testHandleReturnsNilForDeviceCommandAndPhonePathsInBoundSession() async throws {
        let wiring = try makeWiring(boundTo: SessionHostBindingValue(hostName: host, workdir: "~/code"))
        let device = await handle("shell_execute", #"{"command":"apple-calendar list"}"#, wiring: wiring)
        XCTAssertNil(device)
        let phoneFile = await handle("file_read", #"{"path":"/var/minis/workspace/a.txt"}"#, wiring: wiring)
        XCTAssertNil(phoneFile)
        let explicitLocal = await handle("shell_execute", #"{"command":"ls","target":"local"}"#, wiring: wiring)
        XCTAssertNil(explicitLocal)
    }

    func testAnswersCallMatchesWhatHandleDoes() throws {
        let bound = try makeWiring(boundTo: SessionHostBindingValue(hostName: host, workdir: "~/code"))
        XCTAssertTrue(RemoteToolBridge.answersCall(
            toolName: "file_write", argsJson: #"{"path":"a.txt","content":"x"}"#, sessionId: sessionId, wiring: bound))
        XCTAssertFalse(RemoteToolBridge.answersCall(
            toolName: "file_write", argsJson: #"{"path":"/var/minis/workspace/a.txt","content":"x"}"#,
            sessionId: sessionId, wiring: bound))
        XCTAssertFalse(RemoteToolBridge.answersCall(
            toolName: "file_edit", argsJson: #"{"path":"a.txt"}"#, sessionId: "unbound-session", wiring: bound))
    }

    func testHandleIgnoresOtherTools() async throws {
        let wiring = try makeWiring(boundTo: SessionHostBindingValue(hostName: host, workdir: "~"))
        let result = await handle("browser_use", #"{"action":"navigate"}"#, wiring: wiring)
        XCTAssertNil(result)
    }

    func testUnknownTargetIsAnErrorNotALocalRun() async throws {
        let wiring = try makeWiring(boundTo: nil)
        let result = await handle("shell_execute", #"{"command":"ls","target":"gone"}"#, wiring: wiring)
        XCTAssertEqual(result?.success, false)
        XCTAssertEqual(
            result?.output,
            "Error: unknown target `gone`. Configured hosts: \(host). Pass one of them, or 'local' for this phone.")
    }

    func testUnreadableHostSettingsBlockTheCall() async throws {
        let wiring = RemoteAppWiring(
            services: .failure(.storeUnreadable(path: "/x/remote-hosts.json", detail: "corrupt")))
        let result = await RemoteToolBridge.handle(
            toolName: "file_write", argsJson: #"{"path":"/tmp/a","content":"x"}"#, sessionId: sessionId,
            onOutput: { _ in }, wiring: wiring)
        XCTAssertEqual(result?.success, false)
        XCTAssertTrue(result?.output.contains("/x/remote-hosts.json") == true, result?.output ?? "nil")
    }

    // MARK: Permission

    func testPermissionDeniedReturnsMessageNotLocalRun() async throws {
        OffloadPermissionManager.shared.setPermissionLevel(.notAllowed, for: RemoteAppWiring.permissionKey(host: host))
        let wiring = try makeWiring(boundTo: SessionHostBindingValue(hostName: host, workdir: "~/code"))

        let result = await handle("shell_execute", #"{"command":"rm -rf build"}"#, wiring: wiring)

        XCTAssertEqual(result?.success, false)
        XCTAssertTrue(result?.output.contains("Permission denied") == true, result?.output ?? "nil")
        XCTAssertEqual(
            result?.output,
            "Permission denied: tool calls on host `\(host)` are set to Not Allowed. To change it, open Settings → Remote Hosts → \(host).")
    }

    func testDeclinedPermissionPointsToTheHostSettings() {
        XCTAssertEqual(
            RemoteAppWiring.permissionDeniedMessage(host: "box", level: .askOnce),
            "Permission denied: the user declined tool calls on host `box` for this session, or did not answer in time. To change it, open Settings → Remote Hosts → box.")
    }

    func testUnsetHostPermissionBecomesAskOnceAndASetOneIsKept() {
        UserDefaults.standard.removeObject(forKey: RemoteAppWiring.permissionDefaultsKey(host: host))
        XCTAssertEqual(OffloadPermissionManager.shared.permissionLevel(for: RemoteAppWiring.permissionKey(host: host)), .bypass)

        RemoteAppWiring.defaultUnsetPermissionToAskOnce(host: host)
        XCTAssertEqual(OffloadPermissionManager.shared.permissionLevel(for: RemoteAppWiring.permissionKey(host: host)), .askOnce)

        OffloadPermissionManager.shared.setPermissionLevel(.bypass, for: RemoteAppWiring.permissionKey(host: host))
        RemoteAppWiring.defaultUnsetPermissionToAskOnce(host: host)
        XCTAssertEqual(OffloadPermissionManager.shared.permissionLevel(for: RemoteAppWiring.permissionKey(host: host)), .bypass)
    }

    // MARK: Redaction

    func testRemoteOutputIsRedacted() {
        let secret = "s3cr3t-value"
        let result = RemoteExecResult.finished(
            output: "token=\(secret)\n", outcome: .exited(0), handle: RemoteRunHandle(host: host, runId: "r3", offset: 0))

        let text = RemoteToolBridge.shellResultText(
            result, limit: AIChatViewModel.kMaxToolResultChars,
            redact: { EnvVarRedactor.redact($0, against: [secret]) })

        XCTAssertFalse(text.contains(secret), text)
        XCTAssertTrue(text.contains("token=\(EnvVarRedactor.mask(secret))"), text)
        XCTAssertTrue(text.hasPrefix("run_id: r3\n"), text)
    }
}
