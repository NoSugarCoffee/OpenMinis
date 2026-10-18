import XCTest
@testable import MinisRemote

final class RemoteRoutingTests: XCTestCase {
    private let bound = SessionHostBindingValue(hostName: "mini", workdir: "/home/u/repo")

    private func route(_ tool: String, _ args: [String: Any], binding: SessionHostBindingValue?,
                       hosts: [String] = ["mini"]) throws -> ToolDestination {
        try RemoteRouting.destination(toolName: tool, arguments: args, binding: binding, knownHosts: hosts)
    }

    func testExplicitLocalTargetWins() throws {
        XCTAssertEqual(try route("shell_execute", ["command": "ls", "target": "local"], binding: bound), .local)
    }

    func testExplicitHostTargetWins() throws {
        XCTAssertEqual(try route("file_read", ["path": "/var/minis/a", "target": "mini"], binding: nil),
                       .remote(hostName: "mini"))
        XCTAssertEqual(try route("shell_execute", ["command": "apple-calendar list", "target": "mini"], binding: bound),
                       .remote(hostName: "mini"))
    }

    func testUnknownTargetIsErrorListingHosts() {
        XCTAssertThrowsError(try route("shell_execute", ["command": "ls", "target": "old"], binding: bound)) {
            XCTAssertEqual($0 as? RemoteRoutingError, .unknownTarget("old", available: ["mini"]))
        }
    }

    func testDeviceCommandStaysLocal() throws {
        for command in ["apple-calendar list", "/usr/local/bin/ffmpeg -i x", "minis-sessions-cli search q",
                        "  \n apple-calendar list", "apple-calendar\tlist", "apple-calendar"] {
            XCTAssertEqual(try route("shell_execute", ["command": command], binding: bound), .local, command)
        }
    }

    func testCombinedCommandGoesRemote() throws {
        XCTAssertEqual(try route("shell_execute", ["command": "cd x && apple-calendar"], binding: bound),
                       .remote(hostName: "mini"))
    }

    func testLeadingEnvAssignmentGoesRemote() throws {
        XCTAssertEqual(try route("shell_execute", ["command": "FOO=1 apple-calendar"], binding: bound),
                       .remote(hostName: "mini"))
    }

    func testVarMinisAndMinisURLPathsStayLocal() throws {
        XCTAssertEqual(try route("file_read", ["path": "/var/minis/skills/a/SKILL.md"], binding: bound), .local)
        XCTAssertEqual(try route("file_read", ["path": "minis://workspace/a.txt"], binding: bound), .local)
    }

    func testBoundSessionGoesRemote() throws {
        XCTAssertEqual(try route("shell_execute", ["command": "ls"], binding: bound), .remote(hostName: "mini"))
        XCTAssertEqual(try route("file_write", ["path": "a.txt"], binding: bound), .remote(hostName: "mini"))
        XCTAssertEqual(try route("file_edit", ["path": "/etc/hosts"], binding: bound), .remote(hostName: "mini"))
    }

    func testUnboundSessionIsAlwaysLocal() throws {
        XCTAssertEqual(try route("shell_execute", ["command": "ls"], binding: nil), .local)
        XCTAssertEqual(try route("file_read", ["path": "a.txt"], binding: nil), .local)
    }

    func testRelativePathWithSpacesResolves() {
        XCTAssertEqual(RemoteRouting.resolveRemotePath("src/a b.swift", workdir: "/home/u/repo", home: "/home/u"),
                       "/home/u/repo/src/a b.swift")
        XCTAssertEqual(RemoteRouting.resolveRemotePath("a.txt", workdir: "/home/u/repo/", home: "/home/u"),
                       "/home/u/repo/a.txt")
    }

    func testTildeExpands() {
        XCTAssertEqual(RemoteRouting.resolveRemotePath("~", workdir: "/w", home: "/home/u"), "/home/u")
        XCTAssertEqual(RemoteRouting.resolveRemotePath("~/x y", workdir: "/w", home: "/home/u"), "/home/u/x y")
        XCTAssertEqual(RemoteRouting.resolveRemotePath("~/x", workdir: "/w", home: "/home/u/"), "/home/u/x")
    }

    func testOtherUsersTildeIsLeftUnchanged() {
        XCTAssertEqual(RemoteRouting.resolveRemotePath("~bob/x", workdir: "/w", home: "/home/u"), "/w/~bob/x")
    }

    func testAbsolutePathUnchanged() {
        XCTAssertEqual(RemoteRouting.resolveRemotePath("/etc/hosts", workdir: "/w", home: "/home/u"), "/etc/hosts")
    }

    func testLocalDeviceCommandsMatchRegisteredHandlers() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pattern = try NSRegularExpression(pattern: #"native_offload_add_handler\("([^"]+)""#)
        var registered: Set<String> = []
        for dir in ["NativeOffloads", "iSH"] {
            let root = iosRoot.appendingPathComponent(dir)
            let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let file as URL in files where file.pathExtension == "m" {
                let text = try String(contentsOf: file, encoding: .utf8)
                for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    registered.insert(String(text[Range(match.range(at: 1), in: text)!]))
                }
            }
        }
        XCTAssertGreaterThan(registered.count, 20, "handler scan found too few files; check source root")
        XCTAssertEqual(registered, RemoteRouting.localDeviceCommands)
    }
}
