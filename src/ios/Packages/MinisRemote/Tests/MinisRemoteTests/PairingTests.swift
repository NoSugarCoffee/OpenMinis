import Foundation
import NIOCore
import NIOPosix
import XCTest
@testable import MinisRemote

/// The vector minis-hostd's Go tests check too, so both sides agree on the MAC.
private enum Vector {
    static let secret = Data(0..<32)
    static let secretText = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
    static let publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKn78iqpSP+qI9YVAkEx9IFgvGfJNWffdtQLrSCdKh8p minis@iPhone"
    static let mac = "c9b6420d8207f338f2ce7ecbd4aff2f43e3cc8656524f10881dcfa45fc836611"
    static let hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMMMA56wC/FG21eE8SNWeCtcfO7RxpLqmq6ibqB0+5sh"
}

private func code(_ fields: [String: Any]) throws -> String {
    var all: [String: Any] = [
        "v": 1, "name": "macmini", "user": "light", "port": 22, "addresses": ["100.81.208.83", "192.168.1.5"],
        "pairPort": 50123, "hostKey": Vector.hostKey, "secret": Vector.secretText,
    ]
    all.merge(fields) { _, new in new }
    return PairingPayload.prefix + String(decoding: try JSONSerialization.data(withJSONObject: all), as: UTF8.self)
}

final class PairingPayloadTests: XCTestCase {
    func testParsesTheHostdCode() throws {
        let payload = try PairingPayload.parse(try code([:]))
        XCTAssertEqual(payload, PairingPayload(
            name: "macmini", user: "light", port: 22, addresses: ["100.81.208.83", "192.168.1.5"], pairPort: 50123,
            hostKey: Vector.hostKey, secret: Vector.secret))
    }

    func testRefusesOtherCodes() {
        XCTAssertThrowsError(try PairingPayload.parse("https://example.com")) {
            XCTAssertEqual($0 as? PairingError, .notAPairingCode)
        }
    }

    func testRefusesANewerVersion() throws {
        XCTAssertThrowsError(try PairingPayload.parse(try code(["v": 2]))) {
            XCTAssertEqual($0 as? PairingError, .unsupportedVersion(2))
        }
    }

    func testRefusesBadFields() throws {
        let cases: [[String: Any]] = [
            ["name": ""], ["user": ""], ["port": 0], ["pairPort": 70000], ["addresses": []], ["addresses": ["mini.local"]],
            ["hostKey": "ssh-rsa AAAAB3NzaC1yc2E="], ["hostKey": Vector.hostKey + " root@mini"],
            ["hostKey": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMMM"], ["secret": "AAEC"],
        ]
        for fields in cases {
            XCTAssertThrowsError(try PairingPayload.parse(try code(fields)), "\(fields)") {
                guard case .malformedCode = $0 as? PairingError else { return XCTFail("\(fields): \($0)") }
            }
        }
    }
}

final class PairingRequestTests: XCTestCase {
    func testMACMatchesTheSharedVector() {
        XCTAssertEqual(PairingRequest.mac(secret: Vector.secret, publicKey: Vector.publicKey), Vector.mac)
    }

    func testLineIsOneJSONObjectEndingInANewline() throws {
        let line = try PairingRequest.line(publicKey: Vector.publicKey, secret: Vector.secret)
        XCTAssertEqual(line.last, UInt8(ascii: "\n"))
        XCTAssertEqual(line.filter { $0 == UInt8(ascii: "\n") }.count, 1)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["publicKey"] as? String, Vector.publicKey)
        XCTAssertEqual(object["mac"] as? String, Vector.mac)
    }

