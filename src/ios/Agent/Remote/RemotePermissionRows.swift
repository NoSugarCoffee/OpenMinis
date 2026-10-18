import Foundation
import MinisRemote

/// The permission sheet's rows for a host call. `PermissionRequest.parsedArguments` reads a full command as an
/// offload command line, skipping the first token and taking `-a` as a flag, so `uname -a && pwd` showed as
/// "a  true"; a host call names its whole command line or file instead.
enum RemotePermissionRows {
    static let permissionKeyPrefix = "remote-host:"

    /// nil for any permission that is not a host's, which keeps upstream's parsing.
    static func rows(commandName: String, fullCommand: String) -> [(key: String, value: String)]? {
        guard commandName.hasPrefix(permissionKeyPrefix) else { return nil }
        switch RemotePermissionSubject(summary: fullCommand) {
        case .command(let command):
            return [(key: RemoteHostL10n.string("Command"), value: command)]
        case .file(let access, let path):
            return [(key: label(access), value: path)]
        }
    }

    private static func label(_ access: RemoteFileAccess) -> String {
        switch access {
        case .read: return RemoteHostL10n.string("Read file")
        case .write: return RemoteHostL10n.string("Write file")
        case .edit: return RemoteHostL10n.string("Edit file")
        }
    }
}
