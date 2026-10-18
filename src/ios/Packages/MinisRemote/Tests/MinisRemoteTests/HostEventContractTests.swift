import Foundation
import XCTest
@testable import MinisRemote

/// Decodes the Go side's golden files, so the app and minis-hostd cannot drift apart unnoticed.
final class HostEventContractTests: XCTestCase {
    private static let contractDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // MinisRemoteTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // MinisRemote
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // ios
        .deletingLastPathComponent() // src
        .deletingLastPathComponent() // repository root
        .appendingPathComponent("host/minis-hostd/testdata/contract")

    private func golden(_ name: String, exitStatus: Int) throws -> ExecResult {
        let data = try Data(contentsOf: Self.contractDirectory.appendingPathComponent(name))
        return ExecResult(stdout: Array(data), stderr: [], exitStatus: exitStatus)
    }

    private func decode<Reply: Decodable>(_ name: String, as: Reply.Type) throws -> Reply {
        try HostEventClient.decode(golden(name, exitStatus: 0), host: "mac-mini")
    }

    func testEveryGoldenFileIsCovered() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.contractDirectory.path).sorted()
        XCTAssertEqual(names, [
            "batches_get.json", "error_bad_request.json", "error_not_found.json", "error_schema_mismatch.json",
            "error_store_unavailable.json", "events_ack.json", "events_get_github.json", "events_get_mail.json",
            "events_list.json", "status.json",
        ], "a new golden file needs a decoding test here")
    }

    func testMailEvent() throws {
        let event = try decode("events_get_mail.json", as: HostEventReply.self).event
        XCTAssertEqual(event.source, .mail)
        XCTAssertEqual(event.url, "minis://host-event/mac-mini/\(event.id)")
        guard case .mail(let body) = event.body else { return XCTFail("\(event.body)") }
        XCTAssertEqual(body.from, MailAddress(name: "Alice Chen", address: "alice@example.com"))
        XCTAssertEqual(body.subject, event.summary)
        XCTAssertTrue(body.text.contains("$HOME"))
        XCTAssertEqual(body.attachments.first?.name, "contract-v3.pdf")
        XCTAssertNotNil(event.ackedAt)
    }

    func testGitHubEvent() throws {
        let event = try decode("events_get_github.json", as: HostEventReply.self).event
        guard case .github(let body) = event.body else { return XCTFail("\(event.body)") }
        XCTAssertEqual(body.reason, "review_requested")
        XCTAssertEqual(body.htmlUrl, "https://github.com/NoSugarCoffee/OpenMinis/pull/10")
        XCTAssertNil(event.ackedAt)
    }

    func testBatchListAndStatus() throws {
        let batch = try decode("batches_get.json", as: HostEventBatchReply.self).batch
        XCTAssertFalse(batch.events.isEmpty)
        let list = try decode("events_list.json", as: HostEventListReply.self).events
        XCTAssertEqual(list.first?.reason, "sender_not_allowed")
        let status = try decode("status.json", as: HostdStatus.self)
        XCTAssertEqual(status.sources.map(\.state), [.error, .ok])
        XCTAssertNotNil(status.heartbeatAt)
        XCTAssertTrue(try decode("events_ack.json", as: HostEventAck.self).ok)
    }

    func testErrorGoldensMapToServerErrors() throws {
        for (name, code) in [
            ("error_not_found.json", "not_found"), ("error_bad_request.json", "bad_request"),
            ("error_store_unavailable.json", "store_unavailable"), ("error_schema_mismatch.json", "schema_mismatch"),
        ] {
            XCTAssertThrowsError(try HostEventClient.decode(golden(name, exitStatus: 2), host: "mac-mini") as HostEventAck, name) {
                guard case HostEventError.server(let found, let message) = $0 else { return XCTFail("\($0)") }
                XCTAssertEqual(found, code, name)
                XCTAssertFalse(message.isEmpty, name)
            }
        }
    }
}
