import Foundation

/// フェード処理のパラメータ。FadeProcessor の生成時に固定される。
public struct FadeSettings: Equatable {
    /// 一時停止（音が途切れる直前）のフェードアウトを行うか
    public var fadeOutEnabled = true
    /// 長い無音のあと（再開）のフェードインを行うか
    public var fadeInEnabled = true
    /// 短い無音のあと（シーク）のフェードインを行うか
    public var seekFadeInEnabled = true
    /// 希望するフェードアウト長。実際は先読み遅延で上限が決まる
    public var fadeOutMs = 350.0
    public var fadeInMs = 300.0
    /// 出力を入力より遅らせる時間。0 ならフェードアウトなし・遅延なし
    public var lookaheadMs = 100.0
    /// この長さ以上の無音のあとに音が戻ったら「再開」とみなす
    public var resumeGapMs = 250.0
    /// この長さ以上（resumeGapMs 未満）の無音のあとなら「シーク」とみなす
    public var seekGapMs = 60.0
    /// この振幅以下を無音とみなす。一時停止中のプレイヤーはほぼ完全な 0 を出す
    public var silenceThresholdDB = -80.0
    /// 無音がこの長さ続いた時点で「途切れた」と確定し、直前をさかのぼってフェードする
    public var confirmMs = 15.0
    /// 無音の直後の gentleEdgeWindowMs、および無音の直前の gentleEdgeWindowMs のあいだ、
    /// 振幅がずっとこの値以下なら「滑らかな縁」とみなして、フェードを掛けない。
    /// 音声合成や曲頭・曲末は、数十 ms かけてほぼ無音から立ち上がり、ほぼ無音まで戻る（実測で
    /// −80dB→−45dB に 10〜40ms）ので、フェードは冒頭・語尾を弱めるだけになる。
    /// 一時停止・再開した動画は、OS の極短いランプ（約 0.3ms）のあとすぐ全開になるので、これまでどおり掛かる。
    /// 判定を無効にするには十分小さい値（-200 など）にする
    public var gentleEdgeDB = -45.0
    public var gentleEdgeWindowMs = 2.0

    public init() {}
}

/// 無音を検知して、音の途切れる直前（フェードアウト）と戻った直後（フェードイン）に
/// ゲインを掛ける。プレイヤー側の一時停止を横取りできないため、出力を先読み分だけ遅らせ、
/// 無音の開始が確定した時点で「まだ出力していない直前の区間」にフェードを掛け直す。
///
/// オーディオスレッドから呼ぶ前提で、process 内ではメモリ確保もロックもしない。
/// 入出力は同一バッファ（in-place）でもよい。
public final class FadeProcessor {
    public let sampleRate: Double
    public let channels: Int
    public let settings: FadeSettings
    /// 入力に対する出力の遅延（フレーム）
    public let latencyFrames: Int

    private struct Ramp {
        var start: Int64
        var length: Int64
    }

    /// 無音明けの音の始まり。縁が滑らかかの判定が済むまで、フェードインの登録を保留する
    private struct Onset {
        var start: Int64
        var gapFrames: Int
    }

    private let lookahead: Int
    private let confirmFrames: Int
    private let fadeOutFrames: Int
    private let fadeInFrames: Int
    private let resumeGapFrames: Int
    private let seekGapFrames: Int
    private let threshold: Float
    private let gentleEdge: Float
    private let gentleWindowFrames: Int

    private let ringFrames: Int
    private let ring: UnsafeMutablePointer<Float>
    private let rampCapacity = 8
    private let fadeIns: UnsafeMutablePointer<Ramp>
    private let fadeOuts: UnsafeMutablePointer<Ramp>
    private var fadeInCount = 0
    private var fadeOutCount = 0

    private var inIndex: Int64 = 0
    private var silentRun = 0
    private var pendingOnset: Onset?

    public init(sampleRate: Double, channels: Int, settings: FadeSettings) {
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        self.settings = settings

        func frames(_ ms: Double) -> Int { max(0, Int((sampleRate * ms / 1000).rounded())) }

        lookahead = frames(settings.lookaheadMs)
        latencyFrames = lookahead
        confirmFrames = max(1, frames(settings.confirmMs))
        fadeInFrames = frames(settings.fadeInMs)
        resumeGapFrames = frames(settings.resumeGapMs)
        seekGapFrames = frames(settings.seekGapMs)
        threshold = Float(pow(10.0, settings.silenceThresholdDB / 20.0))
        gentleEdge = Float(pow(10.0, settings.gentleEdgeDB / 20.0))
        gentleWindowFrames = max(1, frames(settings.gentleEdgeWindowMs))

        // 確定までに confirmFrames かかるので、遡れるのは先読み - 確定待ち - 余白 まで
        let maxFadeOut = lookahead - confirmFrames - 1
        if settings.fadeOutEnabled && maxFadeOut > 0 {
            fadeOutFrames = min(frames(settings.fadeOutMs), maxFadeOut)
        } else {
            fadeOutFrames = 0
        }

        ringFrames = lookahead + 1
        ring = UnsafeMutablePointer<Float>.allocate(capacity: ringFrames * self.channels)
        ring.initialize(repeating: 0, count: ringFrames * self.channels)
        fadeIns = UnsafeMutablePointer<Ramp>.allocate(capacity: rampCapacity)
        fadeOuts = UnsafeMutablePointer<Ramp>.allocate(capacity: rampCapacity)
    }

    deinit {
        ring.deallocate()
        fadeIns.deallocate()
        fadeOuts.deallocate()
    }

    /// 実際に適用されるフェードアウト長（ms）。先読みで頭打ちになるので UI 表示用に公開する
    public var effectiveFadeOutMs: Double {
        Double(fadeOutFrames) / sampleRate * 1000
    }

