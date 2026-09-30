import AVFoundation
import CoreMedia
import Foundation
import MelogoldCore

/// Рендерер звука и его часы (`AVSampleBufferAudioRenderer` + `AVSampleBufferRenderSynchronizer`) — путь Apple для
/// своих движков потока, работает и с AirPlay 2 (docs/PROMPT.md §4). Все обращения к рендереру — на своей очереди.
/// Поколение отсекает буферы, опоздавшие после перемотки или смены трека.
final class RenderPipeline: @unchecked Sendable {
    let renderer = AVSampleBufferAudioRenderer()
    let synchronizer = AVSampleBufferRenderSynchronizer()
    private let queue = DispatchQueue(label: "app.melogold.render", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: [CMSampleBuffer] = []
    private var requesting = false
    private var generationValue = 0
    private var enqueuedEndValue: CMTime = .zero
    private var handedEndValue: CMTime = .zero
    /// Какую скорость просил сам движок: отличие от скорости синхронизатора — остановка системой (прерывание, маршрут).
    private var expectedRate: Float = 0
    private var automaticFlushHandler: (@Sendable () -> Void)?
    private var observers: [any NSObjectProtocol] = []

    /// Система сбросила очередь рендерера сама (смена маршрута звука, смена скорости): всё, что было отдано, пропало, а
    /// часы идут дальше — без новой подачи звука нет, пока человек не перемотает. Вызывается с произвольного потока.
    var onAutomaticFlush: (@Sendable () -> Void)? {
        get { lock.withLock { automaticFlushHandler } }
        set { lock.withLock { automaticFlushHandler = newValue } }
    }

    init() {
        synchronizer.addRenderer(renderer)
        renderer.audioTimePitchAlgorithm = .timeDomain
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: renderer, queue: nil) { [weak self] note in
            let time = (note.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?.timeValue
            Log.warning("player", "Рендерер сбросил очередь сам (маршрут звука или смена скорости), время сброса \(time.map { String(format: "%.2f", $0.seconds) } ?? "—") с")
            self?.onAutomaticFlush?()
        })
        observers.append(center.addObserver(forName: .AVSampleBufferAudioRendererOutputConfigurationDidChange, object: renderer, queue: nil) { _ in
            Log.info("player", "Выход звука сменил настройки (формат устройства не совпал с потоком)")
        })
        observers.append(center.addObserver(forName: AVSampleBufferRenderSynchronizer.rateDidChangeNotification, object: synchronizer, queue: nil) { [weak self] _ in
            guard let self else { return }
            let actual = synchronizer.rate
            let expected = lock.withLock { expectedRate }
            if actual != expected { Log.warning("player", "Синхронизатор сменил скорость сам: \(actual), движок просил \(expected) — прерывание звука?") }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    var generation: Int { lock.withLock { generationValue } }

    /// До какого времени шкалы подача приняла отсчёты (часть ещё ждёт в очереди `pending`).
    var enqueuedEnd: CMTime { lock.withLock { enqueuedEndValue } }

    /// До какого времени шкалы отсчёты уже в самом рендерере. Пока `pending` не пуст, а рендерер доиграл всё отданное, —
    /// подача встала.
    var handedEnd: CMTime { lock.withLock { handedEndValue } }

    /// Сколько буферов ждёт места в рендерере.
    var pendingCount: Int { lock.withLock { pending.count } }

    var currentTime: CMTime { synchronizer.currentTime() }

    var volume: Float {
        get { renderer.volume }
        set { renderer.volume = newValue }
    }

    /// Всё отдать заново с времени `time`: очередь рендерера очищается, часы стоят на `time`. Новое поколение.
    @discardableResult
    func reset(to time: CMTime) -> Int {
        let generation = lock.withLock { () -> Int in
            generationValue += 1
            pending.removeAll()
            enqueuedEndValue = time
            handedEndValue = time
            return generationValue
        }
        queue.sync {
            if requesting {
                renderer.stopRequestingMediaData()
                requesting = false
            }
            renderer.flush()
        }
        lock.withLock { expectedRate = 0 }
        synchronizer.setRate(0, time: time)
        return generation
    }

    func append(_ batch: SampleBatch, generation: Int) {
        queue.async { [self] in
            let accepted = lock.withLock { () -> Bool in
                guard generation == generationValue else { return false }
                pending.append(contentsOf: batch.buffers)
                if CMTimeCompare(batch.end, enqueuedEndValue) > 0 { enqueuedEndValue = batch.end }
                return true
            }
            guard accepted else { return }
            if !requesting {
                requesting = true
                renderer.requestMediaDataWhenReady(on: queue) { [weak self] in self?.drain() }
            }
        }
    }

    private func drain() {
        while renderer.isReadyForMoreMediaData {
            let next = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
            guard let next else {
                renderer.stopRequestingMediaData()
                requesting = false
                return
            }
            renderer.enqueue(next)
            let end = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(next), CMSampleBufferGetDuration(next))
            lock.withLock { if CMTimeCompare(end, handedEndValue) > 0 { handedEndValue = end } }
        }
    }

    /// Отбросить всё, что подано с времени `time` и дальше: очередь изменилась после текущего трека, а следующий
    /// уже стоял на шкале. `false` — рендерер не смог (время слишком близко к текущему).
    func truncate(from time: CMTime) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            queue.async { [self] in
                lock.withLock {
                    pending.removeAll { CMTimeCompare(CMSampleBufferGetPresentationTimeStamp($0), time) >= 0 }
                }
                renderer.flush(fromSourceTime: time) { [self] success in
                    if success {
                        lock.withLock {
                            if CMTimeCompare(enqueuedEndValue, time) > 0 { enqueuedEndValue = time }
                            if CMTimeCompare(handedEndValue, time) > 0 { handedEndValue = time }
                        }
                    }
                    continuation.resume(returning: success)
                }
            }
        }
    }

    func setRate(_ rate: Float) {
        lock.withLock { expectedRate = rate }
        synchronizer.rate = rate
    }

    var rate: Float { synchronizer.rate }

    /// Одна строка для журнала, когда часы встали или звука нет: что у подачи и у рендерера.
    var diagnostics: String {
        let (pendingCount, end, handed) = lock.withLock { (pending.count, enqueuedEndValue, handedEndValue) }
        let ready = queue.sync { renderer.isReadyForMoreMediaData }
        let error = renderer.error.map { " \($0.localizedDescription)" } ?? ""
        return String(format: "скорость %.2f, время %.2f, принято до %.2f, в рендерере до %.2f, ждёт %d буферов, рендерер %d, готов %@%@",
                      synchronizer.rate, synchronizer.currentTime().seconds, end.seconds, handed.seconds, pendingCount,
                      renderer.status.rawValue, ready ? "да" : "нет", error)
    }
}
