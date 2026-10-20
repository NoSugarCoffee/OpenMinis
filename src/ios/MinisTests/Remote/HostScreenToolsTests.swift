import Foundation
import MinisRemote
import XCTest
@testable import Minis

/// Every case here is decided before the screen connects, so no host is needed.
@MainActor
final class HostScreenToolsTests: XCTestCase {
    private let host = "screen-test-\(UUID().uuidString.prefix(8))"
    private let sessionId = "host-screen-test-session"
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HostScreenToolsTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        HostScreenSessions.shared.existingSession(host: host)?.userControlling = false
        UserDefaults.standard.removeObject(forKey: RemoteAppWiring.permissionDefaultsKey(host: host))
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeWiring(bound: Bool) throws -> RemoteAppWiring {
        let secrets = InMemorySecretStore()
        let store = try RemoteHostStore(
            fileURL: directory.appendingPathComponent("remote-hosts.json"), secrets: secrets, onHostAdded: { _ in })
        try store.add(RemoteHostConfig(
            name: host, address: "192.0.2.1", port: 22, user: "dev", keyRef: "k", pinnedHostKey: nil, os: "Darwin"))
        if bound {
            try store.setBinding(SessionHostBindingValue(hostName: host, workdir: "/Users/dev"), sessionId: sessionId)
        }
        return RemoteAppWiring(services: .success(RemoteServices.make(store: store, secrets: secrets)))
    }

    private func run(_ toolName: String, _ arguments: [String: Any], wiring: RemoteAppWiring) async -> (output: String, success: Bool)? {
        await HostScreenTools.run(
            toolName: toolName, arguments: arguments, bindingSessionId: sessionId, ownSessionId: sessionId,
            wiring: wiring)
    }

    func testToolsAreOfferedOnlyToBoundSessions() throws {
        XCTAssertTrue(HostScreenTools.definitions(boundHost: nil).isEmpty)
        let bound = RemoteBoundHost(binding: SessionHostBindingValue(hostName: host, workdir: "/"), os: "Darwin")
        let tools = HostScreenTools.definitions(boundHost: bound)
        XCTAssertEqual(tools.map(\.name), [ScreenToolLogic.captureToolName, ScreenToolLogic.inputToolName])
        XCTAssertEqual(tools[1].required, ["tool_title", "actions"])
        XCTAssertNotNil(tools[1].parameters["capture_after"])
    }

    func testOtherToolsAreNotAnswered() async throws {
        let result = await run("shell_execute", [:], wiring: try makeWiring(bound: true))
        XCTAssertNil(result)
    }

    func testUnboundSessionIsRefused() async throws {
        let result = await run(ScreenToolLogic.captureToolName, [:], wiring: try makeWiring(bound: false))
        XCTAssertEqual(result?.success, false)
        XCTAssertTrue(result?.output.contains("bound to a host") == true, result?.output ?? "")
    }

    func testUserControlPausesTheAgent() async throws {
        let wiring = try makeWiring(bound: true)
        HostScreenSessions.shared.session(host: host).userControlling = true
        for tool in ScreenToolLogic.toolNames {
            let result = await run(tool, ["actions": "[]"], wiring: wiring)
            XCTAssertEqual(result?.output, ScreenToolLogic.userControllingReply(host: host))
            XCTAssertEqual(result?.success, false)
        }
    }

    func testBadActionsAreRefusedBeforeConnecting() async throws {
        let result = await run(
            ScreenToolLogic.inputToolName, ["actions": [["action": "fly"]]], wiring: try makeWiring(bound: true))
        XCTAssertEqual(result?.success, false)
        XCTAssertTrue(result?.output.hasPrefix("Error: ") == true, result?.output ?? "")
    }
}
