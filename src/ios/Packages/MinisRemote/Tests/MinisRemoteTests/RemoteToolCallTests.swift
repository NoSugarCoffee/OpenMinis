import Foundation
import XCTest
@testable import MinisRemote

private let handle = RemoteRunHandle(host: "mini", runId: "abc123", offset: 0)
private let runHeader = "run_id: abc123\noutput: ~/.minis/runs/abc123/out\n"

private func allResultCases(output: String) -> [RemoteExecResult] {
    [
        .finished(output: output, outcome: .exited(0), handle: handle),
        .finished(output: output, outcome: .exited(2), handle: handle),
        .finished(output: output, outcome: .cancelled, handle: handle),
        .finished(output: output, outcome: .abnormal, handle: handle),
        .detached(handle: handle),
        .disconnected(partialOutput: output, handle: handle),
        .failed(partialOutput: output, handle: handle, error: RemoteRunFailure(message: "Host `mini` is not configured.")),
    ]
}

private func decode(_ toolName: String, _ json: String) throws -> RemoteToolRequest {
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
    return try RemoteToolCall.decode(toolName: toolName, arguments: XCTUnwrap(object as? [String: Any]))
}

private func decodeError(_ toolName: String, _ json: String) -> RemoteToolArgumentError? {
    do {
        _ = try decode(toolName, json)
        return nil
    } catch {
        return error as? RemoteToolArgumentError
    }
}

final class RemoteToolOutputTests: XCTestCase {
    func testResultAlwaysStartsWithRunIdAndPath() {
        for result in allResultCases(output: "hello\n") {
            XCTAssertTrue(
                RemoteToolOutput.format(result, limit: 15_000).hasPrefix(runHeader), "\(result)")
        }
    }

    func testTruncatedResultStillStartsWithRunIdAndFitsTheLimit() {
        let huge = "FIRST\n" + String(repeating: "x", count: 50_000) + "\nLAST"
        for result in allResultCases(output: huge) {
            let text = RemoteToolOutput.format(result, limit: 15_000)
            XCTAssertTrue(text.hasPrefix(runHeader), "\(result)")
            XCTAssertLessThanOrEqual(text.count, 15_000, "\(result)")
        }
    }

    func testDisconnectedResultSaysMayStillBeRunning() {
        let text = RemoteToolOutput.format(.disconnected(partialOutput: "partial", handle: handle), limit: 15_000)
        XCTAssertTrue(text.contains("host disconnected; command may still be running"), text)
        XCTAssertTrue(text.contains("partial"), text)
    }

    func testFailedResultCarriesTheReasonAndMayStillBeRunning() {
        let failure = RemoteRunFailure(message: "Host `mini` rejected this device's SSH key.")
        let text = RemoteToolOutput.format(.failed(partialOutput: "so far", handle: handle, error: failure), limit: 15_000)
        XCTAssertTrue(text.contains(failure.message), text)
        XCTAssertTrue(text.contains("may still be running"), text)
        XCTAssertTrue(text.contains("so far"), text)
    }

    func testFinishedResultReportsExitCodeAndOutput() {
        let text = RemoteToolOutput.format(
            .finished(output: "built\n", outcome: .exited(3), handle: handle), limit: 15_000)
        XCTAssertEqual(text, runHeader + "exit_code: 3\nbuilt\n")
    }

    func testEmptyOutputSaysSo() {
        let text = RemoteToolOutput.format(.finished(output: "", outcome: .exited(0), handle: handle), limit: 15_000)
        XCTAssertEqual(text, runHeader + "exit_code: 0\n(no output)")
    }

    func testCancelledAndAbnormalOutcomesAreNamed() {
        let cancelled = RemoteToolOutput.format(.finished(output: "x", outcome: .cancelled, handle: handle), limit: 15_000)
        XCTAssertTrue(cancelled.contains("status: cancelled"), cancelled)
        let abnormal = RemoteToolOutput.format(.finished(output: "x", outcome: .abnormal, handle: handle), limit: 15_000)
        XCTAssertTrue(abnormal.contains("terminated abnormally"), abnormal)
    }