    func testReplies() {
        XCTAssertNoThrow(try PairingRequest.checkReply(Data(#"{"ok":true}"#.utf8)))
        XCTAssertThrowsError(try PairingRequest.checkReply(Data(#"{"ok":false,"error":"bad_mac"}"#.utf8))) {
            XCTAssertEqual($0 as? PairingError, .refused(.badMAC))
        }
        XCTAssertThrowsError(try PairingRequest.checkReply(Data(#"{"ok":false,"error":"later"}"#.utf8))) {
            guard case .malformedReply = $0 as? PairingError else { return XCTFail("\($0)") }
        }
    }
}

private struct ScriptedTransport: PairingTransport {
    let replies: [String: Result<String, PairingTransportError>]
    let asked = Asked()

    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var addresses: [String] = []
        func append(_ address: String) { lock.lock(); addresses.append(address); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return addresses }
    }

    func exchange(address: String, port: Int, line: Data, timeout: Duration) async throws -> Data {
        asked.append(address)
        return Data(try XCTUnwrap(replies[address]).get().utf8)
    }
}

final class PairingClientTests: XCTestCase {
    private let payload = PairingPayload(
        name: "macmini", user: "light", port: 22, addresses: ["100.81.208.83", "192.168.1.5"], pairPort: 50123,
        hostKey: Vector.hostKey, secret: Vector.secret)

    func testFallsBackToTheNextAddress() async throws {
        let transport = ScriptedTransport(replies: [
            "100.81.208.83": .failure(.timedOut), "192.168.1.5": .success(#"{"ok":true}"#),
        ])
        let address = try await PairingClient(transport: transport).pair(payload, publicKey: Vector.publicKey)
        XCTAssertEqual(address, "192.168.1.5")
        XCTAssertEqual(transport.asked.all, ["100.81.208.83", "192.168.1.5"])
    }

    func testRefusalStopsAtTheFirstAddress() async throws {
        let transport = ScriptedTransport(replies: ["100.81.208.83": .success(#"{"ok":false,"error":"bad_mac"}"#)])
        do {
            _ = try await PairingClient(transport: transport).pair(payload, publicKey: Vector.publicKey)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? PairingError, .refused(.badMAC))
        }
        XCTAssertEqual(transport.asked.all, ["100.81.208.83"])
    }

    func testNoAddressAnswering() async throws {
        let transport = ScriptedTransport(replies: [
            "100.81.208.83": .failure(.timedOut), "192.168.1.5": .failure(.closedWithoutReply),
        ])
        do {
            _ = try await PairingClient(transport: transport).pair(payload, publicKey: Vector.publicKey)
            XCTFail("expected unreachable")
        } catch {
            XCTAssertEqual(error as? PairingError, .unreachable(name: "macmini", addresses: payload.addresses))
        }
    }
}

/// Answers like the host's listener: reads one line, replies with `reply`.
private final class OneLineServer: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    let reply: String
    private(set) var received = ""

    init(reply: String) { self.reply = reply }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = unwrapInboundIn(data)
        received += bytes.readString(length: bytes.readableBytes) ?? ""
        guard received.hasSuffix("\n") else { return }
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: reply + "\n"))).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}

final class NetworkPairingTransportTests: XCTestCase {
    func testExchangesOneLineOverTCP() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let handler = OneLineServer(reply: #"{"ok":true}"#)
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { $0.pipeline.addHandler(handler) }
            .bind(host: "127.0.0.1", port: 0).get()
        let port = try XCTUnwrap(server.localAddress?.port)
        let reply = try await NetworkPairingTransport().exchange(
            address: "127.0.0.1", port: port, line: Data("hello\n".utf8), timeout: .seconds(3))
        XCTAssertEqual(String(decoding: reply, as: UTF8.self), #"{"ok":true}"#)
        XCTAssertEqual(handler.received, "hello\n")
        try await server.close()
        try await group.shutdownGracefully()
    }

    func testClosedPortFailsFast() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let port = try XCTUnwrap(server.localAddress?.port)
        try await server.close()
        try await group.shutdownGracefully()
        let started = ContinuousClock.now
        do {
            _ = try await NetworkPairingTransport().exchange(
                address: "127.0.0.1", port: port, line: Data("hello\n".utf8), timeout: .seconds(3))
            XCTFail("expected a failure")
        } catch {}
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(4))
    }

    /// A listener that accepts but never answers must not hang the attempt.
    func testSilentHostTimesOut() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let port = try XCTUnwrap(server.localAddress?.port)
        do {
            _ = try await NetworkPairingTransport().exchange(
                address: "127.0.0.1", port: port, line: Data("hello\n".utf8), timeout: .milliseconds(500))
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? PairingTransportError, .timedOut)
        }
        try await server.close()
        try await group.shutdownGracefully()
    }
}
