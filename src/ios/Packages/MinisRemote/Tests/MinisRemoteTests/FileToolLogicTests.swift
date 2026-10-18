import Foundation
import XCTest
@testable import MinisRemote

/// Expected strings are the ones `AIChatViewModel+FileTools.swift` produces today (minus the app-only
/// `minis_url:` suffix), so the app can switch to `FileToolLogic` without a visible change.
/// `AIChatViewModel.kMaxToolResultChars`, which the app passes as the default `max_length`.
private let appToolResultLimit = 15_000

final class FileToolLogicTests: XCTestCase {
    private func read(
        _ text: String, offset: Int? = nil, lines: Int? = nil, direction: String? = nil, maxLength: Int? = nil
    ) -> FileToolLogic.ReadOutcome {
        FileToolLogic.read(
            path: "/p", data: Data(text.utf8), offset: offset, lines: lines, direction: direction,
            maxLength: maxLength, defaultMaxLength: appToolResultLimit)
    }

    private func edit(_ text: String, old: String, new: String, replaceAll: Bool) -> FileToolLogic.EditOutcome {
        FileToolLogic.edit(path: "/p", data: Data(text.utf8), oldString: old, newString: new, replaceAll: replaceAll)
    }

    // MARK: Read slicing

    func testReadWholeFileByDefault() {
        XCTAssertEqual(read("a\nb\nc"), .text("[/p | 5 bytes | 3 lines | showing lines 1-3 of 3]\na\nb\nc"))
    }

    func testReadCountsTrailingNewlineAsEmptyLastLine() {
        XCTAssertEqual(read("a\n"), .text("[/p | 2 bytes | 2 lines | showing lines 1-2 of 2]\na\n"))
    }

    func testReadOffsetAndLines() {
        XCTAssertEqual(read("a\nb\nc", offset: 2, lines: 1), .text("[/p | 5 bytes | 3 lines | showing lines 2-2 of 3]\nb"))
    }

    func testReadOffsetBelowOneStartsAtFirstLine() {
        XCTAssertEqual(read("a\nb", offset: -4, lines: 1), .text("[/p | 3 bytes | 2 lines | showing lines 1-1 of 2]\na"))
    }

    func testReadOffsetPastEndReturnsEmptyRange() {
        XCTAssertEqual(read("a\nb\nc", offset: 10), .text("[/p | 5 bytes | 3 lines | showing lines 4-3 of 3]\n"))
    }

    func testReadTailIgnoresOffsetAndIsCaseInsensitive() {
        XCTAssertEqual(
            read("a\nb\nc", offset: 1, lines: 2, direction: "TAIL"),
            .text("[/p | 5 bytes | 3 lines | showing lines 2-3 of 3]\nb\nc"))
    }

    func testReadUnknownDirectionIsHead() {
        XCTAssertEqual(read("a\nb\nc", lines: 1, direction: "sideways"), .text("[/p | 5 bytes | 3 lines | showing lines 1-1 of 3]\na"))
    }

    // MARK: Read parameter guards

    func testNonPositiveLinesIsRejected() {
        for lines in [-1, 0, Int.min] {
            XCTAssertEqual(read("a\nb", lines: lines), .rejected("Error: lines must be a positive integer"), "\(lines)")
            XCTAssertEqual(
                read("a\nb", lines: lines, direction: "tail"), .rejected("Error: lines must be a positive integer"), "\(lines)")
        }
    }

    func testNonPositiveMaxLengthIsRejected() {
        for maxLength in [-5, 0, Int.min] {
            XCTAssertEqual(
                read("a\nb", maxLength: maxLength), .rejected("Error: max_length must be a positive integer"), "\(maxLength)")
        }
    }

    func testHugeLinesAndOffsetDoNotOverflow() {
        XCTAssertEqual(read("a\nb\nc", offset: 2, lines: Int.max), .text("[/p | 5 bytes | 3 lines | showing lines 2-3 of 3]\nb\nc"))
        XCTAssertEqual(read("a\nb\nc", offset: Int.max, lines: Int.max), .text("[/p | 5 bytes | 3 lines | showing lines 4-3 of 3]\n"))
        XCTAssertEqual(
            read("a\nb\nc", lines: Int.max, direction: "tail"), .text("[/p | 5 bytes | 3 lines | showing lines 1-3 of 3]\na\nb\nc"))
        XCTAssertEqual(read("a\nb\nc", maxLength: Int.max), .text("[/p | 5 bytes | 3 lines | showing lines 1-3 of 3]\na\nb\nc"))
    }

    // MARK: Read truncation

