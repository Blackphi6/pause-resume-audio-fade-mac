import XCTest
@testable import FadeCore

private let sr = 48_000.0
private let ch = 2

private func frames(_ ms: Double) -> Int { Int((sr * ms / 1000).rounded()) }

/// 音の縁（始まりと終わり）の形
private enum Edge {
    /// 途中から大きな値で始まる／切れる（一時停止した動画をプレイヤーが止めた直後）
    case abrupt
    /// OS が掛ける 0.3ms ほどの極短いランプ。実機で見た「動画の一時停止・再開」はこの形
    case systemRamp
    /// 音声合成や曲頭・曲末のように、数十 ms かけて、ほぼ無音から立ち上がる／戻る
    case gentle
}

/// 440Hz の音。縁は edge の形にする
private func burst(ms: Double, edge: Edge, amp: Float = 0.5) -> [Float] {
    let n = frames(ms)
    var out = [Float](repeating: 0, count: n * ch)
    for i in 0..<n {
        let d = Float(min(i + 1, n - i)) // 縁からの距離（フレーム）
        let env: Float
        switch edge {
        case .abrupt: env = 1
        case .systemRamp:
            // 実機の計測: 最初のサンプルは 0.0001〜0.0002（−80dB 付近）、約 16 フレーム（0.33ms）で全開になる
            let x = min(1, d / Float(frames(0.33)))
            env = x * x * x
        case .gentle:
            // 30ms かけて -60dB から 0dB まで、dB に対して直線で上げる（音声の立ち上がりに近い）
            let x = min(1, d / Float(frames(30)))
            env = powf(10, -3 * (1 - x))
        }
        let v = amp * env * cosf(2 * .pi * 440 * Float(i) / Float(sr))
        for c in 0..<ch { out[i * ch + c] = v }
    }
    return out
}

private func silence(ms: Double) -> [Float] { [Float](repeating: 0, count: frames(ms) * ch) }

private func render(_ settings: FadeSettings, _ input: [Float]) -> [Float] {
    let p = FadeProcessor(sampleRate: sr, channels: ch, settings: settings)
    var output = [Float](repeating: 0, count: input.count)
    let total = input.count / ch
    var pos = 0
    input.withUnsafeBufferPointer { inp in
        output.withUnsafeMutableBufferPointer { out in
            while pos < total {
                let n = min(1024, total - pos)
                p.process(input: inp.baseAddress! + pos * ch, output: out.baseAddress! + pos * ch, frameCount: n)
                pos += n
            }
        }
    }
    return output
}

/// フレーム範囲 [from, to) の最大振幅
private func peak(_ x: [Float], from: Int, to: Int) -> Float {
    var p: Float = 1e-12
    for i in from..<to { p = max(p, abs(x[i * ch])) }
    return p
}

/// フレーム範囲の出力ピーク ÷ 入力ピーク（latency 遅れで比べる）。1 なら素通し、0 に近ければフェード中
private func throughput(_ out: [Float], _ input: [Float], from: Int, to: Int, latency: Int) -> Float {
    peak(out, from: from + latency, to: to + latency) / peak(input, from: from, to: to)
}

final class GentleEdgeTests: XCTestCase {
    private var s = FadeSettings()
    private var latency = 0

    override func setUp() {
        s = FadeSettings()
        s.lookaheadMs = 100
        s.fadeInMs = 300
        latency = frames(s.lookaheadMs)
    }

    // MARK: 滑らかな縁（音声合成など）はフェードしない

    func testGentleOnsetAfterLongSilenceIsNotFadedIn() {
        let gap = frames(500)
        let input = silence(ms: 500) + burst(ms: 1000, edge: .gentle)
        let out = render(s, input)
        // 立ち上がり中(0〜30ms)も、その後の 300ms（フェードインがあれば弱まる区間）も素通し
        XCTAssertEqual(throughput(out, input, from: gap, to: gap + frames(30), latency: latency), 1, accuracy: 1e-5)
        XCTAssertEqual(throughput(out, input, from: gap + frames(30), to: gap + frames(300), latency: latency), 1, accuracy: 1e-5)
    }

    func testGentleEndIsNotFadedOut() {
        let input = burst(ms: 1000, edge: .gentle) + silence(ms: 500)
        let out = render(s, input)
        let end = frames(1000)
        XCTAssertEqual(throughput(out, input, from: end - frames(90), to: end, latency: latency), 1, accuracy: 1e-5)
    }

