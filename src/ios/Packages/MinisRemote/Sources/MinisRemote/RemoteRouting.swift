import Foundation

public struct SessionHostBindingValue: Codable, Hashable, Sendable {
    public let hostName: String
    public let workdir: String

    public init(hostName: String, workdir: String) {
        self.hostName = hostName
        self.workdir = workdir
    }
}

public enum ToolDestination: Equatable, Sendable {
    case local
    case remote(hostName: String)
}

public enum RemoteRoutingError: Error, Equatable {
    case unknownTarget(String, available: [String])
}

public enum RemoteRouting {
    private static let localTarget = "local"
    private static let deviceFilesystemPrefixes: [String] = ["/var/minis/", "minis://"]

    /// Mirrors every `native_offload_add_handler` name plus `minis-remote`;
    /// `RemoteRoutingTests.testLocalDeviceCommandsMatchRegisteredHandlers` catches drift on upstream syncs.
    public static let localDeviceCommands: Set<String> = [
        "apple-alarm", "apple-bluetooth", "apple-calendar", "apple-clipboard", "apple-device",
        "apple-healthkit", "apple-homekit", "apple-location", "apple-maps", "apple-media",
        "apple-nfc", "apple-nlp", "apple-notification", "apple-open", "apple-photos",
        "apple-player", "apple-reminders", "apple-speak", "apple-speech", "apple-vision", "apple-weather",
        "ffmpeg",
        "minis-browser-use", "minis-config", "minis-debug", "minis-hangtest", "minis-model-use",
        "minis-remote", "minis-scheduled", "minis-sessions-cli",
    ]

    public static func destination(
        toolName: String,
        arguments: [String: Any],
        binding: SessionHostBindingValue?,
        knownHosts: [String]
    ) throws -> ToolDestination {
        if let target = arguments["target"] as? String {
            if target == localTarget { return .local }
            guard knownHosts.contains(target) else {
                throw RemoteRoutingError.unknownTarget(target, available: knownHosts)
            }
            return .remote(hostName: target)
        }
        guard let binding else { return .local }

        if toolName == "shell_execute",
           let command = arguments["command"] as? String,
           let first = firstToken(of: command),
           localDeviceCommands.contains(basename(of: first)) {
            return .local
        }
        if let path = arguments["path"] as? String,
           deviceFilesystemPrefixes.contains(where: path.hasPrefix) {
            return .local
        }
        return .remote(hostName: binding.hostName)
    }

    /// `~user/...` is deliberately not expanded: resolving another account's home needs the host.
    public static func resolveRemotePath(_ path: String, workdir: String, home: String) -> String {
        if path == "~" { return trimmingTrailingSlashes(home) }
        if path.hasPrefix("~/") { return trimmingTrailingSlashes(home) + "/" + path.dropFirst(2) }
        if path.hasPrefix("/") { return path }
        return trimmingTrailingSlashes(workdir) + "/" + path
    }

    private static func firstToken(of command: String) -> String? {
        command
            .split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init)
    }

    private static func basename(of token: String) -> String {
        token.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? token
    }

    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }
}
