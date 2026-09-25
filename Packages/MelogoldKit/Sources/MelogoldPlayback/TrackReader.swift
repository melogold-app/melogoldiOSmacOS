import CoreMedia
import Foundation
import MelogoldCore

/// Буферы одного фрагмента для рендерера и время, до которого они дотягивают на шкале синхронизатора.
public struct SampleBatch: @unchecked Sendable {
    public let buffers: [CMSampleBuffer]
    public let end: CMTime
}

/// Что известно о треке после чтения начала файла.
public struct TrackTiming: Sendable, Equatable {
    /// Настоящая длительность звука, секунды (без «разгона» кодека в начале).
    public let duration: Double
    public let fragmentCount: Int
}

/// Чтение трека по фрагментам (docs/PROMPT.md §4): начало файла (`moov`, `sidx`) одним запросом — дальше фрагмент за
/// фрагментом через `StreamSource` (загрузки, кэш, googlevideo). Первый звук — после первого фрагмента.
public actor TrackReader {
    public nonisolated let videoId: String
    public let source: StreamSource
    /// Столько байт начала читается сразу: там `moov`, `sidx` и обычно первый фрагмент (~160 КБ у itag 140).
    static let prefixSize = 256 * 1024

    private var header: FragmentedMP4.InitSegment?
    private var index: FragmentedMP4.SegmentIndex?
    private nonisolated(unsafe) var format: CMAudioFormatDescription?
    private var prefix = Data()
    private var totalLength: Int64 = 0
    private var fragments: [Range<Int>] = []

    public init(source: StreamSource) {
        self.source = source
        self.videoId = source.videoId
    }

    /// Прочитать начало файла; повторный вызов ничего не читает.
    @discardableResult
    public func open() async throws -> TrackTiming {
        if let header, !fragments.isEmpty {
            return timing(header)
        }
        let content = try await source.contentInfo()
        totalLength = content.length
        var length = min(Self.prefixLength(content), totalLength)
        while true {
            prefix = try await readFully(offset: 0, length: Int(length))
            if let parsed = try FragmentedMP4.parseHeader(prefix) {
                let (initSegment, segmentIndex, firstFragment) = parsed
                header = initSegment
                index = segmentIndex
                format = try AudioSamples.formatDescription(sampleEntry: initSegment.sampleEntry)
                if let segmentIndex {
                    fragments = segmentIndex.segments.map { $0.offset..<$0.end }
                } else {
                    fragments = try await scanFragments(from: firstFragment)
                }
                guard !fragments.isEmpty else { throw StreamError(.extractor, "в файле нет фрагментов звука") }
                return timing(initSegment)
            }
            guard length < totalLength else { throw StreamError(.extractor, "в начале файла нет moov") }
            length = min(length * 2, totalLength)
        }
    }

    public var fragmentCount: Int { fragments.count }

    /// Сколько читать сразу: ~11 с звука (у YouTube фрагмент — около 10 с), но не меньше 64 КБ. Первый фрагмент
    /// приходит тем же запросом, что и `moov` с `sidx`, — звук после одного запроса к googlevideo.
    static func prefixLength(_ content: StreamContent) -> Int64 {
        guard let ms = content.durationMs, ms > 0 else { return Int64(prefixSize) }
        let bytesPerSecond = Double(content.length) / (Double(ms) / 1000)
        return max(64 * 1024, Int64(bytesPerSecond * 11) + 8 * 1024)
    }

    /// Фрагмент, в котором лежит время `seconds` от начала трека.
    public func fragment(at seconds: Double) -> Int {
        guard let header else { return 0 }
        let mediaSeconds = seconds + Double(header.priming) / Double(header.timescale)
        if let index { return index.segment(at: mediaSeconds) }
        return 0
    }

    /// Буферы фрагмента `number`. `start` — где на шкале синхронизатора начинается трек; `trimBefore` — отсчёты
    /// раньше не нужны (перемотка внутрь фрагмента).
    public func batch(_ number: Int, start: CMTime, trimBefore: CMTime? = nil) async throws -> SampleBatch {
        guard let header, let format, fragments.indices.contains(number) else { throw StreamError(.extractor, "нет фрагмента \(number)") }
        let range = fragments[number]
        let data = try await bytes(range)
        let fragment = try FragmentedMP4.parseFragment(data, moofOffset: range.lowerBound, defaultDuration: header.defaultSampleDuration)
        let mediaTime: Int64
        if let base = fragment.baseDecodeTime {
            mediaTime = Int64(base)
        } else if let index {
            mediaTime = Int64(index.segments[number].startTime)
        } else {
            mediaTime = 0
        }
        let scale = CMTimeScale(header.timescale)
        let pts = CMTimeAdd(start, CMTime(value: mediaTime - header.priming, timescale: scale))
        let buffers = try AudioSamples.sampleBuffers(fragmentData: data, fragment: fragment, format: format,
                                                     timescale: header.timescale, pts: pts, trimBefore: trimBefore)
        let ticks = fragment.durations.reduce(Int64(0)) { $0 + Int64($1) }
        return SampleBatch(buffers: buffers, end: CMTimeAdd(pts, CMTime(value: ticks, timescale: scale)))
    }

    private func timing(_ header: FragmentedMP4.InitSegment) -> TrackTiming {
        let ticks = index?.totalDuration ?? 0
        let seconds = ticks > 0 ? Double(Int64(ticks) - header.priming) / Double(header.timescale) : 0
        return TrackTiming(duration: max(0, seconds), fragmentCount: fragments.count)
    }

    /// Байты диапазона: из начала файла в памяти, иначе через `StreamSource`.
    private func bytes(_ range: Range<Int>) async throws -> Data {
        if range.upperBound <= prefix.count {
            return Data(prefix[(prefix.startIndex + range.lowerBound)..<(prefix.startIndex + range.upperBound)])
        }
        return try await readFully(offset: Int64(range.lowerBound), length: range.count)
    }

    private func readFully(offset: Int64, length: Int) async throws -> Data {
        var result = Data()
        result.reserveCapacity(length)
        while result.count < length {
            try Task.checkCancellation()
            let chunk = try await source.read(offset: offset + Int64(result.count), length: length - result.count)
            if chunk.isEmpty { throw StreamError(.network, "поток оборвался на \(offset + Int64(result.count))") }
            result.append(chunk)
        }
        return result
    }

    /// Файл без `sidx`: фрагменты по заголовкам боксов (`moof` + `mdat`) один за другим.
    private func scanFragments(from start: Int) async throws -> [Range<Int>] {
        var result: [Range<Int>] = []
        var offset = start
        var moofStart: Int?
        while Int64(offset) + 8 <= totalLength {
            let head = try await readFully(offset: Int64(offset), length: 16)
            var size = Int(FragmentedMP4.u32(head, 0))
            if size == 1 { size = Int(FragmentedMP4.u64(head, 8)) }
            if size == 0 { size = Int(totalLength) - offset }
            guard size >= 8 else { break }
            let type = FragmentedMP4.type(head, 0)
            if type == "moof" { moofStart = offset }
            if type == "mdat", let moof = moofStart {
                result.append(moof..<(offset + size))
                moofStart = nil
            }
            offset += size
        }
        return result
    }
}
