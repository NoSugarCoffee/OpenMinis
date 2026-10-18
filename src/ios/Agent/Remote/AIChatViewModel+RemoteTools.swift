import Foundation
import MinisRemote

/// Remote calls in flight, per view model, so the tool card's stop button can cancel them. The view model is
/// upstream code, so the registry lives here instead of in a stored property.
@MainActor
final class RemoteRunRegistry {
    static let shared = RemoteRunRegistry()

    struct Key: Hashable {
        let owner: ObjectIdentifier
        let msgIdx: Int
        let blockIdx: Int
    }

    private var runs: [Key: Task<(output: String, success: Bool)?, Never>] = [:]
    private var stoppedByUser: Set<Key> = []

    func register(_ task: Task<(output: String, success: Bool)?, Never>, key: Key) {
        runs[key] = task
    }

    /// Returns whether the user stopped this run, and forgets it.
    func finish(key: Key) -> Bool {
        runs[key] = nil
        return stoppedByUser.remove(key) != nil
    }

    func cancelAll(owner: ObjectIdentifier) -> Bool {
        let keys = runs.keys.filter { $0.owner == owner }
        for key in keys {
            stoppedByUser.insert(key)
            runs[key]?.cancel()
        }
        return !keys.isEmpty
    }
}

extension AIChatViewModel {
    /// A sub agent's hidden session works for its parent, so it uses the parent's host binding, and the
    /// parent's Ask Once grant covers it.
    var remoteBindingSessionId: String? { helperConfig?.parentSessionId ?? sessionId }

    /// The tool-card side of `RemoteToolBridge.handle`: streams host output into the card while the run lasts,
    /// then shows the final result. nil means the call takes the local path.
    func remoteToolResult(
        toolName: String, argsJson: String, msgIdx: Int, blockIdx: Int
    ) async -> RemoteToolOutcome? {
        let key = RemoteRunRegistry.Key(owner: ObjectIdentifier(self), msgIdx: msgIdx, blockIdx: blockIdx)
        let bindingSessionId = remoteBindingSessionId
        // One consumer keeps chunks in order, and draining it before the final result means no chunk lands
        // after it and overwrites the card.
        let (chunks, chunkSink) = AsyncStream.makeStream(of: String.self)
        let display = Task { @MainActor [weak self] in
            for await chunk in chunks {
                self?.appendRemoteOutput(chunk, msgIdx: msgIdx, blockIdx: blockIdx)
            }
        }
        let run = Task { @MainActor in
            await RemoteToolBridge.handle(
                toolName: toolName, argsJson: argsJson, sessionId: bindingSessionId,
                onOutput: { chunkSink.yield($0) })
        }
        RemoteRunRegistry.shared.register(run, key: key)
        // The run is its own task so the card's stop button can cancel it alone; stopping the turn cancels it too.
        let result = await withTaskCancellationHandler {
            await run.value
        } onCancel: {
            run.cancel()
        }
        chunkSink.finish()
        await display.value
        let stoppedByUser = RemoteRunRegistry.shared.finish(key: key)
        guard let result else { return nil }
        let outcome = RemoteToolOutcome(output: result.output, success: result.success, stoppedByUser: stoppedByUser)
        if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
            messages[msgIdx].blocks[blockIdx].content = outcome.output
        }
        return outcome
    }

    /// Cancels this view model's remote runs; the host-side cancel sequence runs before each returns. Not on
    /// background expiry, which sets `backgroundSuspended` before calling `stopCurrentCommand`: a host run must
    /// outlive suspension (spec §4.4). Any other stop, a helper's wrap-up in the background included, cancels.
    func cancelRemoteRun() -> Bool {
        guard !backgroundSuspended else { return false }
        return RemoteRunRegistry.shared.cancelAll(owner: ObjectIdentifier(self))
    }

    private func appendRemoteOutput(_ chunk: String, msgIdx: Int, blockIdx: Int) {
        // Same display cap as the local shell stream in executeSingleToolUse.
        let maxDisplayChars = 30_000
        guard msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count else { return }
        let current = messages[msgIdx].blocks[blockIdx].content
        var updated = current.hasSuffix("Executing...") ? chunk : current + chunk
        if updated.count > maxDisplayChars {
            updated = "…[output truncated]…\n" + String(updated.suffix(maxDisplayChars))
        }
        messages[msgIdx].blocks[blockIdx].content = updated
        scrollToBottomSignal.send()
    }
}
