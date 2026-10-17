import Crypto
import Foundation
import XCTest

/// FileToolLogic is a port of the app's local file_read / file_edit (upstream code the fork leaves untouched).
/// When upstream changes one of these functions, remote and local behaviour drift apart unless the change is
/// ported, so this test pins each function's source.
final class FileToolDriftTests: XCTestCase {
    private static let upstreamFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // MinisRemoteTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // MinisRemote
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // src/ios
        .appendingPathComponent("Agent/Chat/AIChatViewModel+FileTools.swift")

    /// SHA-256 of each function's source, from its `func` line through its closing brace, as of b4c0661.
    private static let recordedFingerprints: [String: String] = [
        "executeFileRead": "771dc3cf190e6f892539c20cdc8101f8816c73d57749d948f505914e845925ed",
        "executeFileEdit": "638bd3a0529f1e9b835feae382c7e386c1718046a9adafee8d7cd9832ce6ecf9",
        "findAllRanges": "d0a291a39006002dfdf21d5df20f6a3caca8031ebccba91a09b0d3b4e77a0062",
        "normalizeForFuzzyMatch": "cadd7e2671d28f27b1d3aabf1a096935793f4c1e6263c4f4ec922acbe4cb4943",
        "buildFileEditPreview": "89b286426bfacb2c5a10b5f83eadf2c07186769af879cbe2cacda750162cdf2d",
    ]

    func testPortedUpstreamFileToolFunctionsAreUnchanged() throws {
        let source = try String(contentsOf: Self.upstreamFile, encoding: .utf8)
        for (name, recorded) in Self.recordedFingerprints.sorted(by: { $0.key < $1.key }) {
            let body = try XCTUnwrap(
                Self.functionSource(named: name, in: source),
                "`func \(name)(` is gone from AIChatViewModel+FileTools.swift. Find where upstream moved it and port the change into FileToolLogic.")
            XCTAssertEqual(
                Self.fingerprint(body), recorded,
                "Upstream changed `\(name)` in AIChatViewModel+FileTools.swift. Port the change into FileToolLogic (the remote file_read/file_edit) so remote and local tools behave alike, then record the new fingerprint here.")
        }
    }

    static func functionSource(named name: String, in source: String) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("func \(name)(") }) else { return nil }
        var depth = 0
        var opened = false
        for index in start..<lines.count {
            for character in lines[index] {
                if character == "{" { depth += 1; opened = true }
                if character == "}" { depth -= 1 }
            }
            if opened && depth == 0 {
                return lines[start...index].joined(separator: "\n")
            }
        }
        return nil
    }

    static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func testFunctionSourceStopsAtTheMatchingBrace() {
        let source = "a\nfunc f(x: Int) {\n    if x > 0 { g() }\n}\nfunc h() {}\n"
        XCTAssertEqual(Self.functionSource(named: "f", in: source), "func f(x: Int) {\n    if x > 0 { g() }\n}")
        XCTAssertNil(Self.functionSource(named: "missing", in: source))
    }
}
