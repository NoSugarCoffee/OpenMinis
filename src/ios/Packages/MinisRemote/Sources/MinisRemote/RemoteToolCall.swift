import Foundation

public struct RemoteShellRequest: Equatable, Sendable {
    public let command: String
    public let timeout: Duration
    public let delay: Duration
    public let detach: Bool

    public init(command: String, timeout: Duration, delay: Duration, detach: Bool) {
        self.command = command
        self.timeout = timeout
        self.delay = delay
        self.detach = detach
    }
}

public struct RemoteReadRequest: Equatable, Sendable {
    public let path: String
    public let offset: Int?
    public let lines: Int?
    public let direction: String?
    public let maxLength: Int?

    public init(path: String, offset: Int?, lines: Int?, direction: String?, maxLength: Int?) {
        self.path = path
        self.offset = offset
        self.lines = lines
        self.direction = direction
        self.maxLength = maxLength
    }
}

public struct RemoteWriteRequest: Equatable, Sendable {
    public let path: String
    public let content: String
    public let append: Bool

    public init(path: String, content: String, append: Bool) {
        self.path = path
        self.content = content
        self.append = append
    }
}

public struct RemoteEditRequest: Equatable, Sendable {
    public let path: String
    public let oldString: String
    public let newString: String
    public let replaceAll: Bool

    public init(path: String, oldString: String, newString: String, replaceAll: Bool) {
        self.path = path
        self.oldString = oldString
        self.newString = newString
        self.replaceAll = replaceAll
    }
}

public enum RemoteToolRequest: Equatable, Sendable {
    case shell(RemoteShellRequest)
    case read(RemoteReadRequest)
    case write(RemoteWriteRequest)
    case edit(RemoteEditRequest)
}

public enum RemoteFileAccess: String, CaseIterable, Equatable, Sendable {
    case read = "file_read"
    case write = "file_write"
    case edit = "file_edit"
}

/// What the host-permission sheet names: the whole command line, or the file and what the call does to it.
public enum RemotePermissionSubject: Equatable, Sendable {
    case command(String)
    case file(RemoteFileAccess, path: String)

    public var summary: String {
        switch self {
        case .command(let command): return command
        case .file(let access, let path): return "\(access.rawValue) \(path)"
        }
    }

    /// `OffloadPermissionManager` carries the subject as one string; the sheet decodes it back from `summary`.
    public init(summary: String) {
        for access in RemoteFileAccess.allCases where summary.hasPrefix(access.rawValue + " ") {
            self = .file(access, path: String(summary.dropFirst(access.rawValue.count + 1)))
            return
        }
        self = .command(summary)
    }
}

extension RemoteToolRequest {
    public var permissionSubject: RemotePermissionSubject {
        switch self {
        case .shell(let shell): return .command(shell.command)
        case .read(let read): return .file(.read, path: read.path)
        case .write(let write): return .file(.write, path: write.path)
        case .edit(let edit): return .file(.edit, path: edit.path)
        }
    }

    /// What the host-permission prompt shows the user.
    public var permissionSummary: String {
        permissionSubject.summary
    }
}

public enum RemoteToolArgumentError: Error, Equatable, Sendable {
    case missingCommand
    case missingReadPath
    case missingWriteArguments
    case missingEditArguments
    case invalid(parameter: String, reason: String)
    case unsupportedTool(String)

    /// The missing-argument wording is the local tools' own, so the model sees one message per mistake.
    public var userMessage: String {
        switch self {
        case .missingCommand:
            return "Error: Missing required 'command' parameter. Please call shell_execute again with a non-empty `command` field."
        case .missingReadPath:
            return "Error: Missing required 'path' parameter"
        case .missingWriteArguments:
            return "Error: Missing required 'path' and/or 'content' parameters"
        case .missingEditArguments:
            return "Error: Missing required parameters (path, old_string, new_string)"
        case .invalid(let parameter, let reason):
            return "Error: `\(parameter)` \(reason)."
        case .unsupportedTool(let name):
            return "Error: `\(name)` cannot run on a remote host. Only shell_execute, file_read, file_write and file_edit can."
        }
    }
}

