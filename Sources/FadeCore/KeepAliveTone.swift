import Foundation

/// 出力に常時足す、聞こえない極低周波の正弦波。
/// 無音（デジタルのゼロ）が続くと、Bluetooth の経路（コーデック・イヤホン）が眠って、
/// 再開直後の小さな音を落とす疑いがあるため、経路を起こしたままにするための実験機能。
/// 周波数は可聴域の下限より低く、レベルも小さいので、音としては聞こえない。
public struct KeepAliveTone {
    private let phaseStep: Double
    private let amplitude: Float
    private var phase = 0.0

    /// levelDB が -150 以下なら無効（何も足さない）
    public init(sampleRate: Double, frequency: Double, levelDB: Double) {
        phaseStep = 2 * Double.pi * frequency / sampleRate
        amplitude = levelDB > -150 ? Float(pow(10.0, levelDB / 20.0)) : 0
    }

    public var isEnabled: Bool { amplitude > 0 }

    /// インターリーブ済みの buffer の全チャンネルに、同じ値を足す。呼び出しをまたいで位相は連続する
    public mutating func mix(into buffer: UnsafeMutablePointer<Float>, frameCount: Int, channels: Int) {
        guard amplitude > 0 else { return }
        for f in 0..<frameCount {
            let v = amplitude * Float(sin(phase))
            for c in 0..<channels { buffer[f * channels + c] += v }
            phase += phaseStep
            if phase >= 2 * Double.pi { phase -= 2 * Double.pi }
        }
    }
}
