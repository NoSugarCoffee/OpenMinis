import Foundation

/// The setup checks of spec §7. The script prints one `key=value` line per fact; the login shell's own
/// output (profile noise) is filtered on the host, so only `parse` decides what a line means.
public enum RemoteHostChecks {
    public enum Check: Hashable, Sendable {
        case operatingSystem
        case loginShell
        case git
        case minisDirectory
    }

    /// One case per outcome, so the app can word each in the user's language; `detail` is the English wording.
    public enum Finding: Equatable, Sendable {
        /// The check's line is absent: the check script did not finish on the host.
        case missing
        case operatingSystem(String)
        case operatingSystemEmpty
        case loginShell(String)
        case loginShellUnset
        case loginShellNotPosix(shell: String, execShell: String)
        case gitFound(path: String)
        case gitNotOnPath(execShell: String)
        case gitShellFailed(execShell: String)
        case minisWritable
        case minisUnwritable

        public var ok: Bool {
            switch self {
            case .operatingSystem, .loginShell, .loginShellNotPosix, .gitFound, .minisWritable: return true
            case .missing, .operatingSystemEmpty, .loginShellUnset, .gitNotOnPath, .gitShellFailed, .minisUnwritable:
                return false
            }
        }

        public var detail: String {
            switch self {
            case .missing:
                return "Missing from the check output; the check script did not finish on the host."
            case .operatingSystem(let os):
                return os
            case .operatingSystemEmpty:
                return "`uname -s` printed nothing."
            case .loginShell(let shell):
                return shell
            case .loginShellUnset:
                return "$SHELL is not set; commands run with /bin/sh -l."
            case .loginShellNotPosix(let shell, let execShell):
                return "\(shell) is not a POSIX shell; commands run with \(execShell) -l instead."
            case .gitFound(let path):
                return path
            case .gitNotOnPath(let execShell):
                return "git was not found on the PATH of the login shell (\(execShell) -l). Install git, or add its directory to PATH in that shell's login profile."
            case .gitShellFailed(let execShell):
                return "The login shell failed before printing, so git's PATH could not be checked. Run `\(execShell) -lc 'command -v git'` on the host to see the error."
            case .minisWritable:
                return "Run output is kept in ~/.minis/runs."
            case .minisUnwritable:
                return "~/.minis could not be created or written. Minis keeps run output in ~/.minis/runs; fix the ownership or permissions of ~/.minis, or free disk space."
            }
        }
    }

    public struct Result: Equatable, Sendable {
        public let check: Check
        public let finding: Finding

        public init(check: Check, finding: Finding) {
            self.check = check
            self.finding = finding
        }

        public var ok: Bool { finding.ok }
        public var detail: String { finding.detail }

        public var label: String {
            switch check {
            case .operatingSystem: return "Operating system"
            case .loginShell: return "Login shell"
            case .git: return "git"
            case .minisDirectory: return "~/.minis writable"
            }
        }
    }

    /// Picks the shell the same way `RemoteRunScripts.launch` does, so `git` is looked up on the PATH that
    /// commands will actually get.
    public static let script = #"""
        printf 'os=%s\n' "$(uname -s 2>/dev/null)"
        printf 'shell=%s\n' "$SHELL"
        case "${SHELL##*/}" in
          sh|bash|zsh|dash|ksh|ash) S="$SHELL" ;;
          *) S=/bin/sh ;;
        esac
        printf 'exec_shell=%s\n' "$S"
        D="$HOME/.minis"
        if mkdir -p "$D" 2>/dev/null && T="$D/.write-check-$$" && : 2>/dev/null > "$T" && rm -f "$T"; then
          echo minis=writable
        else
          echo minis=unwritable
        fi
        "$S" -lc 'printf "\n__minis_git=%s\n" "$(command -v git)"' </dev/null 2>/dev/null \
          | awk 'index($0, "__minis_git=") == 1 { v = substr($0, 13); f = 1 } END { if (f) print "git=" v; else print "git_shell=failed" }'

        """#

    public static func parse(_ output: String) -> [Result] {
        let values = fields(of: output)
        let execShell = values["exec_shell"] ?? "/bin/sh"
        return [
            Result(check: .operatingSystem, finding: operatingSystemFinding(values["os"])),
            Result(check: .loginShell, finding: loginShellFinding(values["shell"], execShell: execShell)),
            Result(
                check: .git,
                finding: gitFinding(values["git"], shellFailed: values["git_shell"] == "failed", execShell: execShell)),
            Result(check: .minisDirectory, finding: minisDirectoryFinding(values["minis"])),
        ]
    }

    /// The value to persist as `RemoteHostConfig.os`; nil when `uname -s` printed nothing.
    public static func operatingSystem(in output: String) -> String? {
        guard let os = fields(of: output)["os"], !os.isEmpty else { return nil }
        return os
    }

    private static func fields(of output: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return values
    }

    private static func operatingSystemFinding(_ os: String?) -> Finding {
        guard let os else { return .missing }
        return os.isEmpty ? .operatingSystemEmpty : .operatingSystem(os)
    }

    private static func loginShellFinding(_ shell: String?, execShell: String) -> Finding {
        guard let shell else { return .missing }
        guard !shell.isEmpty else { return .loginShellUnset }
        guard shell == execShell else { return .loginShellNotPosix(shell: shell, execShell: execShell) }
        return .loginShell(shell)
    }

    private static func gitFinding(_ path: String?, shellFailed: Bool, execShell: String) -> Finding {
        if shellFailed { return .gitShellFailed(execShell: execShell) }
        guard let path else { return .missing }
        return path.isEmpty ? .gitNotOnPath(execShell: execShell) : .gitFound(path: path)
    }

    private static func minisDirectoryFinding(_ state: String?) -> Finding {
        switch state {
        case "writable": return .minisWritable
        case "unwritable": return .minisUnwritable
        default: return .missing
        }
    }
}

extension RemoteExecutor {
    /// Raw output of `RemoteHostChecks.script`, sent through the framed control path so login-file output
    /// cannot reach the parser.
    public func hostCheckOutput(host: String) async throws -> String {
        try await control(host: host, script: RemoteHostChecks.script).stdoutText
    }
}
