import XCTest
@testable import MinisRemote

final class RemoteRunStateTests: XCTestCase {
    func testClassifyExitCode() {
        XCTAssertEqual(RemoteRunState.classify(statusOutput: "3"), .exited(3))
        XCTAssertEqual(RemoteRunState.classify(statusOutput: "3\n"), .exited(3))
    }

    func testClassifyCancelled() {
        XCTAssertEqual(RemoteRunState.classify(statusOutput: "cancelled"), .cancelled)
    }

    func testClassifyRunning() {
        XCTAssertEqual(RemoteRunState.classify(statusOutput: "running 1"), .running)
        XCTAssertEqual(RemoteRunState.classify(statusOutput: "running 1\n"), .running)
    }

    func testClassifyAbnormal() {
        XCTAssertEqual(RemoteRunState.classify(statusOutput: "running 0"), .abnormal)
        XCTAssertEqual(RemoteRunState.classify(statusOutput: "garbage"), .abnormal)
    }

    func testSplitMultibyteSequenceAcrossChunksIsPreserved() {
        var buffer = RemoteOutputBuffer()
        XCTAssertEqual(buffer.append([0xE4]), "")
        XCTAssertEqual(buffer.append([0xB8, 0xAD]), "中")
        XCTAssertEqual(buffer.offset, 3)
    }

    func testInvalidUTF8IsReplacedNotDropped() {
        var buffer = RemoteOutputBuffer()
        XCTAssertEqual(buffer.append([0xFF, 0x41]), "\u{FFFD}A")
    }

    func testTruncateKeepsHeadTailAndNamesFile() {
        let text = "FIRST\n" + String(repeating: "x", count: 500) + "\nLAST"
        let path = "~/.minis/runs/abc/out"
        let result = RemoteRunState.truncateForModel(text, outputPath: path, limit: 100)
        let expected = String(text.prefix(50))
            + "\n\n...\n\n"
            + String(text.suffix(50))
            + "\n\n[OUTPUT TRUNCATED] Full output (\(text.count) chars) saved to: \(path)"
        XCTAssertEqual(result, expected)
        XCTAssertTrue(result.hasPrefix("FIRST\n"))
        XCTAssertTrue(result.contains("\nLAST\n\n[OUTPUT TRUNCATED]"))
    }

    func testFourByteSequenceSplitOneThree() {
        var buffer = RemoteOutputBuffer()
        XCTAssertEqual(buffer.append([0xF0]), "")
        XCTAssertEqual(buffer.append([0x9F, 0x98, 0x80]), "😀")
        XCTAssertEqual(buffer.offset, 4)
    }

    func testFourByteSequenceSplitThreeOne() {
        var buffer = RemoteOutputBuffer()
        XCTAssertEqual(buffer.append([0xF0, 0x9F, 0x98]), "")
        XCTAssertEqual(buffer.append([0x80]), "😀")
        XCTAssertEqual(buffer.offset, 4)
    }

    func testTwoByteSequenceSplit() {
        var buffer = RemoteOutputBuffer()
        XCTAssertEqual(buffer.append([0x41, 0xC3]), "A")
        XCTAssertEqual(buffer.append([0xA9]), "é")
        XCTAssertEqual(buffer.offset, 3)
    }

    func testFlushDecodesHeldLeadByteAsReplacement() {
        var buffer = RemoteOutputBuffer()
        XCTAssertEqual(buffer.append([0xE4]), "")
        XCTAssertEqual(buffer.flush(), "\u{FFFD}")
        XCTAssertEqual(buffer.flush(), "")
        XCTAssertEqual(buffer.offset, 1)
    }

    func testFlushOfTruncatedSequenceEmitsReplacement() {
        var buffer = RemoteOutputBuffer()
        XCTAssertEqual(buffer.append([0x41, 0xE4, 0xB8]), "A")
        XCTAssertEqual(buffer.flush(), "\u{FFFD}")
        XCTAssertEqual(buffer.offset, 3)
    }

    func testOffsetCountsHeldTail() {
        var buffer = RemoteOutputBuffer()
        _ = buffer.append([0x41, 0x42, 0xE4])
        XCTAssertEqual(buffer.offset, 3)
    }

    func testInvalidLeadFollowedByValidChunk() {
        var buffer = RemoteOutputBuffer()
        XCTAssertEqual(buffer.append([0xE4]), "")
        XCTAssertEqual(buffer.append([0x41]), "\u{FFFD}A")
    }

    func testTruncateLeavesShortTextUntouched() {
        XCTAssertEqual(RemoteRunState.truncateForModel("hi", outputPath: "p", limit: 100), "hi")
    }
}
