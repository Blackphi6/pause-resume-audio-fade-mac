import CoreAudio
import Foundation

/// 既定の入力デバイス（マイク）を、どこかのアプリが使っているかを監視する。
/// 通話アプリは通話中ずっとマイクを開くので、「通話中かどうか」の目安にする。
/// 自プロセスはマイクを開かず、フェードのタップも入力デバイスを含まないので、自分では反応しない。
final class MicActivityWatcher {
    private let onChange: () -> Void
    private var watched = AudioObjectID(kAudioObjectUnknown)
    private var defaultInputAddress = CoreAudioUtil.address(kAudioHardwarePropertyDefaultInputDevice)
    private var runningAddress = CoreAudioUtil.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
    private lazy var block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange() }
    private lazy var deviceChangedBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.watchCurrentInput()
        self?.onChange()
    }

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultInputAddress, .main, deviceChangedBlock)
        watchCurrentInput()
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultInputAddress, .main, deviceChangedBlock)
        unwatchInput()
    }

    /// いまマイクを使っているアプリがあるか。入力デバイスがなければ false
    var isInUse: Bool {
        guard watched != kAudioObjectUnknown else { return false }
        let running = try? CoreAudioUtil.get(watched, kAudioDevicePropertyDeviceIsRunningSomewhere, default: UInt32(0))
        return (running ?? 0) != 0
    }

    /// 既定の入力デバイスが替わる（AirPods の接続など）たびに、監視先を付け替える
    private func watchCurrentInput() {
        unwatchInput()
        guard let device = try? CoreAudioUtil.get(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice,
            default: AudioObjectID(kAudioObjectUnknown)),
            device != kAudioObjectUnknown else { return }
        watched = device
        AudioObjectAddPropertyListenerBlock(device, &runningAddress, .main, block)
    }

    private func unwatchInput() {
        if watched != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(watched, &runningAddress, .main, block)
            watched = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
