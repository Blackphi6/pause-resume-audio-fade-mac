import AudioToolbox
import CoreAudio
import Foundation

/// 検証用: 本体を除く全アプリの「生の音」を、ミュートせずに受け取り、
/// 無音からの音の始まり・音の終わりごとに、立ち上がり／落ち方の速さと判定を表示する。
/// プレイヤーごとの違い（QuickTime、VLC、Chrome など）を測って、フェードの判定を調整するための道具。
@available(macOS 14.2, *)
final class OnsetDiag {
    struct Event {
        var isOnset: Bool
        var atFrame: Int64
        var gapFrames: Int      // 始まり: 直前の無音の長さ ／ 終わり: 0
        var edgeFrames: Int     // 始まり: -80→-45dB に上がるまで ／ 終わり: -45→-80dB に落ちるまで
        var gentle: Bool        // 滑らか（ゆっくり立ち上がる／戻る）か
        var peakAfter: Float    // 始まりから 20ms 以内の最大値
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "pauseresume.diag", qos: .userInteractive)

    private let capacity = 2000
    private let events = UnsafeMutablePointer<Event>.allocate(capacity: 2000)
    private(set) var eventCount = 0
    private(set) var sampleRate = 48_000.0

    // 以下はオーディオスレッドだけが触る
    private let silent: Float = 1e-4        // -80dB
    private let gentleLevel: Float = 0.0056 // -45dB
    private var index: Int64 = 0
    private var silentRun = 0
    private var inSound = false
    private var onsetFrame: Int64 = 0
    private var onsetGap = 0
    private var firstLoudFrame: Int64 = -1
    private var onsetPeak: Float = 0
    private var onsetPending = false
    private var lastSoundFrame: Int64 = -1
    private var lastLoudFrame: Int64 = -1

    deinit { events.deallocate() }

    func start() throws {
        // 本体（同じ Bundle ID の別プロセス）の出力は、処理済みの音なので除く
        let mainApps = CoreAudioUtil.processObjects().filter {
            CoreAudioUtil.processBundleID($0) == "io.github.blackphi6.PauseResumeAudioFade" && CoreAudioUtil.processPID($0) != getpid()
        }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: mainApps)
        description.name = "PauseResumeAudioFade diag"
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw CoreAudioError(operation: "diag タップ作成", status: status) }

        let outDevice = try CoreAudioUtil.defaultOutputDevice()
        let outUID = try CoreAudioUtil.deviceUID(outDevice)
        sampleRate = CoreAudioUtil.nominalSampleRate(outDevice)
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "PauseResumeAudioFade diag",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregateID)
        guard status == noErr else { throw CoreAudioError(operation: "diag 集約デバイス作成", status: status) }

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [unowned self] _, inData, _, _, _ in
            self.analyze(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData)))
        }
        guard status == noErr else { throw CoreAudioError(operation: "diag IOProc作成", status: status) }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw CoreAudioError(operation: "diag 開始", status: status) }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        procID = nil
    }

    func event(_ i: Int) -> Event { events[i] }

    private func push(_ e: Event) {
        if eventCount < capacity { events[eventCount] = e; eventCount += 1 }
    }

    /// 入力の全バッファを見て、フレームごとの最大振幅を調べる（インターリーブでもプレーナでもよい）
    private func analyze(_ input: UnsafeMutableAudioBufferListPointer) {
        guard input.count > 0, let first = input[0].mData else { return }
        let planar = input.count > 1 && input[0].mNumberChannels == 1
        let channels = max(1, Int(input[0].mNumberChannels))
        let frames = planar
            ? Int(input[0].mDataByteSize) / MemoryLayout<Float>.size
            : Int(input[0].mDataByteSize) / (MemoryLayout<Float>.size * channels)
        _ = first
        let gentleWindow = Int(sampleRate * 0.002)
        let confirm = Int(sampleRate * 0.015)
        let minGap = Int(sampleRate * 0.060)

        for f in 0..<frames {
            var peak: Float = 0
            if planar {
                for b in 0..<input.count {
                    if let d = input[b].mData?.assumingMemoryBound(to: Float.self) { peak = max(peak, abs(d[f])) }
                }
            } else if let d = input[0].mData?.assumingMemoryBound(to: Float.self) {
                for c in 0..<channels { peak = max(peak, abs(d[f * channels + c])) }
            }

            if peak > silent {
                if silentRun >= minGap || (!inSound && index > 0 && silentRun > 0) {
                    // 十分長い無音のあとの始まり
                    if silentRun >= minGap {
                        onsetFrame = index
                        onsetGap = silentRun
                        firstLoudFrame = -1
                        onsetPeak = 0
                        onsetPending = true
                    }
                }
                inSound = true
                silentRun = 0
                lastSoundFrame = index
                if peak > gentleLevel { lastLoudFrame = index }
                if onsetPending {
                    onsetPeak = max(onsetPeak, peak)
                    if firstLoudFrame < 0 && peak > gentleLevel { firstLoudFrame = index }
                    if index - onsetFrame >= Int64(sampleRate * 0.020) {
                        let rise = firstLoudFrame < 0 ? Int(index - onsetFrame) : Int(firstLoudFrame - onsetFrame)
                        let gentle = firstLoudFrame < 0 || firstLoudFrame - onsetFrame > Int64(gentleWindow)
                        push(Event(isOnset: true, atFrame: onsetFrame, gapFrames: onsetGap, edgeFrames: rise, gentle: gentle, peakAfter: onsetPeak))
                        onsetPending = false
                    }
                }
            } else {
                silentRun += 1
                if silentRun == confirm && inSound {
                    // 無音が確定: 直前の落ち方を調べる
                    let fall = Int(lastSoundFrame - lastLoudFrame)
                    push(Event(isOnset: false, atFrame: lastSoundFrame, gapFrames: 0, edgeFrames: fall, gentle: fall > gentleWindow, peakAfter: 0))
                    inSound = false
                }
            }
            index += 1
        }
    }
}
