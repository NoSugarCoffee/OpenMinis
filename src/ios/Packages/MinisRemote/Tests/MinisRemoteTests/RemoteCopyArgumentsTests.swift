import XCTest
@testable import MinisRemote

final class RemoteCopyArgumentsTests: XCTestCase {
    func testParseEndpoint() throws {
        XCTAssertEqual(try RemoteCopyArguments.parseEndpoint("mini:~/a"), .remote(host: "mini", path: "~/a"))
        XCTAssertEqual(try RemoteCopyArguments.parseEndpoint("mini:rel/b"), .remote(host: "mini", path: "rel/b"))
        XCTAssertEqual(try RemoteCopyArguments.parseEndpoint("/h/s/workspace/x"), .local("/h/s/workspace/x"))
        XCTAssertThrowsError(try RemoteCopyArguments.parseEndpoint("C:/x")) {
            XCTAssertEqual($0 as? RemoteCopyArgumentError, .invalidEndpoint("C:/x", reason: .driveLetter))
        }
    }

    func testParseEndpointRejectsMalformedEndpoints() {
        for bad in ["relative.txt", "mini:", ":/x", "a b:/x"] {
            XCTAssertThrowsError(try RemoteCopyArguments.parseEndpoint(bad), bad)
        }
    }

    func testCopyRejectsLocalToLocalAndRemoteToRemote() {
        let hosts = ["mini", "box"]
        XCTAssertThrowsError(try RemoteCopyArguments.plan(src: "/h/s/workspace/a", dst: "/h/s/workspace/b", knownHosts: hosts)) {
            XCTAssertEqual($0 as? RemoteCopyArgumentError, .needsOneHost(reason: .bothLocal))
        }
        XCTAssertThrowsError(try RemoteCopyArguments.plan(src: "mini:/a", dst: "box:/b", knownHosts: hosts)) {
            XCTAssertEqual($0 as? RemoteCopyArgumentError, .needsOneHost(reason: .bothRemote))
        }
    }

    func testUnknownHostError() {
        XCTAssertThrowsError(try RemoteCopyArguments.plan(src: "/h/s/workspace/a", dst: "nope:/b", knownHosts: ["mini"])) {
            XCTAssertEqual($0 as? RemoteRoutingError, .unknownTarget("nope", available: ["mini"]))
        }
    }

    func testPlanUploadAndDownload() throws {
        let up = try RemoteCopyArguments.plan(src: "/h/s/workspace/a", dst: "mini:~/b", knownHosts: ["mini"])
        XCTAssertEqual(up, RemoteCopyPlan(host: "mini", localHostPath: "/h/s/workspace/a", remotePath: "~/b", direction: .upload))
        let down = try RemoteCopyArguments.plan(src: "mini:/b", dst: "/h/s/workspace/a", knownHosts: ["mini"])
        XCTAssertEqual(down, RemoteCopyPlan(host: "mini", localHostPath: "/h/s/workspace/a", remotePath: "/b", direction: .download))
    }

    func testCommandLineTakesTwoPathsBecauseSubcommandIsAlreadyDropped() throws {
        let parsed = try RemoteCopyArguments.parseCommandLine(positional: ["/h/a", "mini:~/b"])
        XCTAssertEqual(parsed.src, "/h/a")
        XCTAssertEqual(parsed.dst, "mini:~/b")
        for wrong in [[], ["/h/a"], ["cp", "/h/a", "mini:~/b"]] {
            XCTAssertThrowsError(try RemoteCopyArguments.parseCommandLine(positional: wrong)) {
                XCTAssertEqual($0 as? RemoteCopyArgumentError, .wrongArgumentCount(wrong.count))
            }
        }
    }

    func testProbeBoundsSlowHostsAndRunsConcurrently() async {
        let started = ContinuousClock.now
        let result = await RemoteReachability.probe(
            hosts: ["fast", "down", "hang1", "hang2"], budget: .milliseconds(300)
        ) { host in
            switch host {
            case "fast": return true
            case "down": return false
            default:
                try? await Task.sleep(for: .seconds(30))
                return true
            }
        }
        XCTAssertEqual(result, ["fast": true, "down": false, "hang1": false, "hang2": false])
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
    }
}

final class RemoteLocalPathGuardTests: XCTestCase {
    private var base: URL!
    private var roots: [RemoteCopyRoot]!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("guard-\(UUID().uuidString)")
        let workspace = base.appendingPathComponent("sid1/workspace")
        let shared = base.appendingPathComponent("shared")
        for dir in [workspace, shared, base.appendingPathComponent("secret")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        roots = [
            RemoteCopyRoot(guestPrefix: "/var/minis/workspace", hostPath: workspace.path),
            RemoteCopyRoot(guestPrefix: "/var/minis/shared", hostPath: shared.path),
        ]
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testHostPathInsideBucketMapsBackToGuestForm() throws {
        let contained = try RemoteLocalPathGuard.contain(
            hostPath: base.path + "/sid1/workspace/out/report.pdf", roots: roots)
        XCTAssertEqual(contained.guestPath, "/var/minis/workspace/out/report.pdf")
    }

    func testDotDotEscapeOutOfTheBucketIsRejected() {
        for escape in [
            base.path + "/sid1/workspace/../../secret/key",
            base.path + "/sid1/workspace/../../../../../../Library/Preferences/x",
            base.path + "/sid1/workspace/..",
            base.path + "/sid1/workspace-evil/x",
        ] {
            XCTAssertThrowsError(try RemoteLocalPathGuard.contain(hostPath: escape, roots: roots), escape) {
                XCTAssertEqual(
                    $0 as? RemoteCopyArgumentError,
                    .outsideAllowedRoots(guestRoots: ["/var/minis/shared", "/var/minis/workspace"]))
            }
        }
    }

    func testRootfsPathFromAnUntranslatedGuestFolderIsRejected() {
        XCTAssertThrowsError(try RemoteLocalPathGuard.contain(hostPath: base.path + "/rootfs/data/etc/passwd", roots: roots))
    }

    func testSymlinkInsideBucketPointingOutIsRejected() throws {
        try FileManager.default.createSymbolicLink(
            atPath: base.path + "/sid1/workspace/link", withDestinationPath: base.path + "/secret")
        XCTAssertThrowsError(try RemoteLocalPathGuard.contain(hostPath: base.path + "/sid1/workspace/link/key", roots: roots))
    }

    func testDotDotThatStaysInsideIsAccepted() throws {
        let contained = try RemoteLocalPathGuard.contain(
            hostPath: base.path + "/sid1/workspace/a/../b.txt", roots: roots)
        XCTAssertEqual(contained.guestPath, "/var/minis/workspace/b.txt")
    }
}