/// Decoding and path decisions for a tool call routed to a host. Argument shapes follow the local tools
/// (`AIChatViewModel.parseToolInput`, `executeFileRead` and friends) so a call means the same on either side.
public enum RemoteToolCall {
    /// Mirrors `AIChatViewModel.defaultCommandTimeout`.
    public static let defaultTimeout: Duration = .seconds(900)
    /// A host call without a session binding starts in the login directory.
    public static let unboundWorkdir = "~"

    /// `arguments` is the tool call's decoded JSON object, as `RemoteRouting.destination` takes it.
    public static func decode(toolName: String, arguments: [String: Any]) throws -> RemoteToolRequest {
        switch toolName {
        case "shell_execute":
            guard let command = arguments["command"] as? String,
                  !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RemoteToolArgumentError.missingCommand
            }
            let timeout = try seconds(arguments["timeout"], parameter: "timeout", allowZero: false) ?? defaultTimeout
            let delay = try seconds(arguments["delay"], parameter: "delay", allowZero: true) ?? .zero
            let detach = (arguments["detach"] as? Bool) ?? false
            return .shell(RemoteShellRequest(command: command, timeout: timeout, delay: delay, detach: detach))
        case "file_read":
            guard let path = arguments["path"] as? String else { throw RemoteToolArgumentError.missingReadPath }
            return .read(RemoteReadRequest(
                path: path, offset: arguments["offset"] as? Int, lines: arguments["lines"] as? Int,
                direction: arguments["direction"] as? String, maxLength: arguments["max_length"] as? Int))
        case "file_write":
            guard let path = arguments["path"] as? String, let content = arguments["content"] as? String else {
                throw RemoteToolArgumentError.missingWriteArguments
            }
            return .write(RemoteWriteRequest(path: path, content: content, append: (arguments["append"] as? Bool) ?? false))
        case "file_edit":
            guard let path = arguments["path"] as? String,
                  let oldString = arguments["old_string"] as? String,
                  let newString = arguments["new_string"] as? String else {
                throw RemoteToolArgumentError.missingEditArguments
            }
            return .edit(RemoteEditRequest(
                path: path, oldString: oldString, newString: newString,
                replaceAll: (arguments["replace_all"] as? Bool) ?? false))
        default:
            throw RemoteToolArgumentError.unsupportedTool(toolName)
        }
    }

    /// The binding's directory applies only on the host it names; an explicit `target` elsewhere starts in `~`.
    public static func workdir(host: String, binding: SessionHostBindingValue?) -> String {
        guard let binding, binding.hostName == host else { return unboundWorkdir }
        return binding.workdir
    }

    public static func needsHome(path: String) -> Bool {
        !path.hasPrefix("/")
    }

    /// The workdir itself may start with `~`, so it is resolved against the home first.
    public static func absolutePath(_ path: String, workdir: String, home: String) -> String {
        let resolvedWorkdir = RemoteRouting.resolveRemotePath(workdir, workdir: home, home: home)
        return RemoteRouting.resolveRemotePath(path, workdir: resolvedWorkdir, home: home)
    }

    /// `RemoteExecutor.run` throws `CancellationError` only when the command did not and will not start, so a
    /// stopped shell call can say so; a file operation cut short may or may not have reached the host.
    public static func cancelledMessage(for request: RemoteToolRequest, host: String) -> String {
        guard case .shell = request else {
            return "Error: cancelled before `\(host)` returned a result; nothing was reported back."
        }
        return "Error: stopped before the command started on `\(host)`; it did not run."
    }

    /// Every message names a next step (spec §8) and starts with `Error:` like the local tools' failures.
    public static func errorMessage(_ error: Error) -> String {
        switch error {
        case RemoteRoutingError.unknownTarget(let target, let available):
            guard !available.isEmpty else {
                return "Error: unknown target `\(target)`. No remote hosts are configured; add one in Settings → Remote Hosts, or pass 'local' for this phone."
            }
            return "Error: unknown target `\(target)`. Configured hosts: \(available.joined(separator: ", ")). Pass one of them, or 'local' for this phone."
        case let argumentError as RemoteToolArgumentError:
            return argumentError.userMessage
        case let fileError as RemoteFileError:
            return fileError.userMessage
        case let hostError as RemoteHostError:
            return "Error: " + hostError.userMessage
        case let runError as RemoteRunError:
            return "Error: " + runError.userMessage
        case RemoteExecError.timedOut(let host, let after):
            return "Error: Host `\(host)` did not answer within \(after). Check the host's load and network, then retry."
        default:
            return "Error: \(String(describing: error))"
        }
    }

    private static func seconds(_ value: Any?, parameter: String, allowZero: Bool) throws -> Duration? {
        guard let number = value as? NSNumber else { return nil }
        let seconds = number.doubleValue
        guard seconds.isFinite, allowZero ? seconds >= 0 : seconds > 0 else {
            throw RemoteToolArgumentError.invalid(
                parameter: parameter,
                reason: allowZero ? "must be zero or a positive number of seconds" : "must be a positive number of seconds")
        }
        return .milliseconds(Int64((seconds * 1000).rounded()))
    }
}