    func testDetachedResultNamesTheExitFile() {
        let text = RemoteToolOutput.format(.detached(handle: handle), limit: 15_000)
        XCTAssertTrue(text.contains("exit: ~/.minis/runs/abc123/exit"), text)
        XCTAssertTrue(text.contains("tail -n 50 ~/.minis/runs/abc123/out"), text)
    }

    func testTruncationTrailerPointsAtHostFileAndShellCommands() {
        let huge = "FIRST\n" + String(repeating: "y", count: 40_000) + "\nLAST"
        let text = RemoteToolOutput.format(
            .finished(output: huge, outcome: .exited(0), handle: handle), limit: 15_000)
        XCTAssertTrue(text.contains("FIRST\n"), "head kept")
        XCTAssertTrue(text.contains("\nLAST"), "tail kept")
        XCTAssertTrue(text.contains("[OUTPUT TRUNCATED] Full output (\(huge.count) chars) saved to: ~/.minis/runs/abc123/out"), text.suffix(300).description)
        XCTAssertTrue(text.contains("tail -n 200 ~/.minis/runs/abc123/out"), text.suffix(300).description)
        XCTAssertTrue(text.contains("sed -n '100,200p' ~/.minis/runs/abc123/out"), text.suffix(300).description)
        XCTAssertFalse(text.contains("minis_url"))
        XCTAssertFalse(text.contains("Use file_read"))
    }

    func testSuccessOnlyForExitZeroAndDetached() {
        let verdicts = allResultCases(output: "o").map(RemoteToolOutput.isSuccess)
        XCTAssertEqual(verdicts, [true, false, false, false, true, false, false])
    }

    func testMapOutputTransformsEveryOutputAndKeepsTheHandle() {
        let mapped = allResultCases(output: "secret").map { $0.mapOutput { $0.uppercased() } }
        for result in mapped {
            let text = RemoteToolOutput.format(result, limit: 15_000)
            XCTAssertFalse(text.contains("secret"), text)
            XCTAssertTrue(text.hasPrefix(runHeader), text)
        }
    }

    func testSystemPromptLineFormat() {
        XCTAssertEqual(
            RemoteToolOutput.systemPromptLine(
                binding: SessionHostBindingValue(hostName: "mini", workdir: "/Users/x/code"), os: "Darwin"),
            "You are working on host `mini` (Darwin) in `/Users/x/code`.")
    }

    func testDeviceCommandsSentenceIsVerbatim() {
        XCTAssertEqual(
            RemoteToolOutput.deviceCommandsSentence,
            "Device commands (apple-*, minis-*, ffmpeg) always run on this phone, whatever `target` says; call them on their own, not combined with host commands.")
    }

    func testFileTransferSentenceNamesMinisRemoteCp() {
        XCTAssertEqual(
            RemoteToolOutput.fileTransferSentence,
            "To move files between this phone and the host, run `minis-remote cp <src> <dst>` (write the host side as `<host>:<path>`, the phone side under /var/minis); the phone has no scp or rsync and none is needed.")
    }

    func testHostRoutingSentenceMakesTheBoundHostTheDefault() {
        XCTAssertEqual(
            RemoteToolOutput.hostRoutingSentence(hostName: "linux"),
            "shell_execute and the file tools (file_read, file_write, file_edit) run on host `linux` by default; leave `target` unset for host work. Set `target: \"local\"` only to touch this phone's own /var/minis files.")
    }

    func testSystemPromptFragmentStatesTheRoutingRuleAndNamesUnknownOS() {
        let binding = SessionHostBindingValue(hostName: "linux", workdir: "/home/dev/code/demo")
        XCTAssertEqual(
            RemoteToolOutput.systemPromptFragment(binding: binding, os: "Linux"),
            "\n\nYou are working on host `linux` (Linux) in `/home/dev/code/demo`. "
                + "shell_execute and the file tools (file_read, file_write, file_edit) run on host `linux` by default; leave `target` unset for host work. Set `target: \"local\"` only to touch this phone's own /var/minis files. "
                + "Device commands (apple-*, minis-*, ffmpeg) always run on this phone, whatever `target` says; call them on their own, not combined with host commands. "
                + "To move files between this phone and the host, run `minis-remote cp <src> <dst>` (write the host side as `<host>:<path>`, the phone side under /var/minis); the phone has no scp or rsync and none is needed.")
        XCTAssertEqual(
            RemoteToolOutput.systemPromptFragment(binding: binding, os: nil),
            "\n\nYou are working on host `linux` (OS not yet known) in `/home/dev/code/demo`. "
                + RemoteToolOutput.hostRoutingSentence(hostName: "linux") + " " + RemoteToolOutput.deviceCommandsSentence
                + " " + RemoteToolOutput.fileTransferSentence)
    }

