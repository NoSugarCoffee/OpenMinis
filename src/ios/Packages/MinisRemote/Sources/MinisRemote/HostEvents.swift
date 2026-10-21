import Foundation

/// A `pico://host-event/…` link from a push notification (B spec §5.5); `minis://` from hostd 0.2.0 and
/// earlier still parses.
public enum HostEventLink: Equatable, Sendable {
    case event(host: String, id: String)
    case batch(host: String, id: String)

    public var host: String {
        switch self {
        case .event(let host, _), .batch(let host, _): return host
        }
    }
}

public enum HostEventLinks {
    private static let alphanumerics = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    /// Anything but the two exact shapes is rejected, so a crafted link cannot smuggle a path or a
    /// shell word into the command run on the host.
    public static func parse(_ url: URL) -> HostEventLink? {
        guard url.scheme == "pico" || url.scheme == "minis", url.host == "host-event", url.query == nil, url.fragment == nil else { return nil }
        // `url.path` drops a trailing slash, which would read ".../batch/" as an event named "batch".
        let segments = url.path(percentEncoded: true)
            .split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        switch segments.count {
        case 2 where isHost(segments[0]) && isID(segments[1]):
            return .event(host: segments[0], id: segments[1])
        case 3 where isHost(segments[0]) && segments[1] == "batch" && isID(segments[2]):
            return .batch(host: segments[0], id: segments[2])
        default:
            return nil
        }
    }

    /// Host names follow A1's rule for `RemoteHostConfig.name`.
    private static func isHost(_ s: String) -> Bool {
        (1...32).contains(s.count) && s.allSatisfy { alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
    }

    private static func isID(_ s: String) -> Bool {
        (1...64).contains(s.count) && s.allSatisfy(alphanumerics.contains)
    }
}

public enum HostEventError: Error, Equatable, Sendable {
    /// The shell could not find the binary (exit 127, spec §9.4).
    case notInstalled(host: String)
    /// minis-hostd answered with its error object (exit 2).
    case server(code: String, message: String)
    case schemaMismatch(host: String, found: Int)
    case undecodable(host: String, detail: String)
    case unexpectedExit(host: String, status: Int, stderr: String)

    public var userMessage: String {
        switch self {
        case .notInstalled(let host):
            return "minis-hostd is not installed on \(host). Install it from Settings → Remote Hosts → \(host) → Notifications."
        case .server(let code, let message) where code == "not_found":
            return "\(message) It may be older than 30 days and deleted on the host."
        case .server(_, let message):
            return message
        case .schemaMismatch(let host, let found):
            return "minis-hostd on \(host) speaks contract version \(found), but this Minis knows version \(HostEventClient.schemaVersion). Update minis-hostd on \(host)."
        case .undecodable(let host, let detail):
            return "minis-hostd on \(host) sent a reply Minis could not read (\(detail))."
        case .unexpectedExit(let host, let status, let stderr):
            return "minis-hostd on \(host) exited with status \(status)\(stderr.isEmpty ? "" : ": \(stderr)")."
        }
    }
}

/// Runs a script the way A1 runs its control scripts: base64 to `/bin/sh`, framed so login-file noise
/// is dropped. Injected so the client can be tested without a host.
public protocol HostControlRunner: Sendable {
    func runControlScript(host: String, script: String) async throws -> ExecResult
}

extension RemoteExecutor: HostControlRunner {
    public func runControlScript(host: String, script: String) async throws -> ExecResult {
        try await control(host: host, script: script)
    }
}

public struct HostEventAck: Decodable, Equatable, Sendable {
    public let ok: Bool
}

/// Calls `minis-hostd … --json` on a host and decodes its one-line reply (spec §8, §9.4).
public struct HostEventClient: Sendable {
    public static let schemaVersion = 1
    static let binary = #""$HOME/.minis/bin/minis-hostd""#

    private let runner: any HostControlRunner

    public init(runner: any HostControlRunner) {
        self.runner = runner
    }

    public func ack(host: String, ids: [String]) async throws -> HostEventAck {
        try await call(host: host, arguments: ["events", "ack"] + ids)
    }

    static func script(arguments: [String]) -> String {
        ([binary] + arguments.map(RemoteRunScripts.shellQuote) + ["--json"]).joined(separator: " ")
    }

    private struct Envelope: Decodable {
        let schemaVersion: Int
    }

    private struct ErrorReply: Decodable {
        struct Body: Decodable {
            let code: String
            let message: String
        }
        let error: Body
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func call<Reply: Decodable>(host: String, arguments: [String]) async throws -> Reply {
        let result = try await runner.runControlScript(host: host, script: Self.script(arguments: arguments))
        return try Self.decode(result, host: host)
    }

    static func decode<Reply: Decodable>(_ result: ExecResult, host: String) throws -> Reply {
        let stderr = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch result.exitStatus {
        case 0, 2:
            break
        case 127:
            throw HostEventError.notInstalled(host: host)
        default:
            throw HostEventError.unexpectedExit(host: host, status: result.exitStatus, stderr: stderr)
        }
        let data = Data(result.stdout)
        let decoder = decoder()
        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            throw HostEventError.undecodable(host: host, detail: stderr.isEmpty ? String(describing: error) : stderr)
        }
        guard envelope.schemaVersion == schemaVersion else {
            throw HostEventError.schemaMismatch(host: host, found: envelope.schemaVersion)
        }
        do {
            // Exit 2 carries the error object, except from `doctor`, which prints its checklist.
            if result.exitStatus == 2, let reply = try? decoder.decode(ErrorReply.self, from: data) {
                throw HostEventError.server(code: reply.error.code, message: reply.error.message)
            }
            return try decoder.decode(Reply.self, from: data)
        } catch let error as HostEventError {
            throw error
        } catch {
            throw HostEventError.undecodable(host: host, detail: String(describing: error))
        }
    }
}
