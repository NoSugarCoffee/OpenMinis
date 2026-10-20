import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

/// Opens a byte stream to a TCP port on the host. `initialize` runs before the first byte is read, because
/// a VNC server speaks first and a handler added later would miss its greeting.
public protocol ScreenTunnelOpener: Sendable {
    func openTunnel(
        host: String, port: Int, initialize: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) async throws -> Channel
}

public enum ScreenBridgeError: Error, Equatable, Sendable {
    case listenFailed(detail: String)
}

/// Why the host's sshd would not open the tunnel (RFC 4254 §5.1 reason codes), worded as the next step.
public enum ScreenTunnelError: Error, Equatable, Sendable {
    case forwardingDisabled(host: String)
    case nothingListening(host: String, port: Int)
    case rejected(host: String, port: Int, detail: String)

    public var userMessage: String {
        switch self {
        case .forwardingDisabled(let host):
            return "Host `\(host)` does not allow SSH tunnels. Set `AllowTcpForwarding yes` in /etc/ssh/sshd_config on the host and restart sshd."
        case .nothingListening(let host, let port):
            return "Nothing is listening on port \(port) on `\(host)`. On a Mac, turn on Screen Sharing in System Settings → General → Sharing; on Linux, start a VNC server on 127.0.0.1:\(port)."
        case .rejected(let host, let port, let detail):
            return "Host `\(host)` refused a tunnel to port \(port): \(detail)"
        }
    }

    /// NIOSSH keeps the reason code private and only prints it, as "…: Reason: <code> <text>".
    static func from(rejection description: String, host: String, port: Int) -> ScreenTunnelError {
        let code = description.range(of: "Reason: ").flatMap { range in
            Int(description[range.upperBound...].prefix { $0.isNumber })
        }
        switch code {
        case 1: return .forwardingDisabled(host: host)
        case 2: return .nothingListening(host: host, port: port)
        default: return .rejected(host: host, port: port, detail: description)
        }
    }
}

/// A3 spec §3.1: noVNC only speaks RFB over a WebSocket, so the app serves one on loopback and pipes its
/// binary frames to the host's VNC port through the tunnel. It accepts a single connection, and only on a
/// random path, so another app on the phone cannot reach the host's screen through it.
public final class ScreenBridge: Sendable {
    public let url: URL

    private let serverChannel: Channel

    private init(url: URL, serverChannel: Channel) {
        self.url = url
        self.serverChannel = serverChannel
    }

    public static func start(
        host: String, port: Int, opener: any ScreenTunnelOpener, group: any EventLoopGroup
    ) async throws -> ScreenBridge {
        let token = makeToken()
        let claimed = NIOLockedValueBox(false)
        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: maxFrameSize,
            automaticErrorHandling: true,
            shouldUpgrade: { channel, head in
                let accepted = head.uri == "/\(token)" && claimed.withLockedValue { taken in
                    defer { taken = true }
                    return !taken
                }
                return channel.eventLoop.makeSucceededFuture(accepted ? responseHeaders(for: head) : nil)
            },
            upgradePipelineHandler: { channel, _ in
                // It sits before the WebSocket decoder, so it would read raw frames as HTTP.
                channel.pipeline.removeHandler(name: refuseHandlerName).flatMap {
                    connect(webSocket: channel, host: host, port: port, opener: opener)
                }
            })
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                        withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }))
                    try channel.pipeline.syncOperations.addHandler(RefuseHTTPHandler(), name: refuseHandlerName)
                }
            }
        let serverChannel: Channel
        do {
            serverChannel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        } catch {
            throw ScreenBridgeError.listenFailed(detail: String(describing: error))
        }
        guard let boundPort = serverChannel.localAddress?.port,
              let url = URL(string: "ws://127.0.0.1:\(boundPort)/\(token)") else {
            try? await serverChannel.close()
            throw ScreenBridgeError.listenFailed(detail: "no local port after bind")
        }
        return ScreenBridge(url: url, serverChannel: serverChannel)
    }

    /// Stops accepting; a connection already bridged ends when either side closes.
    public func stop() async {
        try? await serverChannel.close()
    }

    static let refuseHandlerName = "minis.screen.refuse"

    /// Big enough for a pasted clipboard; RFB client messages are otherwise a few bytes.
    static let maxFrameSize = 1 << 20

    static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", generator.next() as UInt8) }.joined()
    }

    /// noVNC may offer the `binary` subprotocol, and a browser drops a socket whose reply does not echo one
    /// it offered.
    static func responseHeaders(for head: HTTPRequestHead) -> HTTPHeaders {
        let offered = head.headers["Sec-WebSocket-Protocol"]
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return offered.contains("binary") ? HTTPHeaders([("Sec-WebSocket-Protocol", "binary")]) : HTTPHeaders()
    }

    private static func connect(
        webSocket: Channel, host: String, port: Int, opener: any ScreenTunnelOpener
    ) -> EventLoopFuture<Void> {
        let promise = webSocket.eventLoop.makePromise(of: Void.self)
        promise.completeWithTask {
            do {
                let tunnel = try await opener.openTunnel(host: host, port: port) { tunnel in
                    tunnel.pipeline.addHandler(TunnelToWebSocketHandler(webSocket: webSocket))
                }
                try await webSocket.pipeline.addHandler(WebSocketToTunnelHandler(tunnel: tunnel)).get()
            } catch {
                try? await webSocket.writeAndFlush(closeFrame(.unexpectedServerError)).get()
                try? await webSocket.close()
                throw error
            }
        }
        return promise.futureResult
    }

    static func closeFrame(_ code: WebSocketErrorCode) -> WebSocketFrame {
        var data = ByteBuffer()
        data.write(webSocketErrorCode: code)
        return WebSocketFrame(fin: true, opcode: .connectionClose, data: data)
    }
}

/// Answers any request that was not upgraded, so a wrong path fails at once instead of hanging.
private final class RefuseHTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = unwrapInboundIn(data) else { return }
        let head = HTTPResponseHead(
            version: .http1_1, status: .forbidden, headers: HTTPHeaders([("Content-Length", "0"), ("Connection", "close")]))
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        let channel = context.channel
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in channel.close(promise: nil) }
    }
}

private final class TunnelToWebSocketHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer

    private let webSocket: Channel

    init(webSocket: Channel) {
        self.webSocket = webSocket
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = WebSocketFrame(fin: true, opcode: .binary, data: unwrapInboundIn(data))
        webSocket.writeAndFlush(frame, promise: nil)
    }

    /// No futures here: the WebSocket's event loop may already be shutting down when the host side ends.
    func channelInactive(context: ChannelHandlerContext) {
        webSocket.writeAndFlush(ScreenBridge.closeFrame(.normalClosure), promise: nil)
        webSocket.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

private final class WebSocketToTunnelHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let tunnel: Channel

    init(tunnel: Channel) {
        self.tunnel = tunnel
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .binary, .continuation:
            tunnel.writeAndFlush(frame.unmaskedData, promise: nil)
        case .ping:
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .connectionClose:
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(ScreenBridge.closeFrame(.normalClosure))).whenComplete { _ in
                channel.close(promise: nil)
            }
        case .text:
            // RFB is binary; text means the page is not noVNC.
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(ScreenBridge.closeFrame(.unacceptableData))).whenComplete { _ in
                channel.close(promise: nil)
            }
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        tunnel.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
