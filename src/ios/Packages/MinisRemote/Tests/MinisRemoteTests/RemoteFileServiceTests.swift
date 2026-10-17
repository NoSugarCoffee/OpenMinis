import Crypto
import Foundation
import XCTest
@testable import MinisRemote

private func unconfiguredService() -> RemoteFileService {
    RemoteFileService(
        pool: SSHConnectionPool(
            directory: FixedHostDirectory(hosts: [], key: Curve25519.Signing.PrivateKey()),
            connectTimeout: .seconds(1)))
}

private func expectFileError<T>(
    _ expected: RemoteFileError, file: StaticString = #filePath, line: UInt = #line,
    _ operation: () async throws -> T
) async {
    do {
        let value = try await operation()
        XCTFail("Expected \(expected), got \(value)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? RemoteFileError, expected, "\(error)", file: file, line: line)
    }
}

/// A connected service plus a fresh scratch directory on the fixture host, whose name has a space and a quote.
private struct RemoteScratch {
    let pool: SSHConnectionPool
    let service: RemoteFileService
    let dir: String

    static func make(requestTimeout: Duration = .seconds(30)) async throws -> RemoteScratch {
        let fixture = try SSHFixture.fromEnvironment()
        let pool = fixture.pool(pinnedHostKey: try await fixture.pinnedHostKeyLine(), key: fixture.key)
        let made = try await execRetryingFixtureRace(pool, script: "d=$(mktemp -d) && mkdir \"$d/it's dir\" && printf '%s' \"$d/it's dir\"")
        XCTAssertEqual(made.exitStatus, 0, made.stderrText)
        return RemoteScratch(
            pool: pool, service: RemoteFileService(pool: pool, requestTimeout: requestTimeout), dir: made.stdoutText)
    }

    func path(_ name: String) -> String { "\(dir)/\(name)" }

    @discardableResult
    func sh(_ script: String) async throws -> String {
        let result = try await pool.exec(host: "mini", script: "cd \(RemoteRunScripts.shellQuote(dir)) && \(script)", timeout: .seconds(20))
        XCTAssertEqual(result.exitStatus, 0, "\(script): \(result.stderrText)")
        return result.stdoutText
    }
}

private func docker(_ arguments: [String]) throws {
    try runTool("/usr/bin/env", ["docker"] + arguments)
}

final class RemoteFileServiceTests: XCTestCase {
    // MARK: Pure

    func testTempNameStaysInSameDirectory() {
        XCTAssertEqual(
            RemoteFileService.tempName(for: "/home/dev/it's dir/a b.txt", random: "r1"),
            "/home/dev/it's dir/.a b.txt.minis-tmp-r1")
        XCTAssertEqual(RemoteFileService.tempName(for: "/a.txt", random: "r2"), "/.a.txt.minis-tmp-r2")
    }

    func testRelativeRemotePathIsRejectedBeforeConnecting() async {
        let service = unconfiguredService()
        await expectFileError(.relativePath(path: "notes.txt")) {
            try await service.read(host: "mini", path: "notes.txt", offset: nil, lines: nil, direction: nil, maxLength: nil, defaultMaxLength: 15_000)
        }
        await expectFileError(.relativePath(path: "~/a")) {
            try await service.write(host: "mini", path: "~/a", content: "x")
        }
        await expectFileError(.relativePath(path: "a")) {
            try await service.edit(host: "mini", path: "a", oldString: "x", newString: "y", replaceAll: false)
        }
        await expectFileError(.relativePath(path: "rel/local")) {
            try await service.copy(from: .local("rel/local"), to: .remote(host: "mini", path: "/tmp/a"))
        }
    }

    func testListDirectoriesRejectsRelativePathBeforeConnecting() async {
        await expectFileError(.relativePath(path: "src")) {
            try await unconfiguredService().listDirectories(host: "mini", path: "src")
        }
    }

    func testCopyRejectsSameSideEndpoints() async {
        let service = unconfiguredService()
        let localToLocal = (RemoteCopyEndpoint.local("/a"), RemoteCopyEndpoint.local("/b"))
        await expectFileError(.unsupportedCopy(from: localToLocal.0, to: localToLocal.1)) {
            try await service.copy(from: localToLocal.0, to: localToLocal.1)
        }
        let remoteToRemote = (RemoteCopyEndpoint.remote(host: "mini", path: "/a"), RemoteCopyEndpoint.remote(host: "mini", path: "/b"))
        await expectFileError(.unsupportedCopy(from: remoteToRemote.0, to: remoteToRemote.1)) {
            try await service.copy(from: remoteToRemote.0, to: remoteToRemote.1)
        }
    }

    func testErrorMessagesNameTheNextStep() {
        XCTAssertEqual(
            RemoteFileError.conflict(path: "/a").userMessage,
            "Error: /a changed on the host since it was last read. Read it again with file_read, then retry the edit.")
        XCTAssertEqual(RemoteFileError.rejected(message: "Error: exact").userMessage, "Error: exact")
    }

    // MARK: Opt-in, against the sshd fixture

    func testWriteIsAtomicAndKeepsMode() async throws {
        let scratch = try await RemoteScratch.make()
        let target = scratch.path("run me.sh")
        try await scratch.sh("printf old > 'run me.sh' && chmod 755 'run me.sh'")

        try await scratch.service.write(host: "mini", path: target, content: "#!/bin/sh\necho new\n")

        let out1 = try await scratch.sh("cat 'run me.sh'")
        XCTAssertEqual(out1, "#!/bin/sh\necho new\n")
        let out2 = try await scratch.sh("stat -c %a 'run me.sh'")
        XCTAssertEqual(out2, "755\n")
        let out3 = try await scratch.sh("ls -A")
        XCTAssertEqual(out3, "run me.sh\n")
    }

    func testWriteKeepsPrivateModeAndNewFilesGetTheUmaskDefault() async throws {
        let scratch = try await RemoteScratch.make()
        try await scratch.sh("printf old > secret && chmod 600 secret")

        try await scratch.service.write(host: "mini", path: scratch.path("secret"), content: "new")
        try await scratch.service.write(host: "mini", path: scratch.path("fresh"), content: "new")

        let modes = try await scratch.sh("stat -c '%n %a' secret fresh")
        let umask = try await scratch.sh("umask")
        XCTAssertEqual(umask, "0022\n", "the expected default below assumes the fixture's umask")
        XCTAssertEqual(modes, "secret 600\nfresh 644\n")
    }

    func testWriteThroughSymlinkKeepsTheLink() async throws {
        let scratch = try await RemoteScratch.make()
        try await scratch.sh("mkdir real && printf old > real/target.txt && ln -s real/target.txt link.txt")

        try await scratch.service.write(host: "mini", path: scratch.path("link.txt"), content: "new")

        let state = try await scratch.sh("[ -L link.txt ] && echo link; cat real/target.txt; echo; ls -A; ls -A real")
        XCTAssertEqual(state, "link\nnew\nlink.txt\nreal\ntarget.txt\n")
    }

    func testCancelledWriteLeavesNoTempFile() async throws {
        let scratch = try await RemoteScratch.make()
        let content = String(repeating: "0123456789abcdef", count: 4 * 1024 * 1024)
        let service = scratch.service
        let target = scratch.path("big.txt")
        let writing = Task { try await service.write(host: "mini", path: target, content: content) }

        var tempMode = ""
        let deadline = ContinuousClock.now + .seconds(20)
        while tempMode.isEmpty, ContinuousClock.now < deadline {
            tempMode = try await scratch.sh("stat -c %a .big.txt.minis-tmp-* 2>/dev/null || true")
        }
        XCTAssertEqual(tempMode, "600\n", "the temp file must stay private while it is written")
        writing.cancel()
        let outcome = await writing.result

        if case .failure(let error) = outcome {
            XCTAssertTrue(error is CancellationError, "\(error)")
        } else {
            XCTFail("Expected the write to be cancelled before it finished")
        }
        let after = try await scratch.sh("ls -A")
        XCTAssertEqual(after, "")
    }

    func testListDirectoriesReturnsSortedSubdirectoriesOnly() async throws {
        let scratch = try await RemoteScratch.make()
        try await scratch.sh("mkdir 'b dir' a \"it's\" .hidden && touch file.txt && ln -s a link")

        let names = try await scratch.service.listDirectories(host: "mini", path: scratch.dir)

        XCTAssertEqual(names, [".hidden", "a", "b dir", "it's"])
    }

    func testListDirectoriesOfMissingPathIsNotFound() async throws {
        let scratch = try await RemoteScratch.make()
        await expectFileError(.notFound(path: scratch.path("nope"))) {
            try await scratch.service.listDirectories(host: "mini", path: scratch.path("nope"))
        }
    }

    func testWriteCreatesNewFileAndMissingParents() async throws {
        let scratch = try await RemoteScratch.make()
        let target = scratch.path("new/deeper/n.txt")

        try await scratch.service.write(host: "mini", path: target, content: "ü 漢字\n")

        let out4 = try await scratch.sh("cat new/deeper/n.txt")
        XCTAssertEqual(out4, "ü 漢字\n")
        let out5 = try await scratch.sh("ls -A new/deeper")
        XCTAssertEqual(out5, "n.txt\n")
    }

    func testAppendAddsToExistingFileAndCreatesMissingOne() async throws {
        let scratch = try await RemoteScratch.make()
        try await scratch.sh("printf 'one\\n' > a.txt && chmod 640 a.txt")

        try await scratch.service.append(host: "mini", path: scratch.path("a.txt"), content: "two\n")
        try await scratch.service.append(host: "mini", path: scratch.path("fresh/b.txt"), content: "first\n")

        let appended = try await scratch.sh("cat a.txt")
        XCTAssertEqual(appended, "one\ntwo\n")
        let mode = try await scratch.sh("stat -c %a a.txt")
        XCTAssertEqual(mode, "640\n")
        let created = try await scratch.sh("cat fresh/b.txt")
        XCTAssertEqual(created, "first\n")
    }

    func testWriteRefusesDirectoryTarget() async throws {
        let scratch = try await RemoteScratch.make()
        try await scratch.sh("mkdir sub")
        await expectFileError(.isDirectory(path: scratch.path("sub"))) {
            try await scratch.service.write(host: "mini", path: scratch.path("sub"), content: "x")
        }
        let out6 = try await scratch.sh("ls -A sub")
        XCTAssertEqual(out6, "")
    }

    func testReadMatchesLocalSlicing() async throws {
        let scratch = try await RemoteScratch.make()
        let text = (1...50).map { "line \($0)" }.joined(separator: "\n")
        try await scratch.service.write(host: "mini", path: scratch.path("f.txt"), content: text)

        let remote = try await scratch.service.read(
            host: "mini", path: scratch.path("f.txt"), offset: 10, lines: 30, direction: nil, maxLength: 60, defaultMaxLength: 15_000)

        XCTAssertEqual(
            FileToolLogic.read(
                path: scratch.path("f.txt"), data: Data(text.utf8), offset: 10, lines: 30, direction: nil, maxLength: 60, defaultMaxLength: 15_000),
            .text(remote))
    }

    func testReadOfBinaryReturnsTheLocalHexPreview() async throws {
        let scratch = try await RemoteScratch.make()
        try await scratch.sh("printf 'a\\000b' > bin")

        let remote = try await scratch.service.read(
            host: "mini", path: scratch.path("bin"), offset: nil, lines: nil, direction: nil, maxLength: nil, defaultMaxLength: 15_000)

        XCTAssertEqual(
            FileToolLogic.read(
                path: scratch.path("bin"), data: Data([0x61, 0x00, 0x62]), offset: nil, lines: nil, direction: nil, maxLength: nil, defaultMaxLength: 15_000),
            .binary(remote))
    }

    func testLargeBinaryReadStillGivesPreview() async throws {
        let scratch = try await RemoteScratch.make()
        try await scratch.sh("head -c 20000000 /dev/zero > zeros")

        let remote = try await scratch.service.read(
            host: "mini", path: scratch.path("zeros"), offset: nil, lines: nil, direction: nil, maxLength: nil, defaultMaxLength: 15_000)

        XCTAssertEqual(
            remote,
            "[\(scratch.path("zeros")) | 20000000 bytes | binary file]\nHex preview: "
                + Array(repeating: "00", count: 64).joined(separator: " "))
    }

    /// procfs reports size 0, so only reading to EOF gets the whole file.
    func testReadOfZeroSizeProcFileReturnsAllOfIt() async throws {
        let scratch = try await RemoteScratch.make()
        let probe = try await scratch.sh("stat -c %s /proc/cpuinfo; wc -c < /proc/cpuinfo")
        let numbers = probe.split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        XCTAssertEqual(numbers.first, 0, probe)
        XCTAssertGreaterThan(numbers.last ?? 0, FileToolLogic.binarySniffLength, probe)
        let cat = try await scratch.sh("cat /proc/cpuinfo")

        let remote = try await scratch.service.read(
            host: "mini", path: "/proc/cpuinfo", offset: nil, lines: nil, direction: nil, maxLength: 80_000, defaultMaxLength: 15_000)

        XCTAssertEqual(
            FileToolLogic.read(
                path: "/proc/cpuinfo", data: Data(cat.utf8), offset: nil, lines: nil, direction: nil, maxLength: 80_000, defaultMaxLength: 15_000),
            .text(remote))
    }

    func testReadAndEditRefuseFilesOverTenMegabytes() async throws {
        let scratch = try await RemoteScratch.make()
        let path = scratch.path("big.log")
        try await scratch.sh("head -c 10485761 /dev/zero | tr '\\000' a > big.log")

        await expectFileError(.tooLarge(path: path, size: 10_485_761)) {
            try await scratch.service.read(host: "mini", path: path, offset: nil, lines: nil, direction: "tail", maxLength: nil, defaultMaxLength: 15_000)
        }
        await expectFileError(.tooLarge(path: path, size: 10_485_761)) {
            try await scratch.service.edit(host: "mini", path: path, oldString: "a", newString: "b", replaceAll: true)
        }
        XCTAssertTrue(RemoteFileError.tooLarge(path: path, size: 10_485_761).userMessage.contains("tail -n"))

        try await scratch.sh("head -c 10485760 /dev/zero | tr '\\000' a > edge.log")
        let atLimit = try await scratch.service.read(
            host: "mini", path: scratch.path("edge.log"), offset: nil, lines: 1, direction: nil, maxLength: 10, defaultMaxLength: 15_000)
        XCTAssertTrue(atLimit.hasPrefix("[\(scratch.path("edge.log")) | 10485760 bytes | 1 lines"), atLimit)
    }

    func testReadMissingFileIsNotFound() async throws {
        let scratch = try await RemoteScratch.make()
        await expectFileError(.notFound(path: scratch.path("absent"))) {
            try await scratch.service.read(host: "mini", path: scratch.path("absent"), offset: nil, lines: nil, direction: nil, maxLength: nil, defaultMaxLength: 15_000)
        }
    }

    func testEditMatchesLocalSemantics() async throws {
        let scratch = try await RemoteScratch.make()
        let path = scratch.path("dup.txt")
        try await scratch.service.write(host: "mini", path: path, content: "x\nx\n")

        guard case .rejected(let localMessage) = FileToolLogic.edit(
            path: path, data: Data("x\nx\n".utf8), oldString: "x", newString: "y", replaceAll: false)
        else { return XCTFail("Expected the local edit to be rejected") }
        await expectFileError(.rejected(message: localMessage)) {
            try await scratch.service.edit(host: "mini", path: path, oldString: "x", newString: "y", replaceAll: false)
        }

        let summary = try await scratch.service.edit(host: "mini", path: path, oldString: "x", newString: "yy", replaceAll: true)
        XCTAssertEqual(summary, "Edited \(path) (2 replacements, 6 bytes)")
        let out7 = try await scratch.sh("cat dup.txt")
        XCTAssertEqual(out7, "yy\nyy\n")
    }

    func testEditDetectsConcurrentChange() async throws {
        let scratch = try await RemoteScratch.make()
        let path = scratch.path("c.txt")
        try await scratch.sh("printf 'one\\n' > c.txt")
        _ = try await scratch.service.read(host: "mini", path: path, offset: nil, lines: nil, direction: nil, maxLength: nil, defaultMaxLength: 15_000)

        try await scratch.sh("printf 'two\\n' >> c.txt")

        await expectFileError(.conflict(path: path)) {
            try await scratch.service.edit(host: "mini", path: path, oldString: "one", newString: "uno", replaceAll: false)
        }
        let out8 = try await scratch.sh("cat c.txt")
        XCTAssertEqual(out8, "one\ntwo\n")

        _ = try await scratch.service.read(host: "mini", path: path, offset: nil, lines: nil, direction: nil, maxLength: nil, defaultMaxLength: 15_000)
        _ = try await scratch.service.edit(host: "mini", path: path, oldString: "one", newString: "uno", replaceAll: false)
        let out9 = try await scratch.sh("cat c.txt")
        XCTAssertEqual(out9, "uno\ntwo\n")
    }

    func testEditOfMissingFileIsNotFound() async throws {
        let scratch = try await RemoteScratch.make()
        await expectFileError(.notFound(path: scratch.path("absent"))) {
            try await scratch.service.edit(host: "mini", path: scratch.path("absent"), oldString: "a", newString: "b", replaceAll: false)
        }
    }

    func testCopyRoundTripStreamsBytes() async throws {
        let scratch = try await RemoteScratch.make()
        let localDir = FileManager.default.temporaryDirectory.appendingPathComponent("minis-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localDir) }
        var generator = SystemRandomNumberGenerator()
        let bytes = Data((0..<300_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let source = localDir.appendingPathComponent("src.bin")
        try bytes.write(to: source)
        let back = localDir.appendingPathComponent("nested/back.bin")
        let remotePath = scratch.path("up.bin")

        let uploaded = try await scratch.service.copy(from: .local(source.path), to: .remote(host: "mini", path: remotePath))
        let downloaded = try await scratch.service.copy(from: .remote(host: "mini", path: remotePath), to: .local(back.path))

        XCTAssertEqual(uploaded, 300_000)
        XCTAssertEqual(downloaded, 300_000)
        XCTAssertEqual(try Data(contentsOf: back), bytes)
        let out10 = try await scratch.sh("wc -c < up.bin | tr -d ' '")
        XCTAssertEqual(out10, "300000\n")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: back.deletingLastPathComponent().path), ["back.bin"])
    }

    func testHalfOpenConnectionIsUnreachableAndDropped() async throws {
        let scratch = try await RemoteScratch.make(requestTimeout: .seconds(2))
        let path = scratch.path("h.txt")
        try await scratch.service.write(host: "mini", path: path, content: "h")

        try docker(["pause", "minis-sshtest"])
        let started = ContinuousClock.now
        let outcome: Result<String, Error>
        do {
            outcome = .success(try await scratch.service.read(
                host: "mini", path: path, offset: nil, lines: nil, direction: nil, maxLength: nil, defaultMaxLength: 15_000))
        } catch {
            outcome = .failure(error)
        }
        let elapsed = ContinuousClock.now - started
        let cached = await scratch.pool.cachedHostNames
        try docker(["unpause", "minis-sshtest"])

        switch outcome {
        case .success(let text):
            XCTFail("Expected unreachable, got \(text)")
        case .failure(let error):
            XCTAssertEqual(error as? RemoteHostError, .unreachable(host: "mini"), "\(error)")
        }
        XCTAssertEqual(cached, [])
        XCTAssertLessThan(elapsed, .seconds(5))
    }
}
