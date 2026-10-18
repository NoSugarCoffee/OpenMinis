import Foundation
import XCTest

/// The app's remote-host UI reads its strings from `RemoteHost.xcstrings` through `RemoteHostL10n.string`.
/// A key missing there, or missing a locale the app ships, shows English silently, so this test reads the
/// app sources and both catalogs.
final class RemoteHostCatalogTests: XCTestCase {
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // MinisRemoteTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // MinisRemote
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // src/ios
    private static let sourceFolders = ["Views/Remote", "Agent/Remote"]

    private struct Catalog: Decodable {
        struct Entry: Decodable {
            let localizations: [String: Localization]?
        }
        struct Localization: Decodable {
            struct StringUnit: Decodable { let value: String }
            let stringUnit: StringUnit?
        }
        let strings: [String: Entry]
    }

    private static func catalog(_ relativePath: String) throws -> Catalog {
        try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: appRoot.appendingPathComponent(relativePath)))
    }

    /// `\(…)` in Swift and `%@` / `%lld` in the catalog become one placeholder, so keys compare without types.
    static func normalized(_ key: String) -> String {
        key.replacingOccurrences(of: #"\\\((?:[^()]|\([^()]*\))*\)"#, with: "{}", options: .regularExpression)
            .replacingOccurrences(of: #"%(?:lld|@)"#, with: "{}", options: .regularExpression)
            .replacingOccurrences(of: #"\""#, with: "\"")
    }

    static func keysUsed(in source: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"RemoteHostL10n\.string\("((?:[^"\\]|\\.)*)"\)"#)
        return pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        }
    }

    func testEveryRemoteHostStringIsInTheCatalogInEveryShippedLocale() throws {
        let shipped = try Self.catalog("Localizable.xcstrings").strings.values
            .reduce(into: Set<String>()) { $0.formUnion($1.localizations.map { Array($0.keys) } ?? []) }
        let table = try Self.catalog("Views/Remote/RemoteHost.xcstrings").strings
        let tableByNormalizedKey = Dictionary(uniqueKeysWithValues: table.map { (Self.normalized($0.key), $0.value) })
        var used: [String] = []
        for folder in Self.sourceFolders {
            let directory = Self.appRoot.appendingPathComponent(folder)
            for file in try FileManager.default.contentsOfDirectory(atPath: directory.path) where file.hasSuffix(".swift") {
                used += Self.keysUsed(in: try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8))
            }
        }

        XCTAssertFalse(used.isEmpty, "no RemoteHostL10n.string calls found under \(Self.sourceFolders)")
        for key in used {
            guard let entry = tableByNormalizedKey[Self.normalized(key)] else {
                XCTFail("\(key) is not in RemoteHost.xcstrings; add it with every locale (src/ios/LOCALIZATION_STYLE.md).")
                continue
            }
            let translated = (entry.localizations ?? [:]).filter { $0.value.stringUnit != nil }.keys
            let missing = shipped.subtracting(translated)
            XCTAssertEqual(missing, [], "\(key) lacks locales")
        }
    }

    func testNormalizationMatchesInterpolationsToFormatSpecifiers() {
        XCTAssertEqual(
            Self.normalized(#"Port \(port) on “\(String(host.name))”"#), Self.normalized("Port %lld on “%@”"))
    }
}
