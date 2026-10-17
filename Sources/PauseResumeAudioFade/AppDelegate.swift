import AppKit
import CoreAudio
import FadeCore
import ServiceManagement

/// 既定の出力デバイス、および使用中デバイスのサンプルレートの変化を監視する。
/// どちらも変わると集約デバイスが無効になるので、エンジンを作り直す必要がある
final class DeviceWatcher {
    private let onChange: () -> Void
    private var watched: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var systemAddress = CoreAudioUtil.address(kAudioHardwarePropertyDefaultOutputDevice)
    private var rateAddress = CoreAudioUtil.address(kAudioDevicePropertyNominalSampleRate)
    private lazy var block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange() }

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &systemAddress, .main, block)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &systemAddress, .main, block)
        unwatchDevice()
    }

    /// エンジンの（再）起動のたびに、いま使っている出力デバイスのサンプルレート変化を監視し直す
    func watchCurrentDevice() {
        unwatchDevice()
        guard let device = try? CoreAudioUtil.defaultOutputDevice(), device != kAudioObjectUnknown else { return }
        watched = device
        AudioObjectAddPropertyListenerBlock(device, &rateAddress, .main, block)
    }

    private func unwatchDevice() {
        if watched != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(watched, &rateAddress, .main, block)
            watched = AudioObjectID(kAudioObjectUnknown)
        }
    }
}

@available(macOS 14.2, *)
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences()
    private let engine = AudioTapEngine()
    private lazy var statusBar = StatusBarController(preferences: preferences)
    private var deviceWatcher: DeviceWatcher?
    private var micWatcher: MicActivityWatcher?
    /// マイクが一瞬途切れても通話中とみなし続ける（解除は 3 秒後）
    private var callGate = HoldOffGate(releaseDelay: 3)
    private var callCheckWorkItem: DispatchWorkItem?
    private var restartWorkItem: DispatchWorkItem?
    private var lastError: String?
    private var loginItemNote: String?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar.snapshot = { [unowned self] in makeSnapshot() }
        statusBar.onToggleEnabled = { [unowned self] in preferences.enabled = $0; scheduleRestart(after: 0) }
        statusBar.onSelectFadeOutMode = { [unowned self] in preferences.fadeOutMode = $0; scheduleRestart(after: 0.2) }
        statusBar.onToggleFadeIn = { [unowned self] in preferences.fadeInEnabled = $0; scheduleRestart(after: 0.2) }
        statusBar.onToggleSeekFadeIn = { [unowned self] in preferences.seekFadeInEnabled = $0; scheduleRestart(after: 0.2) }
        statusBar.onSelectFadeInMs = { [unowned self] in preferences.fadeInMs = $0; scheduleRestart(after: 0.2) }
        statusBar.onToggleSkipGentleEdges = { [unowned self] in preferences.skipGentleEdges = $0; scheduleRestart(after: 0.2) }
        statusBar.onToggleBypassDuringCalls = { [unowned self] in preferences.bypassDuringCalls = $0; evaluateCallState() }
        statusBar.onToggleLoginItem = { [unowned self] in setLoginItem($0) }
        statusBar.onOpenPermissionSettings = { NSWorkspace.shared.open(AudioCapturePermission.settingsURL) }
        statusBar.onQuit = { NSApp.terminate(nil) }
        _ = statusBar

        deviceWatcher = DeviceWatcher { [weak self] in self?.scheduleRestart(after: 0.5) }
        micWatcher = MicActivityWatcher { [weak self] in self?.evaluateCallState() }
        evaluateCallState()

        let center = NSWorkspace.shared.notificationCenter
        // スリープ中は音声デバイスが不安定になるので止め、復帰後に作り直す
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.engine.stop()
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleRestart(after: 2)
        }

        // 終了時は必ずタップを破棄して、元の音声経路に戻す
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }

        scheduleRestart(after: 0)
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }

    /// 設定変更・デバイス変更が連続しても 1 回だけ作り直す
    private func scheduleRestart(after delay: TimeInterval) {
        restartWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.restartEngine() }
        restartWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// 通話中（マイク使用中）かを判定し直す。変わったときだけエンジンを止める／起こす
    private func evaluateCallState() {
        callCheckWorkItem?.cancel()
        let wasHeld = callGate.isHeld
        if !preferences.bypassDuringCalls { callGate = HoldOffGate(releaseDelay: callGate.releaseDelay) }
        let active = preferences.bypassDuringCalls && (micWatcher?.isInUse ?? false)
        let now = ProcessInfo.processInfo.systemUptime
        callGate.update(active: active, now: now)
        if callGate.isHeld != wasHeld { scheduleRestart(after: 0) }

        // マイクが止まった後の解除は、イベントが来ないので自分で再確認を予約する
        if let remaining = callGate.remainingDelay(now: now) {
            let item = DispatchWorkItem { [weak self] in self?.evaluateCallState() }
            callCheckWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining + 0.05, execute: item)
        }
    }

    private func restartEngine() {
        guard preferences.enabled else {
            engine.stop()
            lastError = nil
            return
        }
        // 通話中はタップごと止める。音は元の経路をそのまま通るので、遅延もフェードも掛からない
        guard !callGate.isHeld else {
            engine.stop()
            lastError = nil
            return
        }
        do {
            try engine.start(settings: preferences.fadeSettings,
                             keepAlive: (preferences.keepAliveHz, preferences.keepAliveDB))
            lastError = nil
            deviceWatcher?.watchCurrentDevice()
        } catch {
            lastError = "\(error)"
            // 一時的な失敗（デバイス切替の最中など）に備えて、有効な間は自動で再試行する
            scheduleRestart(after: 5)
        }
    }

    private func setLoginItem(_ enable: Bool) {
        do {
            if enable { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemNote = nil
        } catch {
            loginItemNote = "ログイン項目を変更できませんでした: \(error.localizedDescription)"
        }
    }

    private func makeSnapshot() -> StatusBarController.Snapshot {
        let permission = AudioCapturePermission.current()
        var status: String
        var detail: String?
        if !preferences.enabled {
            status = "停止中（無効）"
        } else if permission == .denied {
            status = "システム音声の録音が許可されていません"
        } else if callGate.isHeld {
            status = "通話中のため一時停止（フェードなし）"
        } else if let error = lastError {
            status = "エラー: \(error)"
        } else if let info = engine.info {
            status = "稼働中"
            detail = "出力: \(info.deviceName)（遅延 \(Int(info.latencyMs.rounded())) ms）"
        } else {
            status = "起動中…"
        }
        if let note = loginItemNote { detail = note }
        return StatusBarController.Snapshot(
            statusLine: status,
            detailLine: detail,
            permissionDenied: permission == .denied,
            loginItemEnabled: SMAppService.mainApp.status == .enabled,
            loginItemNote: loginItemNote ?? (SMAppService.mainApp.status == .requiresApproval ? "システム設定 > 一般 > ログイン項目 で許可が必要です" : nil))
    }
}
