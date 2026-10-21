import Crypto
import Foundation
import Network

/// What `minis-hostd pair` puts in its code (pairing spec §2). The code is shown on the user's own screen, so
/// its host key is pinned as is and its secret authenticates the phone's public key on the way to the host.
public struct PairingPayload: Equatable, Sendable {
    public static let prefix = "minis-pair:"
    public static let supportedVersion = 1

    public let name: String
    public let user: String
    public let port: Int
    /// In the order the host prefers them: Tailscale first, then the LAN.
    public let addresses: [String]
    public let pairPort: Int
    /// `ssh-ed25519 <base64>`, the form `RemoteHostConfig.pinnedHostKey` stores.
    public let hostKey: String
    public let secret: Data

    private struct Wire: Decodable {
        let v: Int
        let name: String?
        let user: String?
        let port: Int?
        let addresses: [String]?
        let pairPort: Int?
        let hostKey: String?
        let secret: String?
    }

    public static func parse(_ text: String) throws -> PairingPayload {
        guard text.hasPrefix(prefix) else { throw PairingError.notAPairingCode }
        let json = Data(text.dropFirst(prefix.count).utf8)
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: json)
        } catch {
            throw PairingError.malformedCode("the code is not valid JSON: \(error)")
        }
        guard wire.v == supportedVersion else { throw PairingError.unsupportedVersion(wire.v) }
        guard let name = wire.name, !name.isEmpty else { throw PairingError.malformedCode("name is missing") }
        guard let user = wire.user, !user.isEmpty else { throw PairingError.malformedCode("user is missing") }
        guard let port = wire.port, (1...65535).contains(port) else { throw PairingError.malformedCode("port is not 1–65535") }
        guard let pairPort = wire.pairPort, (1...65535).contains(pairPort) else {
            throw PairingError.malformedCode("pairPort is not 1–65535")
        }
        guard let addresses = wire.addresses, !addresses.isEmpty, addresses.allSatisfy({ IPv4Address($0) != nil }) else {
            throw PairingError.malformedCode("addresses must list at least one IPv4 address")
        }
        guard let hostKey = wire.hostKey, isEd25519KeyLine(hostKey) else {
            throw PairingError.malformedCode("hostKey is not an ssh-ed25519 public key")
        }
        guard let encoded = wire.secret, let secret = Data(base64URLEncoded: encoded), secret.count == 32 else {
            throw PairingError.malformedCode("secret is not 32 bytes of base64url")
        }
        return PairingPayload(
            name: name, user: user, port: port, addresses: addresses, pairPort: pairPort, hostKey: hostKey, secret: secret)
    }

    /// Exactly `ssh-ed25519 <blob>`, the blob being the type string and a 32-byte key.
    private static func isEd25519KeyLine(_ line: String) -> Bool {
        let fields = line.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 2, fields[0] == "ssh-ed25519", let blob = Data(base64Encoded: String(fields[1])) else {
            return false
        }
        let type = Data("ssh-ed25519".utf8)
        let expected = Data([0, 0, 0, UInt8(type.count)]) + type + Data([0, 0, 0, 32])
        return blob.count == expected.count + 32 && blob.prefix(expected.count) == expected
    }
}

public enum PairingRefusal: String, Equatable, Sendable {
    case badMAC = "bad_mac"
    case badKey = "bad_key"
    case badRequest = "bad_request"
}

public enum PairingError: Error, Equatable {
    case notAPairingCode
    case unsupportedVersion(Int)
    case malformedCode(String)
    case unreachable(name: String, addresses: [String])
    case refused(PairingRefusal)
    case malformedReply(String)
}

/// The one-line exchange with the host's pairing listener (pairing spec §3).
public enum PairingRequest {
    private static let macContext = "minis-pair-v1\n"

