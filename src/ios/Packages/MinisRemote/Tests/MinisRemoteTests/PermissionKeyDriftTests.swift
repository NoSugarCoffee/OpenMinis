import Foundation
import XCTest

/// RemoteAppWiring.permissionDefaultsKey rebuilds OffloadPermissionManager's private defaults key, because the
/// manager's API reads an unset key as Bypass. If upstream renames the key, every host's stored level silently
/// resets to Ask Once, so this test pins the upstream format.
final class PermissionKeyDriftTests: XCTestCase {
    private static let iosRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // MinisRemoteTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // MinisRemote
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // src/ios

    func testUpstreamPermissionDefaultsKeyFormatIsUnchanged() throws {
        let source = try String(
            contentsOf: Self.iosRoot.appendingPathComponent("Agent/Offload/OffloadPermissionManager.swift"),
            encoding: .utf8)
        let body = try XCTUnwrap(
            FileToolDriftTests.functionSource(named: "defaultsKey", in: source),
            "`func defaultsKey(` is gone from OffloadPermissionManager.swift. Find how upstream now builds the key and update RemoteAppWiring.permissionDefaultsKey to match.")
        XCTAssertTrue(
            body.contains(#""offloadPermission.\(command)""#),
            "Upstream changed the defaults key in OffloadPermissionManager.defaultsKey. Update RemoteAppWiring.permissionDefaultsKey to the same format, then this test.")
    }

    func testRemoteWiringUsesTheUpstreamKeyFormat() throws {
        let source = try String(
            contentsOf: Self.iosRoot.appendingPathComponent("Agent/Remote/RemoteAppWiring.swift"),
            encoding: .utf8)
        let body = try XCTUnwrap(FileToolDriftTests.functionSource(named: "permissionDefaultsKey", in: source))
        XCTAssertTrue(body.contains(#""offloadPermission.\("#), "RemoteAppWiring.permissionDefaultsKey no longer uses the upstream key format.")
    }
}
