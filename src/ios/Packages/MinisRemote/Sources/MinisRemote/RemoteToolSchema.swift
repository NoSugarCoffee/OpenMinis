public struct RemoteToolParameter: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case string
        case boolean
    }

    public let name: String
    public let kind: Kind
    public let description: String
}

/// The parameters remote routing adds to the local tool schemas. The app maps them onto its own tool type.
public enum RemoteToolSchema {
    public static let target = RemoteToolParameter(
        name: "target", kind: .string,
        description: "Leave unset for the default: the host this chat is bound to, or this phone if the chat has no host. Never needed for work on the bound host. 'local' runs on this phone (iSH, /var/minis); a configured host name runs on that host.")

    public static let detach = RemoteToolParameter(
        name: "detach", kind: .boolean,
        description: "Remote hosts only. If true, start the command in the background and return its run_id, output file and exit file at once; check on it later with shell_execute (tail the output file, cat the exit file). Default false waits for the command to finish.")

    /// Appended to upstream's shell_execute description, which says commands run in iSH.
    public static func boundShellNote(binding: SessionHostBindingValue, os: String?) -> String {
        "In this chat, commands do not run in iSH: they run on host `\(binding.hostName)` (\(os ?? RemoteToolOutput.unknownOS)) in `\(binding.workdir)` unless `target: \"local\"` is set."
    }

    /// In `propertyOrdering` order, after the tool's own parameters. Without a configured host there is nothing
    /// to target, so the schemas stay exactly upstream's.
    public static func additions(toolName: String, hostsConfigured: Bool) -> [RemoteToolParameter] {
        guard hostsConfigured else { return [] }
        switch toolName {
        case "shell_execute": return [target, detach]
        case "file_read", "file_write", "file_edit": return [target]
        default: return []
        }
    }
}
