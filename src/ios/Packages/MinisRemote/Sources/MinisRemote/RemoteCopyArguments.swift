import Foundation

public enum RemoteCopyArgumentError: Error, Equatable, Sendable {
    public enum EndpointReason: Equatable, Sendable {
        case driveLetter
        case notAbsoluteOnPhone
        case badHostName
        case emptyRemotePath
    }

    public enum HostCountReason: Equatable, Sendable {
        case bothLocal
        case bothRemote
    }

    case invalidEndpoint(String, reason: EndpointReason)
    case needsOneHost(reason: HostCountReason)
    case wrongArgumentCount(Int)
    case outsideAllowedRoots(guestRoots: [String])

    public var userMessage: String {
        switch self {
        case .invalidEndpoint(let text, let reason):
            return "Error: `\(text)` is not a valid copy path: \(Self.describe(reason)) Use `/var/minis/...` for this phone and `<host>:<path>` for a host."
        case .needsOneHost(let reason):
            switch reason {
            case .bothLocal:
                return "Error: both paths are on this phone. Use `cp` in the shell, or name a host as `<host>:<path>` on one side."
            case .bothRemote:
                return "Error: both paths are on hosts. Copy between hosts by running a command on one host with shell_execute."
            }
        case .wrongArgumentCount(let count):
            return "Error: cp takes exactly <src> <dst>, got \(count) path argument(s)."
        case .outsideAllowedRoots(let guestRoots):
            return "Error: the phone path is outside the folders this session may copy from or to. Use a path under: \(guestRoots.joined(separator: ", "))."
        }
    }

    private static func describe(_ reason: EndpointReason) -> String {
        switch reason {
        case .driveLetter: return "a single letter before `:` looks like a drive letter, not a host."
        case .notAbsoluteOnPhone: return "phone paths must be absolute."
        case .badHostName: return "host names contain only letters, digits, `_` and `-`."
        case .emptyRemotePath: return "the host path is empty."
        }
    }
}

public struct RemoteCopyPlan: Equatable, Sendable {
    public enum Direction: Equatable, Sendable {
        case upload
        case download
    }

    public let host: String
    public let localHostPath: String
    public let remotePath: String
    public let direction: Direction

    public init(host: String, localHostPath: String, remotePath: String, direction: Direction) {
        self.host = host
        self.localHostPath = localHostPath
        self.remotePath = remotePath
        self.direction = direction
    }
}

/// Validation for `minis-remote cp`. `native_offload_exec` already rewrote absolute argv entries to phone (host)
/// paths, so the local side arrives in host form and is checked by `RemoteLocalPathGuard` afterwards.
public enum RemoteCopyArguments {
    /// `positional` is what `noff_positional_args` returns: the subcommand is already dropped.
    public static func parseCommandLine(positional: [String]) throws -> (src: String, dst: String) {
        guard positional.count == 2 else { throw RemoteCopyArgumentError.wrongArgumentCount(positional.count) }
        return (positional[0], positional[1])
    }

    public static func parseEndpoint(_ text: String) throws -> RemoteCopyEndpoint {
        if text.hasPrefix("/") { return .local(text) }
        guard let colon = text.firstIndex(of: ":") else {
            throw RemoteCopyArgumentError.invalidEndpoint(text, reason: .notAbsoluteOnPhone)
        }
        let host = String(text[..<colon])
        let path = String(text[text.index(after: colon)...])
        if host.count == 1, host.first?.isASCII == true, host.first?.isLetter == true,
           path.hasPrefix("/") || path.hasPrefix("\\") {
            throw RemoteCopyArgumentError.invalidEndpoint(text, reason: .driveLetter)
        }
        guard isValidHostName(host) else {
            throw RemoteCopyArgumentError.invalidEndpoint(text, reason: .badHostName)
        }
        guard !path.isEmpty else {
            throw RemoteCopyArgumentError.invalidEndpoint(text, reason: .emptyRemotePath)
        }
        return .remote(host: host, path: path)
    }