    /// 音声合成のように、文の間に短い無音を挟んで滑らかに始まる音が続いても、どの文頭も弱まらない
    func testSentencesWithShortGapsKeepFullLevel() {
        var input = silence(ms: 300)
        var starts: [Int] = []
        for _ in 0..<4 {
            starts.append(input.count / ch)
            input += burst(ms: 400, edge: .gentle) + silence(ms: 350)
        }
        let out = render(s, input)
        for start in starts {
            XCTAssertEqual(throughput(out, input, from: start, to: start + frames(300), latency: latency), 1, accuracy: 1e-5, "start=\(start)")
        }
    }

    // MARK: 動画の一時停止・再開は、これまでどおりフェードする

    func testAbruptOnsetStillFadesIn() {
        let gap = frames(500)
        let input = silence(ms: 500) + burst(ms: 1000, edge: .abrupt)
        let out = render(s, input)
        XCTAssertLessThan(throughput(out, input, from: gap, to: gap + frames(5), latency: latency), 0.05)
    }

    func testAbruptEndStillFadesOut() {
        let input = burst(ms: 1000, edge: .abrupt) + silence(ms: 500)
        let out = render(s, input)
        let end = frames(1000)
        XCTAssertLessThan(throughput(out, input, from: end - frames(5), to: end, latency: latency), 0.1)
    }

    /// 実機では OS が 0.3ms の極短いランプを掛けるので、それでも「ぶつ切り」と判定する
    func testSystemRampedOnsetAndEndAreStillTreatedAsAbrupt() {
        let gap = frames(500)
        let end = gap + frames(1000)
        let input = silence(ms: 500) + burst(ms: 1000, edge: .systemRamp) + silence(ms: 500)
        let out = render(s, input)
        XCTAssertLessThan(throughput(out, input, from: gap, to: gap + frames(5), latency: latency), 0.05)
        XCTAssertLessThan(throughput(out, input, from: end - frames(5), to: end, latency: latency), 0.1)
    }

    /// 立ち上がりの極小の振幅が無音しきい値を行き来しても（ゼロ交差など）、本来の始まりを見失わない
    func testOnsetFlickeringAroundSilenceThresholdIsStillDetected() {
        let gap = frames(500)
        var input = silence(ms: 500) + burst(ms: 1000, edge: .systemRamp)
        // 始まりの数サンプルを、しきい値(-80dB)の上下に揺らす
        for i in 0..<6 { for c in 0..<ch { input[(gap + i) * ch + c] = i % 2 == 0 ? 0.0003 : 0.00005 } }
        let out = render(s, input)
        XCTAssertLessThan(throughput(out, input, from: gap + frames(1), to: gap + frames(10), latency: latency), 0.05)
    }

    // MARK: 設定

    /// 判定を無効にすれば、滑らかな縁にも掛かる（誤判定時の逃げ道）
    func testDisablingGentleEdgeDetectionFadesEverything() {
        s.gentleEdgeDB = -200
        let gap = frames(500)
        let end = gap + frames(1000)
        let input = silence(ms: 500) + burst(ms: 1000, edge: .gentle) + silence(ms: 500)
        let out = render(s, input)
        XCTAssertLessThan(throughput(out, input, from: gap + frames(6), to: gap + frames(16), latency: latency), 0.1)
        XCTAssertLessThan(throughput(out, input, from: end - frames(10), to: end, latency: latency), 0.1)
    }

    /// フェードアウトなし（先読み 0、遅延なし）でも、再開のフェードインの判定は動く
    func testWithoutLookaheadAbruptOnsetStillFadesInAndGentleDoesNot() {
        s.lookaheadMs = 0
        let gap = frames(500)
        let abrupt = silence(ms: 500) + burst(ms: 1000, edge: .abrupt)
        let outAbrupt = render(s, abrupt)
        XCTAssertLessThan(throughput(outAbrupt, abrupt, from: gap + frames(1), to: gap + frames(10), latency: 0), 0.1)

        let gentle = silence(ms: 500) + burst(ms: 1000, edge: .gentle)
        let outGentle = render(s, gentle)
        XCTAssertEqual(throughput(outGentle, gentle, from: gap, to: gap + frames(300), latency: 0), 1, accuracy: 1e-5)
    }
}