    func testBoundShellNoteOverridesTheISHWording() {
        let binding = SessionHostBindingValue(hostName: "linux", workdir: "/home/dev/code/demo")
        XCTAssertEqual(
            RemoteToolSchema.boundShellNote(binding: binding, os: "Linux"),
            "In this chat, commands do not run in iSH: they run on host `linux` (Linux) in `/home/dev/code/demo` unless `target: \"local\"` is set.")
        XCTAssertEqual(
            RemoteToolSchema.boundShellNote(binding: binding, os: nil),
            "In this chat, commands do not run in iSH: they run on host `linux` (OS not yet known) in `/home/dev/code/demo` unless `target: \"local\"` is set.")
    }

    func testWriteSummaryMatchesLocalWording() {
        XCTAssertEqual(RemoteToolOutput.writeSummary(path: "/a", content: "ü\n", appended: false), "Wrote to /a (3 bytes)")
        XCTAssertEqual(RemoteToolOutput.writeSummary(path: "/a", content: "xy", appended: true), "Appended to /a (2 bytes)")
    }

    func testSchemaAddsNothingWithoutConfiguredHosts() {
        for tool in ["shell_execute", "file_read", "file_write", "file_edit"] {
            XCTAssertEqual(RemoteToolSchema.additions(toolName: tool, hostsConfigured: false), [], tool)
        }
    }

    func testSchemaAddsTargetToTheFourToolsAndDetachToShell() {
        XCTAssertEqual(RemoteToolSchema.additions(toolName: "shell_execute", hostsConfigured: true).map(\.name), ["target", "detach"])
        for tool in ["file_read", "file_write", "file_edit"] {
            XCTAssertEqual(RemoteToolSchema.additions(toolName: tool, hostsConfigured: true).map(\.name), ["target"], tool)
        }
        XCTAssertTrue(RemoteToolSchema.additions(toolName: "browser_use", hostsConfigured: true).isEmpty)
        let target = RemoteToolSchema.additions(toolName: "file_read", hostsConfigured: true)[0]
        XCTAssertEqual(target.kind, .string)
        XCTAssertEqual(
            target.description,
            "Leave unset for the default: the host this chat is bound to, or this phone if the chat has no host. Never needed for work on the bound host. 'local' runs on this phone (iSH, /var/minis); a configured host name runs on that host.")
        XCTAssertEqual(RemoteToolSchema.additions(toolName: "shell_execute", hostsConfigured: true)[1].kind, .boolean)
    }
}

