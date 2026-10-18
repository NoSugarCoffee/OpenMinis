import Foundation
import XCTest
@testable import MinisRemote

final class RemoteHostChecksTests: XCTestCase {
    private static let allOk = """
        os=Darwin
        shell=/bin/zsh
        exec_shell=/bin/zsh
        minis=writable
        git=/usr/bin/git

        """

    // MARK: Parse

    func testParseAllOk() {
        let results = RemoteHostChecks.parse(Self.allOk)
        XCTAssertEqual(results, [
            RemoteHostChecks.Result(check: .operatingSystem, finding: .operatingSystem("Darwin")),
            RemoteHostChecks.Result(check: .loginShell, finding: .loginShell("/bin/zsh")),
            RemoteHostChecks.Result(check: .git, finding: .gitFound(path: "/usr/bin/git")),
            RemoteHostChecks.Result(check: .minisDirectory, finding: .minisWritable),
        ])
        XCTAssertEqual(results.map(\.label), ["Operating system", "Login shell", "git", "~/.minis writable"])
        XCTAssertEqual(results.map(\.detail), ["Darwin", "/bin/zsh", "/usr/bin/git", "Run output is kept in ~/.minis/runs."])
        XCTAssertTrue(results.allSatisfy(\.ok))
    }

    /// The app words each finding in the user's language, so every failure is a distinct case.
    func testFailuresAreStructuredFindings() {
        let output = "os=\nshell=\nexec_shell=/bin/sh\nminis=unwritable\ngit_shell=failed\n"
        XCTAssertEqual(RemoteHostChecks.parse(output).map(\.finding), [
            .operatingSystemEmpty, .loginShellUnset, .gitShellFailed(execShell: "/bin/sh"), .minisUnwritable,
        ])
        XCTAssertEqual(
            RemoteHostChecks.parse("shell=/usr/bin/fish\nexec_shell=/bin/sh\ngit=\n").map(\.finding),
            [.missing, .loginShellNotPosix(shell: "/usr/bin/fish", execShell: "/bin/sh"), .gitNotOnPath(execShell: "/bin/sh"), .missing])
        XCTAssertEqual(
            RemoteHostChecks.parse("").map(\.ok), [false, false, false, false])
    }

    func testParseMissingGit() {
        let output = Self.allOk.replacingOccurrences(of: "git=/usr/bin/git", with: "git=")
        let git = RemoteHostChecks.parse(output).first { $0.label == "git" }
        XCTAssertEqual(git?.ok, false)
        XCTAssertTrue(git?.detail.contains("PATH") == true, git?.detail ?? "no git result")
        XCTAssertTrue(git?.detail.contains("/bin/zsh -l") == true, git?.detail ?? "no git result")
    }

    func testParseUnwritableMinisDir() {
        let output = Self.allOk.replacingOccurrences(of: "minis=writable", with: "minis=unwritable")
        let minis = RemoteHostChecks.parse(output).first { $0.label == "~/.minis writable" }
        XCTAssertEqual(minis?.ok, false)
        XCTAssertTrue(minis?.detail.contains("~/.minis/runs") == true, minis?.detail ?? "no ~/.minis result")
    }

    func testParseNonPosixShellExplainsTheShFallback() {
        let output = "os=Linux\nshell=/usr/bin/fish\nexec_shell=/bin/sh\nminis=writable\ngit=/usr/bin/git\n"
        let shell = RemoteHostChecks.parse(output).first { $0.label == "Login shell" }
        XCTAssertEqual(shell?.ok, true)
        XCTAssertEqual(shell?.detail, "/usr/bin/fish is not a POSIX shell; commands run with /bin/sh -l instead.")
    }

    func testParseLoginShellThatFailsNamesTheShell() {
        let output = Self.allOk.replacingOccurrences(of: "git=/usr/bin/git", with: "git_shell=failed")
        let git = RemoteHostChecks.parse(output).first { $0.label == "git" }
        XCTAssertEqual(git?.ok, false)
        XCTAssertTrue(git?.detail.contains("/bin/zsh -lc 'command -v git'") == true, git?.detail ?? "no git result")
    }

    func testParseEmptyOutputFailsEveryCheck() {
        let results = RemoteHostChecks.parse("")
        XCTAssertEqual(results.map(\.label), ["Operating system", "Login shell", "git", "~/.minis writable"])
        XCTAssertTrue(results.allSatisfy { !$0.ok }, "\(results)")
    }

    func testOperatingSystemIsTheUnameLine() {
        XCTAssertEqual(RemoteHostChecks.operatingSystem(in: Self.allOk), "Darwin")
        XCTAssertNil(RemoteHostChecks.operatingSystem(in: "os=\nshell=/bin/sh\n"))
        XCTAssertNil(RemoteHostChecks.operatingSystem(in: ""))
    }

    // MARK: Script, run by the local /bin/sh

    private func runScript(home: URL, shell: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", RemoteHostChecks.script]
        process.environment = ["HOME": home.path, "SHELL": shell, "PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("checks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    func testScriptReportsEveryCheckOnThisMac() throws {
        let home = try makeTemporaryDirectory()
        let output = try runScript(home: home, shell: "/bin/sh")
        let results = RemoteHostChecks.parse(output)

        XCTAssertEqual(RemoteHostChecks.operatingSystem(in: output), "Darwin", output)
        XCTAssertEqual(results.first { $0.label == "Login shell" }?.detail, "/bin/sh", output)
        XCTAssertEqual(results.first { $0.label == "~/.minis writable" }?.ok, true, output)
        XCTAssertNotNil(results.first { $0.label == "git" }, output)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".minis").path), [])
    }

    func testScriptReportsUnwritableHome() throws {
        let home = try makeTemporaryDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: home.path)
        let output = try runScript(home: home, shell: "/bin/sh")
        XCTAssertEqual(RemoteHostChecks.parse(output).first { $0.label == "~/.minis writable" }?.ok, false, output)
    }

    func testScriptReportsLoginShellThatFails() throws {
        let home = try makeTemporaryDirectory()
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let brokenShell = bin.appendingPathComponent("sh")
        try Data("#!/bin/sh\necho 'profile noise'\nexit 3\n".utf8).write(to: brokenShell)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brokenShell.path)

        let output = try runScript(home: home, shell: brokenShell.path)
        let git = RemoteHostChecks.parse(output).first { $0.label == "git" }
        XCTAssertEqual(git?.ok, false, output)
        XCTAssertTrue(git?.detail.contains(brokenShell.path) == true, output)
    }

    // MARK: Against the fixture (opt-in)

    func testChecksRunOverTheFramedExecPath() async throws {
        let fixture = try SSHFixture.fromEnvironment()
        let pool = fixture.pool(pinnedHostKey: try await fixture.pinnedHostKeyLine(), key: fixture.key)
        _ = try await execRetryingFixtureRace(pool, script: "true")
        let output = try await RemoteExecutor(pool: pool).hostCheckOutput(host: "mini")
        let results = RemoteHostChecks.parse(output)

        XCTAssertEqual(RemoteHostChecks.operatingSystem(in: output), "Linux", output)
        XCTAssertEqual(results.first { $0.label == "Login shell" }?.detail, "/bin/bash", output)
        XCTAssertEqual(results.first { $0.label == "~/.minis writable" }?.ok, true, output)
        // The Alpine fixture has no git installed.
        XCTAssertEqual(results.first { $0.label == "git" }?.ok, false, output)
    }
}
