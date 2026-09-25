import AVFoundation
import Foundation
import MelogoldCore

/// Аудиосессия (docs/PROMPT.md §4 «Плеер», §5.6 «Звук»): категория `.playback`, политика `.longFormAudio`, фоновый звук.
/// Звонок и Siri ставят паузу (это делает сам AVPlayer), по окончании прерывания с `shouldResume` — продолжить.
/// Отключение наушников ставит паузу, как в системных плеерах.
///
/// На часах длинное аудио играет только в Bluetooth: `activate()` сам берёт знакомые наушники или показывает
/// системный выбор, а без устройства возвращает `false`. На Mac аудиосессии нет.
@MainActor
final class AudioSessionController {
    var onInterruptionEnded: ((Bool) -> Void)?
    var onRouteLost: (() -> Void)?
    private var configured = false
    private var active = false
    private var tokens: [any NSObjectProtocol] = []

    init() {
        #if !os(macOS)
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            MainActor.assumeIsolated {
                if type == .ended { self?.onInterruptionEnded?(options.contains(.shouldResume)) }
            }
        })
        tokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated {
                if reason == .oldDeviceUnavailable { self?.onRouteLost?() }
            }
        })
        #endif
    }

    /// Включить сессию перед звуком. `false` — на часах нет Bluetooth-устройства.
    func activate() async -> Bool {
        #if os(macOS)
        return true
        #else
        let session = AVAudioSession.sharedInstance()
        if !configured {
            do {
                try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
                configured = true
            } catch {
                Log.error("audio", "Категория аудиосессии не установлена: \(error.localizedDescription)")
            }
        }
        if active { return true }
        #if os(watchOS)
        do {
            active = try await session.activate()
            if !active { Log.warning("audio", "Часы: аудиоустройство не выбрано") }
            return active
        } catch {
            Log.warning("audio", "Часы: нет Bluetooth-наушников или колонки — \(error.localizedDescription)")
            return false
        }
        #else
        do {
            try session.setActive(true)
            active = true
        } catch {
            Log.error("audio", "Аудиосессия не включилась: \(error.localizedDescription)")
        }
        return true
        #endif
        #endif
    }
}
