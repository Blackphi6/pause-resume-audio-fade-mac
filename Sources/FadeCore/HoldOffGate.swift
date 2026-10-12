import Foundation

/// 「マイク使用中」のような信号から、通話中かどうかを安定して判定する。
/// 使い始めはすぐ true にし、使用が止まってからも releaseDelay 秒は true を保つ。
/// 通話アプリがマイクを一瞬手放しても、フェード処理が入ったり抜けたりしないようにするため。
public struct HoldOffGate {
    public let releaseDelay: TimeInterval
    public private(set) var isHeld = false
    /// アクティブでなくなった時刻。解除の待ち時間はここから数える。アクティブ中は nil
    private var inactiveSince: TimeInterval?

    public init(releaseDelay: TimeInterval) {
        self.releaseDelay = releaseDelay
    }

    /// 現在の状態を取り込み、保持中かどうかを返す
    @discardableResult
    public mutating func update(active: Bool, now: TimeInterval) -> Bool {
        if active {
            isHeld = true
            inactiveSince = nil
        } else if isHeld {
            let since = inactiveSince ?? now
            inactiveSince = since
            if now - since >= releaseDelay {
                isHeld = false
                inactiveSince = nil
            }
        }
        return isHeld
    }

    /// 解除待ちの残り秒数。待っていなければ（アクティブ中・解除済み）nil。呼び出し側が再確認の予約に使う
    public func remainingDelay(now: TimeInterval) -> TimeInterval? {
        guard isHeld, let since = inactiveSince else { return nil }
        return max(0, releaseDelay - (now - since))
    }
}
