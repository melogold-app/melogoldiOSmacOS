import AVFoundation
import CoreMedia
import Foundation

/// Уровни звука в момент шкалы: низ, середина, верх (столбики «играет», docs/PROMPT.md §4, Android `AudioLevels`).
public struct LevelFrame: Sendable {
    public var time: Double
    public var low: Float
    public var mid: Float
    public var high: Float
}

/// Столбики под реальный звук: те же сжатые буферы, что уходят рендереру, декодируются в PCM (`AVAudioConverter`)
/// только для замера — моно (среднее каналов), три полосы простыми фильтрами (до 200 Гц, 200 Гц … 3 кГц, выше 3 кГц),
/// RMS каждые 1/30 с. Те же моно-сэмплы идут в спектр живого фона «Сейчас играет» (`SpectrumAnalyzer`, задание 0031):
/// звук декодируется один раз. Разрешения на микрофон не нужно: звук свой. Время кадра — на шкале синхронизатора,
/// поэтому задержку вывода учитывают часы синхронизатора.
final class LevelAnalyzer {
    static let framesPerSecond = 30.0
    private let converter: AVAudioConverter
    private let input: AVAudioFormat
    private let output: AVAudioFormat
    private var lowState: Float = 0
    private var midState: Float = 0
    private let lowAlpha: Float
    private let midAlpha: Float
    private let spectrum = SpectrumAnalyzer()
    private var mono: [Float] = []

    init?(format: CMAudioFormatDescription) {
        let input = AVAudioFormat(cmAudioFormatDescription: format)
        // Каналы — как у звука: моно — их среднее (задание 0031, §2), а не первый канал, как дал бы конвертер
        guard input.sampleRate > 0, input.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: input.sampleRate,
                                         channels: input.channelCount, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }
        self.input = input
        self.output = output
        self.converter = converter
        let rate = Float(input.sampleRate)
        lowAlpha = 1 - exp(-2 * .pi * 200 / rate)
        midAlpha = 1 - exp(-2 * .pi * 3000 / rate)
    }

    /// Перемотка: прежнее состояние декодера и фильтров не относится к новому месту.
    func reset() {
        converter.reset()
        spectrum.reset()
        lowState = 0
        midState = 0
    }

    /// Кадры уровней буферов (время — начало буфера на шкале плюс номер кадра) и измерения спектра.
    func analyze(_ buffers: [CMSampleBuffer]) -> (levels: [LevelFrame], spectrum: [SpectrumFrame]) {
        var frames: [LevelFrame] = []
        var measurements: [SpectrumFrame] = []
        for buffer in buffers {
            guard let pcm = decode(buffer), let channels = pcm.floatChannelData else { continue }
            let count = Int(pcm.frameLength)
            let channelCount = Int(pcm.format.channelCount)
            if mono.count < count { mono = [Float](repeating: 0, count: count) }
            for i in 0..<count {
                var sum: Float = 0
                for channel in 0..<channelCount { sum += channels[channel][i] }
                mono[i] = sum / Float(channelCount)
            }
            let start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            measurements += mono.withUnsafeBufferPointer { samples in
                spectrum.feed(UnsafeBufferPointer(rebasing: samples[0..<count]), start: start, rate: input.sampleRate)
            }
            let frameSize = max(1, Int(input.sampleRate / Self.framesPerSecond))
            var index = 0
            var frameNumber = 0
            while index < count {
                let end = min(index + frameSize, count)
                var low: Float = 0, mid: Float = 0, high: Float = 0
                for i in index..<end {
                    let x = mono[i]
                    lowState += lowAlpha * (x - lowState)
                    midState += midAlpha * (x - midState)
                    let l = lowState, m = midState - lowState, h = x - midState
                    low += l * l
                    mid += m * m
                    high += h * h
                }
                let n = Float(end - index)
                frames.append(LevelFrame(time: start + Double(frameNumber) / Self.framesPerSecond,
                                         low: (low / n).squareRoot(), mid: (mid / n).squareRoot(), high: (high / n).squareRoot()))
                index = end
                frameNumber += 1
            }
        }
        return (frames, measurements)
    }

    private func decode(_ buffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        let packets = CMSampleBufferGetNumSamples(buffer)
        guard packets > 0, let block = CMSampleBufferGetDataBuffer(buffer) else { return nil }
        var descriptionsPointer: UnsafePointer<AudioStreamPacketDescription>?
        var descriptionsSize = 0
        guard CMSampleBufferGetAudioStreamPacketDescriptionsPtr(buffer, packetDescriptionsPointerOut: &descriptionsPointer,
                                                                sizeOut: &descriptionsSize) == noErr,
              let descriptionsPointer else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        let maxPacket = (0..<packets).map { Int(descriptionsPointer[$0].mDataByteSize) }.max() ?? 0
        let compressed = AVAudioCompressedBuffer(format: input, packetCapacity: AVAudioPacketCount(packets), maximumPacketSize: maxPacket)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: compressed.data) == kCMBlockBufferNoErr,
              let target = compressed.packetDescriptions else { return nil }
        for i in 0..<packets { target[i] = descriptionsPointer[i] }
        compressed.byteLength = UInt32(length)
        compressed.packetCount = AVAudioPacketCount(packets)

        let framesPerPacket = max(1, Int(input.streamDescription.pointee.mFramesPerPacket))
        guard let pcm = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(packets * framesPerPacket)) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return compressed
        }
        guard status != .error, pcm.frameLength > 0 else { return nil }
        return pcm
    }
}
