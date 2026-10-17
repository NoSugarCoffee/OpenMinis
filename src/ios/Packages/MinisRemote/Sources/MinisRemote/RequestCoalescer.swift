/// Runs one operation per key at a time; callers arriving while it runs await the same result. The operation
/// runs in its own task, so a caller that is cancelled does not cancel it for the others.
@MainActor
public final class RequestCoalescer<Key: Hashable, Value: Sendable> {
    private var inFlight: [Key: Task<Value, Never>] = [:]

    public init() {}

    public func run(key: Key, _ operation: @escaping @MainActor () async -> Value) async -> Value {
        if let running = inFlight[key] { return await running.value }
        let task = Task { @MainActor in await operation() }
        inFlight[key] = task
        let value = await task.value
        inFlight[key] = nil
        return value
    }
}