    public static func mac(secret: Data, publicKey: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data((macContext + publicKey).utf8), using: SymmetricKey(data: secret))
        return code.map { String(format: "%02x", $0) }.joined()
    }

    private struct Line: Encodable {
        let v: Int
        let publicKey: String
        let mac: String
    }

    public static func line(publicKey: String, secret: Data) throws -> Data {
        let body = try JSONEncoder().encode(Line(v: PairingPayload.supportedVersion, publicKey: publicKey, mac: mac(secret: secret, publicKey: publicKey)))
        return body + Data("\n".utf8)
    }

    private struct Reply: Decodable {
        let ok: Bool
        let error: String?
    }

    public static func checkReply(_ data: Data) throws {
        let reply: Reply
        do {
            reply = try JSONDecoder().decode(Reply.self, from: data)
        } catch {
            throw PairingError.malformedReply(String(decoding: data.prefix(200), as: UTF8.self))
        }
        if reply.ok { return }
        guard let code = reply.error, let refusal = PairingRefusal(rawValue: code) else {
            throw PairingError.malformedReply(String(decoding: data.prefix(200), as: UTF8.self))
        }
        throw PairingError.refused(refusal)
    }
}

/// Sends one line and returns the reply line; any failure to connect or answer means "try the next address".
public protocol PairingTransport: Sendable {
    func exchange(address: String, port: Int, line: Data, timeout: Duration) async throws -> Data
}

public struct PairingClient: Sendable {
    public static let attemptTimeout: Duration = .seconds(3)

    private let transport: any PairingTransport

    public init(transport: any PairingTransport) {
        self.transport = transport
    }

    /// Returns the address that accepted the key. A refusal stops at once: another address reaches the same
    /// listener, which would refuse again.
    public func pair(_ payload: PairingPayload, publicKey: String) async throws -> String {
        let line = try PairingRequest.line(publicKey: publicKey, secret: payload.secret)
        for address in payload.addresses {
            let reply: Data
            do {
                reply = try await transport.exchange(
                    address: address, port: payload.pairPort, line: line, timeout: Self.attemptTimeout)
            } catch {
                continue
            }
            try PairingRequest.checkReply(reply)
            return address
        }
        throw PairingError.unreachable(name: payload.name, addresses: payload.addresses)
    }
}

public enum PairingTransportError: Error, Equatable {
    case timedOut
    case closedWithoutReply
    case replyTooLong
}

/// Plain TCP through Network.framework, so App Transport Security has no say; the content is authenticated by
/// the MAC and the host key comes from the code, not from this connection.
public struct NetworkPairingTransport: PairingTransport {
    static let maxReplyBytes = 4096

    public init() {}

    public func exchange(address: String, port: Int, line: Data, timeout: Duration) async throws -> Data {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            throw PairingTransportError.closedWithoutReply
        }
        let connection = NWConnection(host: NWEndpoint.Host(address), port: endpointPort, using: .tcp)
        defer { connection.cancel() }
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await Self.run(connection, line: line) }
            group.addTask {
                try await Task.sleep(for: timeout)
                // Cancelling the connection is what unblocks the other task's pending callbacks.
                connection.cancel()
                throw PairingTransportError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw PairingTransportError.closedWithoutReply }
            connection.cancel()
            return first
        }
    }

    private static func run(_ connection: NWConnection, line: Data) async throws -> Data {
        try await ready(connection)
        try await send(connection, line)
        return try await receiveLine(connection, received: Data())
    }

    private static func ready(_ connection: NWConnection) async throws {
        let once = ResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    once.run { continuation.resume(throwing: error) }
                case .cancelled:
                    once.run { continuation.resume(throwing: PairingTransportError.timedOut) }
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }

    private static func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private static func receiveLine(_ connection: NWConnection, received: Data) async throws -> Data {
        let (chunk, isComplete) = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(Data, Bool), any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maxReplyBytes) { data, _, isComplete, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: (data ?? Data(), isComplete)) }
            }
        }
        let all = received + chunk
        if let newline = all.firstIndex(of: UInt8(ascii: "\n")) { return Data(all[..<newline]) }
        guard all.count <= maxReplyBytes else { throw PairingTransportError.replyTooLong }
        if isComplete {
            guard !all.isEmpty else { throw PairingTransportError.closedWithoutReply }
            return all
        }
        return try await receiveLine(connection, received: all)
    }
}

/// NWConnection reports states after `.ready` too (`.cancelled` on teardown); only the first may resume.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

extension Data {
    init?(base64URLEncoded text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
