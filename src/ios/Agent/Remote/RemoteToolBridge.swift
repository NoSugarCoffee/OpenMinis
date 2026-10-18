import Foundation
import MinisRemote

private let logger = AppLogger(category: "RemoteHost")

/// Routes shell_execute and the file tools of a host-bound session (or a call with a host `target`) to that
/// host. A call routed to a host never falls through to the phone: every failure comes back as its result.
@MainActor
enum RemoteToolBridge {
    private static let routedTools: Set<String> = ["shell_execute", "file_read", "file_write", "file_edit"]

    /// nil means "not remote — take the existing local path". A cancelled shell run still returns its run id and
    /// partial output; the dispatcher appends the cancel notice when the user stopped the turn.
    static func handle(
        toolName: String, argsJson: String, sessionId: String?, onOutput: @Sendable (String) -> Void
    ) async -> (output: String, success: Bool)? {
        await handle(
            toolName: toolName, argsJson: argsJson, sessionId: sessionId, onOutput: onOutput,
            wiring: RemoteAppWiring.shared)
    }

    static func handle(
        toolName: String, argsJson: String, sessionId: String?, onOutput: @Sendable (String) -> Void,
        wiring: RemoteAppWiring
    ) async -> (output: String, success: Bool)? {
        switch route(toolName: toolName, argsJson: argsJson, sessionId: sessionId, wiring: wiring) {
        case .local:
            return nil
        case .refused(let message):
            return (message, false)
        case .remote(let host, let request, let services, let binding):
            return await runPermitted(
                request, toolName: toolName, host: host, services: services, binding: binding, sessionId: sessionId,
                wiring: wiring, onOutput: onOutput)
        }
    }

    private static func runPermitted(
        _ request: RemoteToolRequest, toolName: String, host: String, services: RemoteServices,
        binding: SessionHostBindingValue?, sessionId: String?, wiring: RemoteAppWiring,
        onOutput: @Sendable (String) -> Void
    ) async -> (output: String, success: Bool) {
        let permission = await wiring.checkPermission(
            host: host, sessionId: sessionId, summary: request.permissionSummary)
        if case .denied(let message) = permission { return (message, false) }

        logger.info("\(toolName) → \(host)")
        do {
            return try await run(
                request, host: host, workdir: RemoteToolCall.workdir(host: host, binding: binding),
                services: services, onOutput: onOutput)
        } catch is CancellationError {
            return (RemoteToolCall.cancelledMessage(for: request, host: host), false)
        } catch {
            logger.error("\(toolName) on \(host) failed: \(error)")
            return (RemoteToolCall.errorMessage(error), false)
        }
    }

    /// Whether `handle` answers this call rather than the local tool; the same decision, made without running
    /// anything, so code after the call (the tool snapshot) can tell a host call from a phone one.
    static func answersCall(toolName: String, argsJson: String, sessionId: String?) -> Bool {
        answersCall(toolName: toolName, argsJson: argsJson, sessionId: sessionId, wiring: RemoteAppWiring.shared)
    }

    static func answersCall(toolName: String, argsJson: String, sessionId: String?, wiring: RemoteAppWiring) -> Bool {
        guard case .local = route(toolName: toolName, argsJson: argsJson, sessionId: sessionId, wiring: wiring) else {
            return true
        }
        return false
    }

    private enum Route {
        case local
        /// Answered with an error before any host is contacted.
        case refused(String)
        case remote(host: String, request: RemoteToolRequest, services: RemoteServices, binding: SessionHostBindingValue?)
    }

    private static func route(
        toolName: String, argsJson: String, sessionId: String?, wiring: RemoteAppWiring
    ) -> Route {
        guard routedTools.contains(toolName),
              let arguments = (try? JSONSerialization.jsonObject(with: Data(argsJson.utf8))) as? [String: Any]
        else { return .local }
        let services: RemoteServices
        switch wiring.services {
        case .success(let ready): services = ready
        case .failure(let error): return .refused(error.userMessage)
        }
        let binding = wiring.binding(sessionId: sessionId)
        do {
            let destination = try RemoteRouting.destination(
                toolName: toolName, arguments: arguments, binding: binding,
                knownHosts: services.store.hosts.map(\.name))
            guard case .remote(let host) = destination else { return .local }
            let request = try RemoteToolCall.decode(toolName: toolName, arguments: arguments)
            return .remote(host: host, request: request, services: services, binding: binding)
        } catch {
            return .refused(RemoteToolCall.errorMessage(error))
        }
    }

    static func formatResult(_ r: RemoteExecResult, limit: Int) -> String {
        RemoteToolOutput.format(r, limit: limit)
    }

    static func systemPromptLine(binding: SessionHostBindingValue, os: String) -> String {
        RemoteToolOutput.systemPromptLine(binding: binding, os: os)
    }

    /// Redacts before formatting so the redaction notice counts against `limit`, like the local shell result
    /// (AIChatViewModel+ConcurrentTools.swift, `EnvVarRedactor.redactIfEnabled`).
    static func shellResultText(
        _ result: RemoteExecResult, limit: Int, redact: (String) -> (String, Int)
    ) -> String {
        var hits = 0
        let redacted = result.mapOutput { output in
            let (masked, count) = redact(output)
            hits += count
            return masked
        }
        if hits > 0 {
            logger.info("[EnvVarRedact] remote shell_execute: masked \(hits) env-var value(s) in tool result")
        }
        return formatResult(redacted, limit: limit)
    }

    private static func run(
        _ request: RemoteToolRequest, host: String, workdir: String, services: RemoteServices,
        onOutput: @Sendable (String) -> Void
    ) async throws -> (output: String, success: Bool) {
        switch request {
        case .shell(let shell):
            if shell.delay > .zero { try await Task.sleep(for: shell.delay) }
            let result = try await services.executor.run(
                host: host, workdir: workdir, command: shell.command, timeout: shell.timeout, detach: shell.detach,
                onOutput: onOutput)
            let text = shellResultText(
                result, limit: AIChatViewModel.kMaxToolResultChars, redact: EnvVarRedactor.redactIfEnabled)
            return (text, RemoteToolOutput.isSuccess(result))
        case .read(let read):
            let path = try await absolutePath(read.path, host: host, workdir: workdir, services: services)
            let text = try await services.files.read(
                host: host, path: path, offset: read.offset, lines: read.lines, direction: read.direction,
                maxLength: read.maxLength, defaultMaxLength: AIChatViewModel.kMaxToolResultChars)
            return (text, true)
        case .write(let write):
            let path = try await absolutePath(write.path, host: host, workdir: workdir, services: services)
            if write.append {
                try await services.files.append(host: host, path: path, content: write.content)
            } else {
                try await services.files.write(host: host, path: path, content: write.content)
            }
            return (RemoteToolOutput.writeSummary(path: path, content: write.content, appended: write.append), true)
        case .edit(let edit):
            let path = try await absolutePath(edit.path, host: host, workdir: workdir, services: services)
            let summary = try await services.files.edit(
                host: host, path: path, oldString: edit.oldString, newString: edit.newString,
                replaceAll: edit.replaceAll)
            return (summary, true)
        }
    }

    private static func absolutePath(
        _ path: String, host: String, workdir: String, services: RemoteServices
    ) async throws -> String {
        guard RemoteToolCall.needsHome(path: path) else { return path }
        let home = try await services.executor.homeDirectory(host: host)
        return RemoteToolCall.absolutePath(path, workdir: workdir, home: home)
    }
}