    func testHeadTruncationBacksOffToWholeLineAndGivesNextOffset() {
        XCTAssertEqual(
            read("aaaa\nbbbb\ncccc", maxLength: 7),
            .text("[/p | 14 bytes | 3 lines | showing lines 1-1 of 3 | truncated at 7 chars, next_offset=2]\naaaa"))
    }

    func testHeadTruncationOfSingleLongLineAsksForFewerLines() {
        XCTAssertEqual(
            read("abcdefgh", maxLength: 3),
            .text("[/p | 8 bytes | 1 lines | showing lines 1-1 of 1 | truncated at 3 chars, retry with a smaller lines value]\nabc"))
    }

    func testTailTruncationKeepsTheEndAndDropsLeadingPartialLine() {
        XCTAssertEqual(
            read("aaaa\nbbbb\ncccc", direction: "tail", maxLength: 7),
            .text("[/p | 14 bytes | 3 lines | showing lines 3-3 of 3 | truncated at 7 chars, retry with a smaller lines value]\ncccc"))
    }

    func testOmittedMaxLengthUsesTheCallersDefault() {
        XCTAssertEqual(
            FileToolLogic.read(
                path: "/p", data: Data("aaaa\nbbbb\ncccc".utf8), offset: nil, lines: nil, direction: nil,
                maxLength: nil, defaultMaxLength: 7),
            .text("[/p | 14 bytes | 3 lines | showing lines 1-1 of 3 | truncated at 7 chars, next_offset=2]\naaaa"))
    }

    func testDefaultMaxLengthIsToolResultLimit() {
        let text = String(repeating: "x", count: 15_001)
        XCTAssertEqual(
            read(text),
            .text("[/p | 15001 bytes | 1 lines | showing lines 1-1 of 1 | truncated at 15000 chars, retry with a smaller lines value]\n"
                + String(repeating: "x", count: 15_000)))
    }

    func testMaxLengthIsCappedAtEightyThousand() {
        let text = String(repeating: "x", count: 80_001)
        XCTAssertEqual(
            read(text, maxLength: 1_000_000),
            .text("[/p | 80001 bytes | 1 lines | showing lines 1-1 of 1 | truncated at 80000 chars, retry with a smaller lines value]\n"
                + String(repeating: "x", count: 80_000)))
    }

    // MARK: Read content checks

    func testNullByteInFirst512BytesIsBinaryWithHexPreview() {
        XCTAssertEqual(
            FileToolLogic.read(
                path: "/p", data: Data([0x00, 0x01, 0x41]), offset: nil, lines: nil, direction: nil, maxLength: nil, defaultMaxLength: appToolResultLimit),
            .binary("[/p | 3 bytes | binary file]\nHex preview: 00 01 41"))
    }

    func testHexPreviewStopsAt64Bytes() {
        let data = Data([0x00] + [UInt8](repeating: 0xab, count: 100))
        let expected = "[/p | 101 bytes | binary file]\nHex preview: 00 " + Array(repeating: "ab", count: 63).joined(separator: " ")
        XCTAssertEqual(
            FileToolLogic.read(path: "/p", data: data, offset: nil, lines: nil, direction: nil, maxLength: nil, defaultMaxLength: appToolResultLimit),
            .binary(expected))
    }

    func testBinaryPreviewNeedsOnlyTheLeadingBytes() {
        XCTAssertEqual(FileToolLogic.binarySniffLength, 512)
        XCTAssertEqual(
            FileToolLogic.binaryPreview(path: "/p", leadingBytes: Data([0x00, 0x01]), totalBytes: 1_000),
            "[/p | 1000 bytes | binary file]\nHex preview: 00 01")
        XCTAssertNil(FileToolLogic.binaryPreview(path: "/p", leadingBytes: Data("text".utf8), totalBytes: 1_000))
    }

    func testNullByteAfter512BytesIsText() {
        let data = Data([UInt8](repeating: 0x61, count: 512) + [0x00])
        guard case .text = FileToolLogic.read(path: "/p", data: data, offset: nil, lines: nil, direction: nil, maxLength: nil, defaultMaxLength: appToolResultLimit) else {
            return XCTFail("Expected text")
        }
    }

