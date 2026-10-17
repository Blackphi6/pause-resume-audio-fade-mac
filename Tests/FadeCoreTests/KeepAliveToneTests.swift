import XCTest
@testable import FadeCore

final class KeepAliveToneTests: XCTestCase {
    private let sr = 48_000.0

    /// 無効（レベルが十分小さい）なら、バッファに触らない
    func testDisabledLeavesBufferUntouched() {
        var tone = KeepAliveTone(sampleRate: sr, frequency: 18, levelDB: -200)
        XCTAssertFalse(tone.isEnabled)
        var buf = [Float](repeating: 0.25, count: 2 * 480)
        tone.mix(into: &buf, frameCount: 480, channels: 2)
        XCTAssertTrue(buf.allSatisfy { $0 == 0.25 })
    }

    /// 振幅は指定した dBFS。左右に同じ値を足す
    func testAmplitudeAndChannels() {
        var tone = KeepAliveTone(sampleRate: sr, frequency: 18, levelDB: -50)
        XCTAssertTrue(tone.isEnabled)
        var buf = [Float](repeating: 0, count: 2 * 48_000)
        tone.mix(into: &buf, frameCount: 48_000, channels: 2)
        let peak = buf.map(abs).max()!
        XCTAssertEqual(peak, powf(10, -50 / 20), accuracy: 1e-5)
        for f in stride(from: 0, to: 48_000, by: 997) { XCTAssertEqual(buf[f * 2], buf[f * 2 + 1]) }
    }

    /// ブロックに分けて呼んでも、位相が途切れない（1 回で作った波形と同じ）
    func testPhaseIsContinuousAcrossBlocks() {
        var whole = KeepAliveTone(sampleRate: sr, frequency: 18, levelDB: -50)
        var a = [Float](repeating: 0, count: 2 * 4096)
        whole.mix(into: &a, frameCount: 4096, channels: 2)

        var split = KeepAliveTone(sampleRate: sr, frequency: 18, levelDB: -50)
        var b = [Float](repeating: 0, count: 2 * 4096)
        var pos = 0
        for n in [512, 1000, 77, 2507] {
            b.withUnsafeMutableBufferPointer { split.mix(into: $0.baseAddress! + pos * 2, frameCount: n, channels: 2) }
            pos += n
        }
        XCTAssertEqual(pos, 4096)
        for i in 0..<a.count { XCTAssertEqual(a[i], b[i], accuracy: 1e-9, "i=\(i)") }
    }

    /// 既存の音に足す（上書きしない）
    func testMixesOntoExistingSignal() {
        var tone = KeepAliveTone(sampleRate: sr, frequency: 18, levelDB: -40)
        var buf = [Float](repeating: 0.5, count: 2 * 2400)
        tone.mix(into: &buf, frameCount: 2400, channels: 2)
        let delta = zip(buf, [Float](repeating: 0.5, count: buf.count)).map { $0 - $1 }.map(abs).max()!
        XCTAssertEqual(delta, powf(10, -40 / 20), accuracy: 1e-4)
    }
}
