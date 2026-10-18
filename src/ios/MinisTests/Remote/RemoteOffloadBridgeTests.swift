import Foundation
import MinisRemote
import XCTest
@testable import Minis

/// Argument validation is covered by `RemoteCopyArgumentsTests` in the package; these cases pin the bridge's
/// error shape. Every one is decided before any network call or permission prompt.
@MainActor
final class RemoteOffloadBridgeTests: XCTestCase {
    /// Unique so a run never touches the permission of a real host named like the fixtures.
    private let host = "offload-test-\(UUID().uuidString.prefix(8))"
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteOffloadBridgeTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: RemoteAppWiring.permissionDefaultsKey(host: host))
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeWiring() throws -> RemoteAppWiring {
        let secrets = InMemorySecretStore()
        let store = try RemoteHostStore(
            fileURL: directory.appendingPathComponent("remote-hosts.json"), secrets: secrets, onHostAdded: { _ in })
        try store.add(RemoteHostConfig(
            name: host, address: "192.0.2.1", port: 22, user: "dev", keyRef: "k", pinnedHostKey: nil, os: nil))
        return RemoteAppWiring(services: .success(RemoteServices.make(store: store, secrets: secrets)))
    }

    func testCopyRejectsLocalToLocalAndRemoteToRemote() async throws {
        let wiring = try makeWiring()
        for (src, dst) in [("/h/s/workspace/a", "/h/s/workspace/b"), ("\(host):/a", "\(host):/b")] {
            let result = await RemoteOffloadBridge.copy(
                positional: [src, dst], sessionId: "s", bindingSessionId: "s", wiring: wiring)
            XCTAssertEqual(result["ok"] as? Bool, false)
            XCTAssertEqual(result["error"] as? String, "invalid_args")
        }
    }

    func testUnknownHostNamesConfiguredHosts() async throws {
        let result = await RemoteOffloadBridge.copy(
            positional: ["/h/s/workspace/a", "gone:/b"], sessionId: "s", bindingSessionId: "s", wiring: try makeWiring())
        XCTAssertEqual(result["error"] as? String, "invalid_args")
        let message = try XCTUnwrap(result["message"] as? String)
        XCTAssertTrue(message.contains(host), message)
    }

    func testPhonePathOutsideSessionFoldersIsRejectedBeforePermission() async throws {
        let escape = AIChatViewModel.minisPersistentBase.path + "/s/workspace/../../../../Library/x"
        let result = await RemoteOffloadBridge.copy(
            positional: [escape, "\(host):/b"], sessionId: "s", bindingSessionId: "s", wiring: try makeWiring())
        XCTAssertEqual(result["error"] as? String, "invalid_args")
    }

    func testHostsDoesNotProbeAnAskOnceHostWithoutAGrant() async throws {
        OffloadPermissionManager.shared.setPermissionLevel(.askOnce, for: RemoteAppWiring.permissionKey(host: host))
        let result = await RemoteOffloadBridge.hosts(bindingSessionId: "no-grant", wiring: try makeWiring())
        let entry = try XCTUnwrap((result["hosts"] as? [NSDictionary])?.first)
        XCTAssertTrue(entry["reachable"] is NSNull)
        XCTAssertEqual(entry["permission"] as? String, "ask")
    }
}