    /// The app's local file_edit decoded with `String(contentsOf:encoding:)`; FileToolLogic decodes the bytes
    /// with `String(data:encoding:)`. Both must treat a UTF-8 BOM and invalid bytes alike for the swap to be
    /// invisible.
    func testStringDecodingParityWithContentsOfURL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileToolLogicTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let samples: [Data] = [
            Data([0xEF, 0xBB, 0xBF] + Array("bom\nline".utf8)),
            Data([0xEF, 0xBB, 0xBF]),
            Data("plain ü 漢字\n".utf8),
            Data(),
            Data([0x66, 0xFF, 0x67]),
        ]
        for (index, data) in samples.enumerated() {
            let url = directory.appendingPathComponent("sample-\(index)")
            try data.write(to: url)
            XCTAssertEqual(
                try? String(contentsOf: url, encoding: .utf8), String(data: data, encoding: .utf8),
                "sample \(index): \(Array(data))")
        }
    }

    func testInvalidUTF8IsRejected() {
        XCTAssertEqual(
            FileToolLogic.read(path: "/p", data: Data([0xff, 0xfe]), offset: nil, lines: nil, direction: nil, maxLength: nil, defaultMaxLength: appToolResultLimit),
            .rejected("Error: /p is not valid UTF-8 text"))
    }

    func testMissingFileMessages() {
        XCTAssertEqual(FileToolLogic.readMissingFileMessage(path: "/p"), "Error: No such file: /p")
        XCTAssertEqual(
            FileToolLogic.editMissingFileMessage(path: "/p"),
            "Error: File does not exist: /p. Use file_write to create new files.")
    }

    // MARK: Edit matching

    func testEditReplacesUniqueMatch() {
        XCTAssertEqual(
            edit("let a = 1\nlet b = 2\n", old: "b = 2", new: "b = 3", replaceAll: false),
            .edited(updatedContent: "let a = 1\nlet b = 3\n", summary: "Edited /p (1 replacement, 20 bytes)"))
    }

    func testEditRejectsAmbiguousMatch() {
        XCTAssertEqual(
            edit("x\nx\n", old: "x", new: "y", replaceAll: false),
            .rejected("Error: old_string matches 2 locations in /p. Provide more surrounding context to make the match unique, or set replace_all: true to replace all occurrences."))
    }

    func testEditReplaceAll() {
        XCTAssertEqual(
            edit("x\nx\n", old: "x", new: "yy", replaceAll: true),
            .edited(updatedContent: "yy\nyy\n", summary: "Edited /p (2 replacements, 6 bytes)"))
    }

    func testEditRejectsEmptyOldString() {
        XCTAssertEqual(
            edit("x", old: "", new: "y", replaceAll: false),
            .rejected("Error: old_string must not be empty. Use file_write to create or overwrite files."))
    }

    func testEditRejectsInvalidUTF8BeforeCheckingOldString() {
        XCTAssertEqual(
            FileToolLogic.edit(path: "/p", data: Data([0xff]), oldString: "", newString: "y", replaceAll: false),
            .rejected("Error: Could not read /p as UTF-8 text"))
    }

    func testEditMissShowsFirstTwentyLines() {
        let lines = (1...25).map { "line\($0)" }
        let expectedPreview = (1...20).map { "\($0): line\($0)" }.joined(separator: "\n")
        XCTAssertEqual(
            edit(lines.joined(separator: "\n"), old: "absent", new: "y", replaceAll: false),
            .rejected("Error: old_string not found in /p. Use file_read to view current file contents before editing.\n\nFirst 20 lines:\n\(expectedPreview)"))
    }

    func testEditMissShowsContextAroundAnchor() {
        let prefix = String(repeating: "x", count: 60)
        let file = "line1\n\(prefix)END\nline3"
        XCTAssertEqual(
            edit(file, old: "\(prefix)OTHER", new: "y", replaceAll: false),
            .rejected("Error: old_string not found in /p. Use file_read to view current file contents before editing.\n\n"
                + "Closest match in file (lines 1–3, normalized old_string anchor at line 2):\n"
                + "1: line1\n2: \(prefix)END\n3: line3\n\n"
                + "Note: file may use smart quotes (\u{201C}\u{201D}\u{2018}\u{2019}), tabs, or trailing whitespace your old_string omits. Re-read the file and copy the exact bytes."))
    }

    func testEditFuzzyMatchesSmartQuotesAndKeepsSurroundingBytes() {
        XCTAssertEqual(
            edit("say \u{201C}hi\u{201D} now", old: "say \"hi\"", new: "say bye", replaceAll: false),
            .edited(
                updatedContent: "say bye now",
                summary: "Edited /p (1 replacement, 11 bytes) — fuzzy-matched: quotes/whitespace normalized"))
    }

    func testEditFuzzyMatchesTrailingAndInlineWhitespace() {
        XCTAssertEqual(
            edit("  a   b  \nc", old: "  a b\nc", new: "z", replaceAll: false),
            .edited(updatedContent: "z", summary: "Edited /p (1 replacement, 1 bytes) — fuzzy-matched: quotes/whitespace normalized"))
    }
}