extension RemoteExecResult {
    public var handle: RemoteRunHandle {
        switch self {
        case .finished(_, _, let handle), .detached(let handle), .disconnected(_, let handle),
             .failed(_, let handle, _):
            return handle
        }
    }

    /// Lets the app redact secrets before `RemoteToolOutput.format` truncates, so the redaction notice is
    /// counted against the limit.
    public func mapOutput(_ transform: (String) -> String) -> RemoteExecResult {
        switch self {
        case .finished(let output, let outcome, let handle):
            return .finished(output: transform(output), outcome: outcome, handle: handle)
        case .detached:
            return self
        case .disconnected(let partialOutput, let handle):
            return .disconnected(partialOutput: transform(partialOutput), handle: handle)
        case .failed(let partialOutput, let handle, let error):
            return .failed(partialOutput: transform(partialOutput), handle: handle, error: error)
        }
    }
}

public enum RemoteToolOutput {
    public static let unknownOS = "OS not yet known"

    public static let deviceCommandsSentence =
        "Device commands (apple-*, minis-*, ffmpeg) always run on this phone, whatever `target` says; call them on their own, not combined with host commands."

    public static let fileTransferSentence =
        "To move files between this phone and the host, run `minis-remote cp <src> <dst>` (write the host side as `<host>:<path>`, the phone side under /var/minis); the phone has no scp or rsync and none is needed."

    /// A2 step 1 (A2 spec §3): the host's browser is driven through shell_execute, so the agent learns about it
    /// here instead of through a new tool. The check stays with the agent because hosts without ego-browser are fine.
    public static let hostBrowserSentence =
        "For web pages that need the user's logins, check `command -v ego-browser` on the host; if it is there, run `ego-browser skill` once for its guide, then drive the host's browser with `ego-browser nodejs <<'EOF' … EOF` through shell_execute. To look at a screenshot, save it to a host file, copy it here with `minis-remote cp`, then open it with read_image."

    public static func systemPromptLine(binding: SessionHostBindingValue, os: String) -> String {
        "You are working on host `\(binding.hostName)` (\(os)) in `\(binding.workdir)`."
    }

    /// On-device acceptance saw a bound sub agent pass `target: "local"` for host work and get the phone's iSH,
    /// so the default is stated outright rather than implied.
    public static func hostRoutingSentence(hostName: String) -> String {
        "shell_execute and the file tools (file_read, file_write, file_edit) run on host `\(hostName)` by default; leave `target` unset for host work. Set `target: \"local\"` only to touch this phone's own /var/minis files."
    }

    public static func systemPromptFragment(binding: SessionHostBindingValue, os: String?) -> String {
        "\n\n" + systemPromptLine(binding: binding, os: os ?? unknownOS) + " "
            + hostRoutingSentence(hostName: binding.hostName) + " " + deviceCommandsSentence
            + " " + fileTransferSentence + " " + hostBrowserSentence
    }