final class RemoteToolCallTests: XCTestCase {
    func testShellDefaultsMatchLocal() throws {
        XCTAssertEqual(
            try decode("shell_execute", #"{"command":"make"}"#),
            .shell(RemoteShellRequest(command: "make", timeout: .seconds(900), delay: .zero, detach: false)))
    }

    func testShellReadsTimeoutDelayAndDetach() throws {
        XCTAssertEqual(
            try decode("shell_execute", #"{"command":"make","timeout":60,"delay":2.5,"detach":true}"#),
            .shell(RemoteShellRequest(command: "make", timeout: .seconds(60), delay: .milliseconds(2500), detach: true)))
    }

    func testShellRejectsEmptyCommand() {
        XCTAssertEqual(decodeError("shell_execute", #"{"command":"  "}"#), .missingCommand)
        XCTAssertEqual(decodeError("shell_execute", #"{}"#), .missingCommand)
    }

    func testShellRejectsNonPositiveTimeoutAndNegativeDelay() {
        XCTAssertEqual(
            decodeError("shell_execute", #"{"command":"x","timeout":0}"#),
            .invalid(parameter: "timeout", reason: "must be a positive number of seconds"))
        XCTAssertEqual(
            decodeError("shell_execute", #"{"command":"x","delay":-1}"#),
            .invalid(parameter: "delay", reason: "must be zero or a positive number of seconds"))
    }

    func testFileArguments() throws {
        XCTAssertEqual(
            try decode("file_read", #"{"path":"a.txt","offset":3,"lines":10,"direction":"tail","max_length":500}"#),
            .read(RemoteReadRequest(path: "a.txt", offset: 3, lines: 10, direction: "tail", maxLength: 500)))
        XCTAssertEqual(
            try decode("file_read", #"{"path":"/a"}"#),
            .read(RemoteReadRequest(path: "/a", offset: nil, lines: nil, direction: nil, maxLength: nil)))
        XCTAssertEqual(
            try decode("file_write", #"{"path":"/a","content":"x","append":true}"#),
            .write(RemoteWriteRequest(path: "/a", content: "x", append: true)))
        XCTAssertEqual(
            try decode("file_edit", #"{"path":"/a","old_string":"x","new_string":"y"}"#),
            .edit(RemoteEditRequest(path: "/a", oldString: "x", newString: "y", replaceAll: false)))
    }

    func testMissingFileArgumentsUseTheLocalMessages() {
        XCTAssertEqual(
            decodeError("file_read", #"{}"#)?.userMessage, "Error: Missing required 'path' parameter")
        XCTAssertEqual(
            decodeError("file_write", #"{"path":"/a"}"#)?.userMessage,
            "Error: Missing required 'path' and/or 'content' parameters")
        XCTAssertEqual(
            decodeError("file_edit", #"{"path":"/a","old_string":"x"}"#)?.userMessage,
            "Error: Missing required parameters (path, old_string, new_string)")
    }

    func testPermissionSummaryNamesTheOperation() {
        XCTAssertEqual(RemoteToolRequest.shell(RemoteShellRequest(command: "make", timeout: .seconds(1), delay: .zero, detach: false)).permissionSummary, "make")
        XCTAssertEqual(RemoteToolRequest.read(RemoteReadRequest(path: "a", offset: nil, lines: nil, direction: nil, maxLength: nil)).permissionSummary, "file_read a")
        XCTAssertEqual(RemoteToolRequest.write(RemoteWriteRequest(path: "a", content: "x", append: true)).permissionSummary, "file_write a")
        XCTAssertEqual(RemoteToolRequest.edit(RemoteEditRequest(path: "a", oldString: "x", newString: "y", replaceAll: false)).permissionSummary, "file_edit a")
    }

    func testPermissionSubjectRoundTripsThroughTheSummary() {
        let requests: [(RemoteToolRequest, RemotePermissionSubject)] = [
            (.shell(RemoteShellRequest(command: "uname -a && pwd && git log --oneline", timeout: .seconds(1), delay: .zero, detach: false)),
             .command("uname -a && pwd && git log --oneline")),
            (.read(RemoteReadRequest(path: "src/a b.txt", offset: nil, lines: nil, direction: nil, maxLength: nil)),
             .file(.read, path: "src/a b.txt")),
            (.write(RemoteWriteRequest(path: "/tmp/x", content: "x", append: false)), .file(.write, path: "/tmp/x")),
            (.edit(RemoteEditRequest(path: "~/y", oldString: "x", newString: "y", replaceAll: false)), .file(.edit, path: "~/y")),
        ]
        for (request, subject) in requests {
            XCTAssertEqual(request.permissionSubject, subject)
            XCTAssertEqual(RemotePermissionSubject(summary: request.permissionSummary), subject)
        }
        XCTAssertEqual(RemotePermissionSubject(summary: "-v && ls"), .command("-v && ls"))
    }

    func testUnsupportedToolIsAnError() {
        XCTAssertEqual(decodeError("browser_use", #"{}"#), .unsupportedTool("browser_use"))
    }

    func testWorkdirIsTheBindingsOnlyForTheBoundHost() {
        let binding = SessionHostBindingValue(hostName: "mini", workdir: "~/code")
        XCTAssertEqual(RemoteToolCall.workdir(host: "mini", binding: binding), "~/code")
        XCTAssertEqual(RemoteToolCall.workdir(host: "other", binding: binding), "~")
        XCTAssertEqual(RemoteToolCall.workdir(host: "mini", binding: nil), "~")
    }

    func testAbsolutePathResolvesAgainstTildeWorkdir() {
        XCTAssertEqual(
            RemoteToolCall.absolutePath("src/a b.txt", workdir: "~/code", home: "/home/dev"),
            "/home/dev/code/src/a b.txt")
        XCTAssertEqual(RemoteToolCall.absolutePath("~/x", workdir: "/srv", home: "/home/dev"), "/home/dev/x")
        XCTAssertEqual(RemoteToolCall.absolutePath("/etc/hosts", workdir: "/srv", home: "/home/dev"), "/etc/hosts")
    }

    func testOnlyRelativePathsNeedTheHome() {
        XCTAssertFalse(RemoteToolCall.needsHome(path: "/etc/hosts"))
        XCTAssertTrue(RemoteToolCall.needsHome(path: "a"))
        XCTAssertTrue(RemoteToolCall.needsHome(path: "~/a"))
    }

    func testUnknownTargetMessageListsHosts() {
        XCTAssertEqual(
            RemoteToolCall.errorMessage(RemoteRoutingError.unknownTarget("old", available: ["mini", "box"])),
            "Error: unknown target `old`. Configured hosts: mini, box. Pass one of them, or 'local' for this phone.")
        XCTAssertEqual(
            RemoteToolCall.errorMessage(RemoteRoutingError.unknownTarget("old", available: [])),
            "Error: unknown target `old`. No remote hosts are configured; add one in Settings → Remote Hosts, or pass 'local' for this phone.")
    }

    func testCancelledShellSaysTheCommandDidNotRunAndFileToolsSayNothingCameBack() {
        let shell = RemoteToolRequest.shell(RemoteShellRequest(command: "make", timeout: .seconds(1), delay: .zero, detach: false))
        let write = RemoteToolRequest.write(RemoteWriteRequest(path: "a", content: "x", append: false))
        XCTAssertEqual(
            RemoteToolCall.cancelledMessage(for: shell, host: "mini"),
            "Error: stopped before the command started on `mini`; it did not run.")
        XCTAssertEqual(
            RemoteToolCall.cancelledMessage(for: write, host: "mini"),
            "Error: cancelled before `mini` returned a result; nothing was reported back.")
    }

    func testErrorMessagesUsePackageWording() {
        XCTAssertEqual(
            RemoteToolCall.errorMessage(RemoteHostError.unreachable(host: "mini")),
            "Error: Host `mini` unreachable — is Tailscale on?")
        XCTAssertEqual(
            RemoteToolCall.errorMessage(RemoteFileError.notFound(path: "/a")),
            "Error: No such file on the host: /a")
        XCTAssertEqual(
            RemoteToolCall.errorMessage(RemoteRunError.workingDirectoryNotFound(path: "/x", host: "mini")),
            "Error: working directory `/x` not found on `mini`. Create it on the host or switch the session to an existing directory.")
        XCTAssertTrue(
            RemoteToolCall.errorMessage(RemoteExecError.timedOut(host: "mini", after: .seconds(10)))
                .hasPrefix("Error: Host `mini` did not answer within"))
    }
}

final class RemoteToolOutcomeTests: XCTestCase {
    func testStoppedRunIsMarkedCancelledWithOneNotice() {
        let outcome = RemoteToolOutcome(output: "run_id: r\nstatus: cancelled", success: false, stoppedByUser: true)
        XCTAssertTrue(outcome.stoppedByUser)
        XCTAssertFalse(outcome.success)
        XCTAssertEqual(
            outcome.output,
            "<system-reminder>The user cancelled this operation. The returned result may be incomplete.</system-reminder>\nrun_id: r\nstatus: cancelled")
        XCTAssertEqual(outcome.output.components(separatedBy: "The user cancelled this operation").count, 2)
    }

    func testRunNotStoppedIsUnchanged() {
        let outcome = RemoteToolOutcome(output: "run_id: r\nexit_code: 0\nok", success: true, stoppedByUser: false)
        XCTAssertEqual(outcome.output, "run_id: r\nexit_code: 0\nok")
        XCTAssertTrue(outcome.success)
        XCTAssertFalse(outcome.stoppedByUser)
    }
}
