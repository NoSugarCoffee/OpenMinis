import XCTest
@testable import Minis

@MainActor
final class OneShotGateTests: XCTestCase {
    func testWaitersResumeOnlyWhenTheGateOpens() async {
        let gate = OneShotGate()
        var resumed = 0
        let waiters = (0..<2).map { _ in Task { await gate.wait(); resumed += 1 } }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(resumed, 0)
        gate.open()
        for waiter in waiters { await waiter.value }
        XCTAssertEqual(resumed, 2)
    }

    func testWaitAfterOpenReturnsAtOnceAndOpenIsIdempotent() async {
        let gate = OneShotGate()
        gate.open()
        gate.open()
        await gate.wait()
        XCTAssertTrue(gate.isOpen)
    }
}
