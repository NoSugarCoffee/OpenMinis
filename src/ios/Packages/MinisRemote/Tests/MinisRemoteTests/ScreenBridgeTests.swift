import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest
@testable import MinisRemote

private struct UnexpectedMessage: Error {
    let description: String
}

/// Speaks first like a VNC server, then echoes, so a test sees both directions.
private final class FakeVNCHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    static let greeting = "RFB 003.008\n"

    func channelActive(context: ChannelHandlerContext) {
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: Self.greeting)), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = unwrapInboundIn(data)
        if bytes.getString(at: bytes.readerIndex, length: bytes.readableBytes) == "bye" {
            context.close(promise: nil)
            return
        }
        context.writeAndFlush(wrapOutboundOut(bytes), promise: nil)
    }
}

/// Stands in for the SSH channel: a plain TCP connection to the fake server, initialised the same way.
private struct LocalTunnelOpener: ScreenTunnelOpener {
    let group: any EventLoopGroup
    let serverPort: Int

    func openTunnel(
        host: String, port: Int, initialize: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) async throws -> Channel {
        XCTAssertEqual(port, 5900)
        return try await ClientBootstrap(group: group)
            .channelInitializer(initialize)
            .connect(host: "127.0.0.1", port: serverPort).get()
    }
}

final class ScreenBridgeTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var server: Channel!
    private var bridge: ScreenBridge!
    private let session = URLSession(configuration: .ephemeral)

    override func setUp() async throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        server = try await ServerBootstrap(group: group)
            .childChannelInitializer { $0.pipeline.addHandler(FakeVNCHandler()) }
            .bind(host: "127.0.0.1", port: 0).get()
        let opener = LocalTunnelOpener(group: group, serverPort: try XCTUnwrap(server.localAddress?.port))
        bridge = try await ScreenBridge.start(host: "mini", port: 5900, opener: opener, group: group)
    }

    override func tearDown() async throws {
        await bridge.stop()
        try await server.close()
        try await group.shutdownGracefully()
    }

    func testURLIsLoopbackWithARandomPath() {
        XCTAssertEqual(bridge.url.scheme, "ws")
        XCTAssertEqual(bridge.url.host, "127.0.0.1")
        XCTAssertEqual(bridge.url.path.count, 33)
    }

    func testGreetingAndEchoPassBothWaysAsBinary() async throws {
        let socket = session.webSocketTask(with: bridge.url, protocols: ["binary"])
        socket.resume()
        let greeting = try await receiveData(socket)
        XCTAssertEqual(greeting, Data(FakeVNCHandler.greeting.utf8))
        let payload = Data((0...255).map { UInt8($0) })
        try await socket.send(.data(payload))
        let echoed = try await receiveData(socket)
        XCTAssertEqual(echoed, payload)
        socket.cancel(with: .normalClosure, reason: nil)
    }

    func testWrongPathIsRefused() async throws {
        var components = try XCTUnwrap(URLComponents(url: bridge.url, resolvingAgainstBaseURL: false))
        components.path = "/" + String(repeating: "0", count: 32)
        let socket = session.webSocketTask(with: try XCTUnwrap(components.url))
        socket.resume()
        await assertFails(socket)
    }

    func testOnlyOneConnectionIsAccepted() async throws {
        let first = session.webSocketTask(with: bridge.url)
        first.resume()
        _ = try await receiveData(first)
        let second = session.webSocketTask(with: bridge.url)
        second.resume()
        await assertFails(second)
        first.cancel(with: .normalClosure, reason: nil)
    }

    func testHostClosingEndsTheWebSocket() async throws {
        let socket = session.webSocketTask(with: bridge.url)
        socket.resume()
        _ = try await receiveData(socket)
        try await socket.send(.data(Data("bye".utf8)))
        await assertFails(socket)
    }

    func testBinarySubprotocolIsEchoedOnlyWhenOffered() throws {
        let offered = HTTPRequestHeadFixture.head(protocols: "chat, binary")
        XCTAssertEqual(ScreenBridge.responseHeaders(for: offered)["Sec-WebSocket-Protocol"], ["binary"])
        let none = HTTPRequestHeadFixture.head(protocols: nil)
        XCTAssertTrue(ScreenBridge.responseHeaders(for: none).isEmpty)
    }

    /// Opt-in like the other SSH tests: the fixture's own sshd stands in for a VNC server, since both speak
    /// first, so a banner proves the bytes crossed a real `direct-tcpip` channel.
    func testBridgeReachesAHostPortThroughSSH() async throws {
        let fixture = try SSHFixture.fromEnvironment()
        let pool = fixture.pool(pinnedHostKey: try await fixture.pinnedHostKeyLine(), key: fixture.key)
        let sshBridge = try await ScreenBridge.start(host: "mini", port: 22, opener: pool, group: group)
        let socket = session.webSocketTask(with: sshBridge.url)
        socket.resume()
        let banner = try await receiveData(socket)
        XCTAssertTrue(String(decoding: banner, as: UTF8.self).hasPrefix("SSH-2.0-"))
        socket.cancel(with: .normalClosure, reason: nil)
        await sshBridge.stop()
        await pool.invalidate(host: "mini")
    }

    func testTunnelRefusalsNameTheFix() {
        XCTAssertEqual(
            ScreenTunnelError.from(
                rejection: "NIOSSHError.channelSetupRejected: Reason: 1 administratively prohibited", host: "mini", port: 5900),
            .forwardingDisabled(host: "mini"))
        XCTAssertEqual(
            ScreenTunnelError.from(rejection: "NIOSSHError.channelSetupRejected: Reason: 2 open failed", host: "mini", port: 5900),
            .nothingListening(host: "mini", port: 5900))
        XCTAssertEqual(
            ScreenTunnelError.from(rejection: "NIOSSHError.channelSetupRejected", host: "mini", port: 5900),
            .rejected(host: "mini", port: 5900, detail: "NIOSSHError.channelSetupRejected"))
    }

    /// The fixture's sshd listens on 22 only, so 5901 has nothing behind it.
    func testClosedHostPortIsReportedAsNothingListening() async throws {
        let fixture = try SSHFixture.fromEnvironment()
        let pool = fixture.pool(pinnedHostKey: try await fixture.pinnedHostKeyLine(), key: fixture.key)
        do {
            _ = try await pool.openTunnel(host: "mini", port: 5901) { $0.eventLoop.makeSucceededVoidFuture() }
            XCTFail("expected the tunnel to be refused")
        } catch let error as ScreenTunnelError {
            XCTAssertEqual(error, .nothingListening(host: "mini", port: 5901))
        }
        await pool.invalidate(host: "mini")
    }

    private func receiveData(_ socket: URLSessionWebSocketTask) async throws -> Data {
        switch try await socket.receive() {
        case .data(let data): return data
        case .string(let text): throw UnexpectedMessage(description: "expected binary, got text \(text)")
        @unknown default: throw UnexpectedMessage(description: "unknown message kind")
        }
    }

    private func assertFails(_ socket: URLSessionWebSocketTask) async {
        do {
            _ = try await socket.receive()
            XCTFail("expected the socket to fail")
        } catch {}
    }
}

private enum HTTPRequestHeadFixture {
    static func head(protocols: String?) -> HTTPRequestHead {
        var headers = HTTPHeaders()
        if let protocols { headers.add(name: "Sec-WebSocket-Protocol", value: protocols) }
        return HTTPRequestHead(version: .http1_1, method: .GET, uri: "/x", headers: headers)
    }
}
