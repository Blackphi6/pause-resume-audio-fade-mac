import XCTest
@testable import FadeCore

final class HoldOffGateTests: XCTestCase {
    func testStartsInactive() {
        let gate = HoldOffGate(releaseDelay: 3)
        XCTAssertFalse(gate.isHeld)
    }

    func testBecomesHeldImmediately() {
        var gate = HoldOffGate(releaseDelay: 3)
        XCTAssertTrue(gate.update(active: true, now: 10))
        XCTAssertTrue(gate.isHeld)
    }

    func testStaysHeldUntilReleaseDelayPasses() {
        var gate = HoldOffGate(releaseDelay: 3)
        _ = gate.update(active: true, now: 10)
        // マイクが一瞬途切れても、通話中とみなし続ける
        XCTAssertTrue(gate.update(active: false, now: 11))
        XCTAssertTrue(gate.update(active: false, now: 12.9))
        XCTAssertFalse(gate.update(active: false, now: 14))
    }

    func testReactivationCancelsPendingRelease() {
        var gate = HoldOffGate(releaseDelay: 3)
        _ = gate.update(active: true, now: 0)
        _ = gate.update(active: false, now: 1)
        _ = gate.update(active: true, now: 2)
        // 解除の待ち時間は、最後に非アクティブになった時点から数え直す
        XCTAssertTrue(gate.update(active: false, now: 3))
        XCTAssertTrue(gate.update(active: false, now: 5.9))
        XCTAssertFalse(gate.update(active: false, now: 6.1))
    }

    func testRemainingDelayTellsWhenToCheckAgain() {
        var gate = HoldOffGate(releaseDelay: 3)
        _ = gate.update(active: true, now: 0)
        XCTAssertNil(gate.remainingDelay(now: 1))
        _ = gate.update(active: false, now: 1)
        XCTAssertEqual(gate.remainingDelay(now: 2) ?? -1, 2, accuracy: 1e-9)
        _ = gate.update(active: false, now: 5)
        XCTAssertNil(gate.remainingDelay(now: 5))
    }
}
