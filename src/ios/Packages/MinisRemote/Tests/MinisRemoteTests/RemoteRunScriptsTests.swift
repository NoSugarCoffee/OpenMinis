import Foundation
import XCTest
@testable import MinisRemote

final class RemoteRunScriptsTests: XCTestCase {
    private func golden(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "sh", subdirectory: "Golden"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private let trickyWorkdir = "/home/a b/it's"

    func testLaunchScriptMatchesGolden() throws {
        let script = RemoteRunScripts.launch(runId: "run1", workdir: trickyWorkdir, commandBase64: "ZWNobyBoaQ==")
        XCTAssertEqual(script, try golden("launch"))
    }

    func testCancelTreeMatchesGolden() throws {
        XCTAssertEqual(RemoteRunScripts.cancelTree(runId: "run1", signal: "TERM"), try golden("cancel-tree"))
    }

    func testRetentionIsSevenDays() {
        XCTAssertTrue(RemoteRunScripts.retention.contains("-mtime +7"))
    }

    func testCommandTravelsAsFileUnchanged() {
        let command = "cat <<'EOF'\n$HOME \"q\" `x` \\ 中文\nEOF"
        let encoded = Data(command.utf8).base64EncodedString()
        let script = RemoteRunScripts.launch(runId: "run1", workdir: "/tmp", commandBase64: encoded)
        XCTAssertTrue(script.contains(encoded))
        XCTAssertFalse(script.contains("$HOME \"q\""))
        XCTAssertFalse(script.contains("中文"))
        XCTAssertTrue(script.contains("base64 -d"))
        XCTAssertTrue(script.contains("base64 -D"))
    }

    func testWorkdirWithSpacesAndQuotesIsQuoted() {
        XCTAssertEqual(RemoteRunScripts.shellQuote(trickyWorkdir), #"'/home/a b/it'\''s'"#)
    }

    func testNonPosixLoginShellFallsBackToSh() {
        let script = RemoteRunScripts.launch(runId: "run1", workdir: "/tmp", commandBase64: "")
        XCTAssertTrue(script.contains("sh|bash|zsh|dash|ksh|ash"))
        XCTAssertTrue(script.contains("/bin/sh"))
    }

    func testLaunchWritesExitAtomicallyAndUsesSubshell() {
        let script = RemoteRunScripts.launch(runId: "run1", workdir: "/tmp", commandBase64: "")
        XCTAssertTrue(script.contains(#"( . "$R/cmd" )"#))
        XCTAssertTrue(script.contains(#"> "$R/exit.tmp""#))
        XCTAssertTrue(script.contains(#"mv "$R/exit.tmp" "$R/exit""#))
    }

    func testLaunchExits97WhenWorkdirMissing() {
        let script = RemoteRunScripts.launch(runId: "run1", workdir: "/tmp", commandBase64: "")
        XCTAssertTrue(script.contains("|| exit 97"))
    }

    func testLaunchFailsWithDistinctCodesForRunDirAndDecode() {
        let script = RemoteRunScripts.launch(runId: "run1", workdir: "/tmp", commandBase64: "")
        XCTAssertTrue(script.contains(#"mkdir -p "$R" || exit 96"#))
        XCTAssertTrue(script.contains("exit 98"))
    }

    func testStatusRechecksExitWhenPidIsDead() {
        let script = RemoteRunScripts.status(runId: "run1")
        let afterKill = script.components(separatedBy: "kill -0").last ?? ""
        XCTAssertTrue(afterKill.contains(#"elif [ -f "$R/exit" ]"#))
    }

    // MARK: Local execution under /bin/sh with a temporary HOME

    private struct ShellResult { let status: Int32; let stdout: String }

    private func runLocally(_ script: String, home: URL) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "SHELL": "/bin/sh"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ShellResult(status: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self))
    }

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("minis-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    func testInvalidBase64ExitsWith98AndWritesNoExitFile() throws {
        let home = try makeHome()
        let result = try runLocally(RemoteRunScripts.launch(runId: "bad", workdir: "/tmp", commandBase64: "@@@@"), home: home)
        XCTAssertEqual(result.status, 98)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".minis/runs/bad/exit").path))
    }

    func testStatusPrintsExitWhenRunFinished() throws {
        let home = try makeHome()
        let dir = home.appendingPathComponent(".minis/runs/done")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "0\n".write(to: dir.appendingPathComponent("exit"), atomically: true, encoding: .utf8)
        try "999999\n".write(to: dir.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try runLocally(RemoteRunScripts.status(runId: "done"), home: home).stdout, "0\n")
    }

    // MARK: A cancel that lands before the launch

    private func runDir(_ home: URL, _ runId: String) -> URL {
        home.appendingPathComponent(".minis/runs/\(runId)")
    }

    func testWriteCancelledCreatesTheRunDirectory() throws {
        let home = try makeHome()
        XCTAssertEqual(try runLocally(RemoteRunScripts.writeCancelled(runId: "early"), home: home).status, 0)
        XCTAssertEqual(
            try String(contentsOf: runDir(home, "early").appendingPathComponent("exit"), encoding: .utf8), "cancelled")
    }

    func testLaunchRefusesARunAlreadyMarkedCancelled() throws {
        let home = try makeHome()
        _ = try runLocally(RemoteRunScripts.writeCancelled(runId: "early"), home: home)
        let launch = RemoteRunScripts.launch(
            runId: "early", workdir: "/tmp", commandBase64: Data("echo ran".utf8).base64EncodedString())

        let result = try runLocally(launch, home: home)

        XCTAssertEqual(result.status, 95)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runDir(home, "early").appendingPathComponent("pid").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runDir(home, "early").appendingPathComponent("out").path))
        XCTAssertEqual(
            try String(contentsOf: runDir(home, "early").appendingPathComponent("exit"), encoding: .utf8), "cancelled")
    }

    func testClaimOfAnUnlaunchedRunMarksItCancelledSoALateLaunchRefuses() throws {
        let home = try makeHome()
        let claim = try runLocally(RemoteRunScripts.claimUnlaunched(runId: "lost"), home: home)
        let lateLaunch = try runLocally(
            RemoteRunScripts.launch(runId: "lost", workdir: "/tmp", commandBase64: Data("true".utf8).base64EncodedString()),
            home: home)

        XCTAssertEqual(claim.stdout, "claimed\n")
        XCTAssertEqual(lateLaunch.status, 95)
    }

    func testClaimOfALaunchedRunLeavesItAlone() throws {
        let home = try makeHome()
        let launch = RemoteRunScripts.launch(
            runId: "live", workdir: "/tmp", commandBase64: Data("sleep 2".utf8).base64EncodedString())
        XCTAssertEqual(try runLocally(launch, home: home).status, 0)

        let claim = try runLocally(RemoteRunScripts.claimUnlaunched(runId: "live"), home: home)

        XCTAssertEqual(claim.stdout, "launched\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: runDir(home, "live").appendingPathComponent("exit").path))
        _ = try runLocally(RemoteRunScripts.cancelTree(runId: "live", signal: "KILL"), home: home)
    }

    func testKillPassReachesChildThatIgnoredTerm() throws {
        let home = try makeHome()
        let command = "( trap '' TERM; sleep 4242; echo survived ) & wait"
        let launch = RemoteRunScripts.launch(runId: "stub", workdir: "/tmp", commandBase64: Data(command.utf8).base64EncodedString())
        XCTAssertEqual(try runLocally(launch, home: home).status, 0)
        Thread.sleep(forTimeInterval: 1)

        let term = try runLocally(RemoteRunScripts.cancelTree(runId: "stub", signal: "TERM"), home: home)
        XCTAssertGreaterThan(Int(term.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0, 0)
        Thread.sleep(forTimeInterval: 1)

        let kill = try runLocally(RemoteRunScripts.cancelTree(runId: "stub", signal: "KILL"), home: home)
        XCTAssertGreaterThan(Int(kill.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0, 0,
                             "KILL must reach the TERM-ignoring child saved by the TERM pass")
        Thread.sleep(forTimeInterval: 0.5)

        let survivors = try runLocally(#"ps -A -o command= | grep -c '^sleep 4242$'; true"#, home: home)
        XCTAssertEqual(survivors.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "0")
    }
}
