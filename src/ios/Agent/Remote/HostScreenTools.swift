import Foundation
import MinisRemote

private let logger = AppLogger(category: "HostScreen")

/// Runs `host_screen_capture` and `host_screen_input` (A3 spec §4.4) on the bound host's screen session.
@MainActor
enum HostScreenTools {
    /// Long enough for a click's effect (a menu, a window) to be drawn before the follow-up capture.
    static let settleBeforeCapture: Duration = .milliseconds(600)

    static func definitions(boundHost: RemoteBoundHost?) -> [AgentToolDefinition] {
        guard boundHost != nil else { return [] }
        let title = AgentToolParam(
            type: .string,
            description: "A concise 5-10 word summary of what this tool call does, shown to the user. Use the same language as the user.")
        let inputParameters = Dictionary(
            uniqueKeysWithValues: ScreenToolLogic.inputParameters.map { ($0.name, AgentToolParam(type: paramType($0.kind), description: $0.description)) })
        return [
            AgentToolDefinition(
                name: ScreenToolLogic.captureToolName, description: ScreenToolLogic.captureDescription,
                parameters: ["tool_title": title], required: ["tool_title"], propertyOrdering: ["tool_title"]),
            AgentToolDefinition(
                name: ScreenToolLogic.inputToolName, description: ScreenToolLogic.inputDescription,
                parameters: inputParameters.merging(["tool_title": title]) { current, _ in current },
                required: ["tool_title"] + ScreenToolLogic.inputRequired,
                propertyOrdering: ["tool_title"] + ScreenToolLogic.inputParameters.map(\.name)),
        ]
    }

    /// nil when `toolName` is not a screen tool. `bindingSessionId` decides the host; `ownSessionId` owns the
    /// saved capture, so read_image in the same session finds it.
    static func run(
        toolName: String, arguments: [String: Any], bindingSessionId: String?, ownSessionId: String?,
        wiring: RemoteAppWiring
    ) async -> (output: String, success: Bool)? {
        guard ScreenToolLogic.toolNames.contains(toolName) else { return nil }
        guard let host = wiring.boundHost(sessionId: bindingSessionId)?.binding.hostName else {
            return ("Error: \(toolName) works only in a chat bound to a host. Bind this chat to a host first.", false)
        }
        let session = HostScreenSessions.shared.session(host: host)
        if session.userControlling { return (ScreenToolLogic.userControllingReply(host: host), false) }
        do {
            if toolName == ScreenToolLogic.captureToolName {
                return (try await captureText(session: session, ownSessionId: ownSessionId), true)
            }
            let request = try ScreenToolLogic.decodeInput(arguments: arguments)
            let permission = await wiring.checkPermission(
                host: host, sessionId: bindingSessionId,
                summary: "Control the screen of \(host) (\(request.actions.count) action\(request.actions.count == 1 ? "" : "s"))")
            if case .denied(let message) = permission { return (message, false) }
            return try await input(request, session: session, ownSessionId: ownSessionId)
        } catch let error as ScreenToolArgumentError {
            return ("Error: \(error.userMessage)", false)
        } catch let error as HostScreenError {
            return ("Error: \(error.userMessage)", false)
        } catch {
            logger.error("\(toolName) on \(host) failed: \(error)")
            return ("Error: \(toolName) on \(host) failed: \(error.localizedDescription)", false)
        }
    }

    private static func input(
        _ request: ScreenInputRequest, session: HostScreenSession, ownSessionId: String?
    ) async throws -> (output: String, success: Bool) {
        let scale = ScreenScale(framebuffer: try await session.framebufferSize())
        let actions = try request.actions.map(scale.framebufferAction)
        // The permission prompt may have taken a while; the user can have taken control meanwhile.
        if session.userControlling { return (ScreenToolLogic.userControllingReply(host: session.host), false) }
        try await session.send(ScreenInputPlan.events(for: actions))
        let done = "Sent \(actions.count) action\(actions.count == 1 ? "" : "s") to the screen of \(session.host)."
        guard request.captureAfter else { return (done, true) }
        try await Task.sleep(for: settleBeforeCapture)
        return (done + "\n" + (try await captureText(session: session, ownSessionId: ownSessionId)), true)
    }

    private static func captureText(session: HostScreenSession, ownSessionId: String?) async throws -> String {
        let (jpeg, scale) = try await session.capture()
        let guestPath = try save(jpeg, host: session.host, ownSessionId: ownSessionId)
        return ScreenToolLogic.captureSummary(host: session.host, scale: scale)
            + " Saved to \(guestPath); open it with read_image to see it."
    }

    private static func save(_ jpeg: Data, host: String, ownSessionId: String?) throws -> String {
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let guestPath = "\(AIChatViewModel.minisOffloadsLinuxDir)/screen-\(host)-\(stamp).jpg"
        guard let ownSessionId, let url = MinisFsRouter.shared.hostURL(forGuest: guestPath, sid: ownSessionId) else {
            throw HostScreenError.failed(host: host, detail: "this chat has no folder for the screenshot")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jpeg.write(to: url, options: .atomic)
        return guestPath
    }

    private static func paramType(_ kind: RemoteToolParameter.Kind) -> AgentParamType {
        switch kind {
        case .string: return .string
        case .boolean: return .boolean
        }
    }
}

extension AIChatViewModel {
    /// The dispatcher's hook for the screen tools; nil sends any other unknown tool to its usual error.
    func hostScreenToolResult(toolName: String, toolArgs: [String: Any], msgIdx: Int, blockIdx: Int) async -> (output: String, success: Bool)? {
        guard let result = await HostScreenTools.run(
            toolName: toolName, arguments: toolArgs, bindingSessionId: remoteBindingSessionId, ownSessionId: sessionId,
            wiring: RemoteAppWiring.shared) else { return nil }
        if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
            messages[msgIdx].blocks[blockIdx].content = result.output
        }
        return result
    }
}
