import MinisRemote

/// Adds `RemoteToolSchema`'s parameters to the app's tool definitions, so the upstream definitions stay as they are.
enum RemoteAgentToolSchema {
    /// `sessionId` is the session whose binding applies (a sub agent's parent's).
    @MainActor
    static func augment(_ tools: [AgentToolDefinition], sessionId: String?) -> [AgentToolDefinition] {
        let wiring = RemoteAppWiring.shared
        let boundHost = wiring.boundHost(sessionId: sessionId)
        return augment(tools, hostsConfigured: wiring.hasConfiguredHosts, boundHost: boundHost)
            + HostScreenTools.definitions(boundHost: boundHost)
    }

    static func augment(
        _ tools: [AgentToolDefinition], hostsConfigured: Bool, boundHost: RemoteBoundHost?
    ) -> [AgentToolDefinition] {
        tools.map { tool in
            let additions = RemoteToolSchema.additions(toolName: tool.name, hostsConfigured: hostsConfigured)
            guard !additions.isEmpty else { return tool }
            var parameters = tool.parameters
            for addition in additions {
                parameters[addition.name] = AgentToolParam(type: paramType(addition.kind), description: addition.description)
            }
            return AgentToolDefinition(
                name: tool.name, description: description(of: tool, boundHost: boundHost), parameters: parameters,
                required: tool.required, propertyOrdering: tool.propertyOrdering.map { $0 + additions.map(\.name) })
        }
    }

    private static func description(of tool: AgentToolDefinition, boundHost: RemoteBoundHost?) -> String {
        guard tool.name == "shell_execute", let boundHost else { return tool.description }
        return tool.description + " " + RemoteToolSchema.boundShellNote(binding: boundHost.binding, os: boundHost.os)
    }

    private static func paramType(_ kind: RemoteToolParameter.Kind) -> AgentParamType {
        switch kind {
        case .string: return .string
        case .boolean: return .boolean
        }
    }
}