    public static func plan(src: String, dst: String, knownHosts: [String]) throws -> RemoteCopyPlan {
        let source = try parseEndpoint(src)
        let destination = try parseEndpoint(dst)
        switch (source, destination) {
        case (.local(let local), .remote(let host, let path)):
            try requireKnown(host, in: knownHosts)
            return RemoteCopyPlan(host: host, localHostPath: local, remotePath: path, direction: .upload)
        case (.remote(let host, let path), .local(let local)):
            try requireKnown(host, in: knownHosts)
            return RemoteCopyPlan(host: host, localHostPath: local, remotePath: path, direction: .download)
        case (.local, .local):
            throw RemoteCopyArgumentError.needsOneHost(reason: .bothLocal)
        case (.remote, .remote):
            throw RemoteCopyArgumentError.needsOneHost(reason: .bothRemote)
        }
    }

    private static func requireKnown(_ host: String, in knownHosts: [String]) throws {
        guard knownHosts.contains(host) else {
            throw RemoteRoutingError.unknownTarget(host, available: knownHosts)
        }
    }

    private static func isValidHostName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
    }
}

public enum RemoteReachability {
    /// Hosts still unanswered when `budget` runs out count as unreachable, so one hung host cannot stall the list.
    public static func probe(
        hosts: [String], budget: Duration, check: @escaping @Sendable (String) async -> Bool
    ) async -> [String: Bool] {
        await withTaskGroup(of: (String, Bool)?.self) { group in
            for host in hosts {
                group.addTask { (host, await check(host)) }
            }
            group.addTask {
                try? await Task.sleep(for: budget)
                return nil
            }
            var results: [String: Bool] = [:]
            for await item in group {
                guard let (host, reachable) = item else {
                    group.cancelAll()
                    break
                }
                results[host] = reachable
                if results.count == hosts.count { group.cancelAll() }
            }
            return Dictionary(uniqueKeysWithValues: hosts.map { ($0, results[$0] ?? false) })
        }
    }
}

public struct RemoteCopyRoot: Equatable, Sendable {
    public let guestPrefix: String
    public let hostPath: String

    public init(guestPrefix: String, hostPath: String) {
        self.guestPrefix = guestPrefix
        self.hostPath = hostPath
    }
}

public struct RemoteContainedPath: Equatable, Sendable {
    public let hostPath: String
    public let guestPath: String
}

/// Keeps `minis-remote cp` inside the folders the guest can see: a guest argument such as `/../../Library/x`
/// is translated to a host path above the rootfs before the handler runs, so containment is checked on the
/// standardized host path, never on the guest spelling.
public enum RemoteLocalPathGuard {
    public static func contain(hostPath: String, roots: [RemoteCopyRoot]) throws -> RemoteContainedPath {
        let resolved = standardize(hostPath)
        let matches = roots.compactMap { root -> (root: RemoteCopyRoot, resolvedRoot: String)? in
            let resolvedRoot = standardize(root.hostPath)
            let inside = resolved == resolvedRoot || resolved.hasPrefix(resolvedRoot + "/")
            return inside ? (root, resolvedRoot) : nil
        }
        guard let best = matches.max(by: { $0.resolvedRoot.count < $1.resolvedRoot.count }) else {
            throw RemoteCopyArgumentError.outsideAllowedRoots(guestRoots: roots.map(\.guestPrefix).sorted())
        }
        let tail = resolved.dropFirst(best.resolvedRoot.count)
        return RemoteContainedPath(hostPath: resolved, guestPath: best.root.guestPrefix + tail)
    }

    /// Symlinks are resolved so a link inside an allowed folder cannot lead out of it. A destination that does
    /// not exist yet is resolved through its deepest existing ancestor, because Foundation leaves such paths alone.
    private static func standardize(_ path: String) -> String {
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var missing: [String] = []
        while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) {
            missing.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        return missing.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
    }
}
