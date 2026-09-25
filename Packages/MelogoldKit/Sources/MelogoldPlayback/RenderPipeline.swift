import AVFoundation
import CoreMedia
import Foundation

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

    init() {
        synchronizer.addRenderer(renderer)
        renderer.audioTimePitchAlgorithm = .timeDomain
    }

    var generation: Int { lock.withLock { generationValue } }

    /// До какого времени шкалы рендереру уже отданы отсчёты.
    var enqueuedEnd: CMTime { lock.withLock { enqueuedEndValue } }

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
            return generationValue
        }
        queue.sync {
            if requesting {
                renderer.stopRequestingMediaData()
                requesting = false
            }
            renderer.flush()
        }
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
        }
    }

    func setRate(_ rate: Float) {
        synchronizer.rate = rate
    }

    var rate: Float { synchronizer.rate }
}
