import Foundation

/// Holds callers until `open()` runs once; later waits return at once.
@MainActor
final class OneShotGate {
    private(set) var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let released = waiters
        waiters = []
        released.forEach { $0.resume() }
    }
}