    /// The local file_write wording, so a host write reads the same as a phone write.
    public static func writeSummary(path: String, content: String, appended: Bool) -> String {
        "\(appended ? "Appended" : "Wrote") to \(path) (\(content.utf8.count) bytes)"
    }

    public static func isSuccess(_ result: RemoteExecResult) -> Bool {
        switch result {
        case .finished(_, .exited(0), _), .detached: return true
        case .finished, .disconnected, .failed: return false
        }
    }

    /// Spec §4.4: every result, partial ones included, starts with the run id and output path so they survive in
    /// the chat history. The whole text fits in `limit`, so the app's own cap never truncates it a second time.
    public static func format(_ result: RemoteExecResult, limit: Int) -> String {
        let handle = result.handle
        let header = "run_id: \(handle.runId)\noutput: \(handle.outputPath)\n"
        let exitCheck = "Check it later with shell_execute: `cat \(handle.exitPath)` (the file appears when the command ends)."
        let status: String
        let body: String
        switch result {
        case .finished(let output, let outcome, _):
            status = statusLine(outcome)
            body = output
        case .detached:
            return header + "exit: \(handle.exitPath)\n"
                + "status: running in the background. Follow it with shell_execute: `tail -n 50 \(handle.outputPath)` for output, `cat \(handle.exitPath)` for the exit code (the file appears when the command ends)."
        case .disconnected(let partialOutput, _):
            status = "status: host disconnected; command may still be running. \(exitCheck)\n"
            body = partialOutput
        case .failed(let partialOutput, _, let error):
            status = "status: \(error.message) The command may still be running. \(exitCheck)\n"
            body = partialOutput
        }
        let prefix = header + status
        guard !body.isEmpty else { return prefix + "(no output)" }
        return prefix + fitted(body, outputPath: handle.outputPath, budget: limit - prefix.count)
    }

    private static func statusLine(_ outcome: RemoteRunOutcome) -> String {
        switch outcome {
        case .exited(let code):
            return "exit_code: \(code)\n"
        case .cancelled:
            return "status: cancelled (timed out or stopped). A process that daemonised itself may survive the cancel.\n"
        case .abnormal:
            return "status: terminated abnormally (the process is gone without an exit code, for example after a host reboot)\n"
        case .running:
            return "status: running\n"
        }
    }

    /// The local truncation trailer points at a phone file with `minis_url` and file_read; the host file is not
    /// under /var/minis, so this one suggests shell commands on the host instead.
    private static func fitted(_ body: String, outputPath: String, budget: Int) -> String {
        guard body.count > budget else { return body }
        let hint = "\nRead parts of it with shell_execute, for example `tail -n 200 \(outputPath)` or `sed -n '100,200p' \(outputPath)`."
        let firstTry = RemoteRunState.truncateForModel(body, outputPath: outputPath, limit: max(0, budget - hint.count))
        let excess = firstTry.count + hint.count - budget
        guard excess > 0 else { return firstTry + hint }
        // truncateForModel keeps two halves of limit / 2, so an odd limit loses one character to rounding.
        let shrunk = RemoteRunState.truncateForModel(
            body, outputPath: outputPath, limit: max(0, budget - hint.count - excess - 1))
        return shrunk + hint
    }
}

/// What a routed call hands the dispatcher. `stoppedByUser` marks a run the user stopped from its tool card;
/// the dispatcher then treats it as a cancelled tool, as it does a stopped local shell command.
public struct RemoteToolOutcome: Equatable, Sendable {
    /// Matches the notice the dispatcher puts on a stopped local command, so the model sees it exactly once.
    public static let userCancelledNotice =
        "<system-reminder>The user cancelled this operation. The returned result may be incomplete.</system-reminder>\n"

    public let output: String
    public let success: Bool
    public let stoppedByUser: Bool

    public init(output: String, success: Bool, stoppedByUser: Bool) {
        self.output = stoppedByUser ? Self.userCancelledNotice + output : output
        self.success = success
        self.stoppedByUser = stoppedByUser
    }
}
