import Foundation

extension AIChatViewModel {
    var isHostEventReadOnly: Bool {
        SessionToolPolicy.shared.isReadOnly(sessionId: remoteBindingSessionId)
    }

    var hostEventSystemPromptFragment: String {
        isHostEventReadOnly ? "\n\n" + SessionToolPolicy.systemPromptLine : ""
    }

    /// Dispatch-side half of the read-only policy: `makeAgentTools` already hides the tool, but a model can
    /// still name one it was not offered, and dispatch runs by name. Shaped like the preflight block.
    func hostEventRefusal(tu: StreamResult.ToolEntry, msgIdx: Int, blockIdx: Int) async -> ToolExecOutcome? {
        guard let modelMessage = SessionToolPolicy.shared.refusal(toolName: tu.name, sessionId: remoteBindingSessionId) else {
            return nil
        }
        let uiMessage = RemoteHostL10n.string("Blocked: this event session is read-only")
        if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
            messages[msgIdx].blocks[blockIdx].content = uiMessage
            messages[msgIdx].blocks[blockIdx].toolStatus = .failed(message: uiMessage)
        }
        let snapshot = ToolSnapshot(type: .text, text: modelMessage, mediaRef: nil, duration: nil)
        let item = ToolSnapshotItem(
            id: tu.id, toolName: tu.name, snapshot: snapshot,
            mediaResolver: await ChatStore.shared.mediaFileURLResolver())
        return ToolExecOutcome(
            toolId: tu.id, toolName: tu.name,
            resultPart: .toolResult(id: tu.id, name: tu.name, content: modelMessage, isError: true),
            snapshotEntry: (toolName: tu.name, snapshot: snapshot),
            snapshotItem: item,
            cancelled: false)
    }
}