    /// インターリーブ済みの Float32 を frameCount フレーム処理する
    public func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int) {
        let ch = channels
        let cap = Int64(ringFrames)

        for i in 0..<frameCount {
            let base = i * ch

            var peak: Float = 0
            for c in 0..<ch {
                let v = abs(input[base + c])
                if v > peak { peak = v }
            }

            if peak > threshold {
                // 立ち上がりの極小の振幅は無音しきい値を行き来するので、判定中の始まりは上書きしない
                if silentRun > 0 && pendingOnset == nil { pendingOnset = Onset(start: inIndex, gapFrames: silentRun) }
                silentRun = 0
            } else {
                if silentRun < Int.max / 2 { silentRun += 1 }
                if silentRun == confirmFrames { registerGapStart() }
            }

            // 始まりの判定: 窓のあいだに gentleEdge を超えたら「ぶつ切り」、超えないまま窓が過ぎたら「滑らか」
            if let onset = pendingOnset {
                if peak > gentleEdge {
                    registerOnset(onset)
                    pendingOnset = nil
                } else if inIndex - onset.start >= Int64(gentleWindowFrames) {
                    pendingOnset = nil
                }
            }

            let write = Int(inIndex % cap) * ch
            for c in 0..<ch { ring[write + c] = input[base + c] }

            let outIndex = inIndex - Int64(lookahead)
            if outIndex >= 0 {
                let gain = gainAt(outIndex)
                let read = Int(outIndex % cap) * ch
                for c in 0..<ch { output[base + c] = ring[read + c] * gain }
            } else {
                for c in 0..<ch { output[base + c] = 0 }
            }
            inIndex += 1
        }

        discardFinishedRamps()
    }

    /// 内部状態を初期化する（デバイス切替後など）
    public func reset() {
        ring.update(repeating: 0, count: ringFrames * channels)
        fadeInCount = 0
        fadeOutCount = 0
        inIndex = 0
        silentRun = 0
        pendingOnset = nil
    }

    /// 無音が確定した時点で、その直前 gentleWindowFrames のピーク。ring に残っている範囲だけ見る
    private func peakBeforeGap() -> Float {
        let last = inIndex - Int64(confirmFrames) // 最後に音があったフレーム
        let first = max(last - Int64(gentleWindowFrames) + 1, inIndex - Int64(lookahead), 0)
        var peak: Float = 0
        var i = first
        while i <= last {
            let base = Int(i % Int64(ringFrames)) * channels
            for c in 0..<channels { peak = max(peak, abs(ring[base + c])) }
            i += 1
        }
        return peak
    }

    private func registerGapStart() {
        guard fadeOutFrames > 0 else { return }
        // 直前の数 ms がずっと小さい（自然な終わり）なら、ぶつ切りではないのでフェード不要
        guard peakBeforeGap() > gentleEdge else { return }
        // silentRun はちょうど confirmFrames に達した瞬間なので、無音の先頭はそこから遡った位置
        let gapStart = inIndex - Int64(confirmFrames - 1)
        let earliest = inIndex - Int64(lookahead) // これより前はもう出力済み
        let start = max(gapStart - Int64(fadeOutFrames), earliest)
        guard gapStart > start else { return }
        push(fadeOuts, &fadeOutCount, Ramp(start: start, length: gapStart - start))
    }

    private func registerOnset(_ onset: Onset) {
        guard fadeInFrames > 0 else { return }
        let isResume = onset.gapFrames >= resumeGapFrames
        let isSeek = !isResume && onset.gapFrames >= seekGapFrames
        if (isResume && settings.fadeInEnabled) || (isSeek && settings.seekFadeInEnabled) {
            // 判定のために数フレーム待ったので、始まりが出力済みなら、いまからの区間に掛ける
            let start = max(onset.start, inIndex - Int64(lookahead))
            push(fadeIns, &fadeInCount, Ramp(start: start, length: Int64(fadeInFrames)))
        }
    }

    private func push(_ list: UnsafeMutablePointer<Ramp>, _ count: inout Int, _ ramp: Ramp) {
        if count == rampCapacity {
            // 満杯のときは最古を捨てる（連続する無音の出入りでのみ起こる）
            for k in 1..<rampCapacity { list[k - 1] = list[k] }
            count -= 1
        }
        list[count] = ramp
        count += 1
    }

    /// 出力フレーム m に掛けるゲイン。フェードイン・フェードアウトの区間は積で合成する
    private func gainAt(_ m: Int64) -> Float {
        var gain: Float = 1
        for k in 0..<fadeInCount {
            let r = fadeIns[k]
            if m >= r.start && m < r.start + r.length {
                let x = Float(m - r.start) / Float(r.length)
                gain *= 0.5 * (1 - cosf(Float.pi * x))
            }
        }
        for k in 0..<fadeOutCount {
            let r = fadeOuts[k]
            if m >= r.start && m < r.start + r.length {
                let x = Float(m - r.start) / Float(r.length)
                gain *= 0.5 * (1 + cosf(Float.pi * x))
            }
        }
        return gain
    }

    private func discardFinishedRamps() {
        let nextOut = inIndex - Int64(lookahead)
        compact(fadeIns, &fadeInCount, before: nextOut)
        compact(fadeOuts, &fadeOutCount, before: nextOut)
    }

    private func compact(_ list: UnsafeMutablePointer<Ramp>, _ count: inout Int, before index: Int64) {
        var kept = 0
        for k in 0..<count where list[k].start + list[k].length > index {
            list[kept] = list[k]
            kept += 1
        }
        count = kept
    }
}
