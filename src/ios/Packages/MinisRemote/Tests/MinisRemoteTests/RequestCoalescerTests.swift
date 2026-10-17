import XCTest
@testable import MinisRemote

@MainActor
private final class Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var started = 0
    private(set) var counted = 0

    func count() { counted += 1 }

    func wait() async {
        started += 1
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@MainActor
final class RequestCoalescerTests: XCTestCase {
    func testConcurrentCallersWithTheSameKeyShareOneRun() async {
        let coalescer = RequestCoalescer<String, Int>()
        let gate = Gate()
        let first = Task { await coalescer.run(key: "remote-host:mini|s1") { await gate.wait(); return 7 } }
        let second = Task { await coalescer.run(key: "remote-host:mini|s1") { await gate.wait(); return 8 } }
        while gate.started == 0 { await Task.yield() }
        for _ in 0..<10 { await Task.yield() }
        gate.open()

        let results = [await first.value, await second.value]

        XCTAssertEqual(gate.started, 1)
        XCTAssertEqual(results, [7, 7])
    }

    func testDifferentKeysRunSeparately() async {
        let coalescer = RequestCoalescer<String, Int>()
        let a = await coalescer.run(key: "a") { 1 }
        let b = await coalescer.run(key: "b") { 2 }
        XCTAssertEqual([a, b], [1, 2])
    }

    func testAFinishedRunIsNotReused() async {
        let coalescer = RequestCoalescer<String, Int>()
        let gate = Gate()
        gate.open()
        _ = await coalescer.run(key: "k") { gate.count(); return gate.counted }
        let second = await coalescer.run(key: "k") { gate.count(); return gate.counted }
        XCTAssertEqual(second, 2)
    }
}
