import Foundation

/// Разбор DASH-m4a YouTube — фрагментированного MP4 (ISO/IEC 14496-12): `ftyp`, `moov` (формат звука), `sidx`
/// (где какой фрагмент), затем пары `moof`+`mdat`.
///
/// Зачем свой разбор: AVPlayer у фрагментированного MP4 перед стартом прочитывает весь файл — по сети звук через
/// 6–10 с, а сегменты HLS через `AVAssetResourceLoader` роняют MediaToolbox (docs/PROMPT.md §9 п. 21). Свой разбор
/// даёт звук после первого фрагмента и честную длительность (у AVFoundation она выходит вдвое больше).
public enum FragmentedMP4 {
    public struct ParseError: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// Бокс: тип, смещение от начала файла, полный размер, размер заголовка.
    public struct Box: Equatable {
        public let type: String
        public let offset: Int
        public let size: Int
        public let headerSize: Int

        public var end: Int { offset + size }
        public var payload: Int { offset + headerSize }
    }

    /// Что нужно для звука: запись `stsd` (формат AAC вместе с `esds`), шкала времени, сдвиг начала (`elst`).
    public struct InitSegment: Equatable {
        public let sampleEntry: Data
        public let timescale: UInt32
        /// `media_time` первой правки `elst`: столько отсчётов в начале — «разгон» кодека, их не слышно.
        public let priming: Int64
        public let trackId: UInt32
        public let defaultSampleDuration: UInt32?
    }

    /// Фрагмент из `sidx`: абсолютное смещение `moof`, размер `moof`+`mdat`, длительность и начало в отсчётах.
    public struct Segment: Equatable {
        public let offset: Int
        public let size: Int
        public let duration: UInt64
        public let startTime: UInt64

        public var end: Int { offset + size }
    }

    public struct SegmentIndex: Equatable {
        public let timescale: UInt32
        public let segments: [Segment]

        public var totalDuration: UInt64 { segments.reduce(0) { $0 + $1.duration } }

        /// Фрагмент, в котором лежит время `seconds`.
        public func segment(at seconds: Double) -> Int {
            let target = UInt64(max(0, seconds) * Double(timescale))
            return segments.lastIndex { $0.startTime <= target } ?? 0
        }
    }

    /// Один фрагмент: время первого отсчёта (`tfdt`), размеры и длительности отсчётов, где лежат их байты.
    public struct Fragment: Equatable {
        public let baseDecodeTime: UInt64?
        public let sizes: [Int]
        public let durations: [UInt32]
        /// Смещение байтов первого отсчёта от начала `moof`.
        public let dataOffset: Int
    }

    // MARK: - Боксы

    static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) << 8 | UInt16(data[base + 1])
    }

    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base]) << 24 | UInt32(data[base + 1]) << 16 | UInt32(data[base + 2]) << 8 | UInt32(data[base + 3])
    }

    static func u64(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(u32(data, offset)) << 32 | UInt64(u32(data, offset + 4))
    }

    static func type(_ data: Data, _ offset: Int) -> String {
        let base = data.startIndex + offset
        return String(decoding: data[(base + 4)..<(base + 8)], as: UTF8.self)
    }

    /// Боксы на отрезке `[start, end)` данных `data` (смещения — от начала `data`). Неполный последний бокс
    /// не возвращается.
    public static func boxes(in data: Data, from start: Int = 0, to end: Int? = nil) -> [Box] {
        let limit = end ?? data.count
        var result: [Box] = []
        var offset = start
        while offset + 8 <= limit {
            var size = Int(u32(data, offset))
            var header = 8
            if size == 1 {
                guard offset + 16 <= limit else { break }
                size = Int(u64(data, offset + 8))
                header = 16
            } else if size == 0 {
                size = limit - offset
            }
            guard size >= header, offset + size <= limit else { break }
            result.append(Box(type: type(data, offset), offset: offset, size: size, headerSize: header))
            offset += size
        }
        return result
    }

    /// Первый вложенный бокс по пути типов.
    static func find(_ path: [String], in data: Data, within box: Box) -> Box? {
        var current = box
        for name in path {
            let start = current.payload + (["stsd"].contains(current.type) ? 8 : 0)
            guard let next = boxes(in: data, from: start, to: current.end).first(where: { $0.type == name }) else { return nil }
            current = next
        }
        return current
    }

    // MARK: - Начало файла

    /// Разбор начала файла: `moov` и `sidx`. `nil` — байтов пока мало (нужно дочитать).
    public static func parseHeader(_ data: Data) throws -> (InitSegment, SegmentIndex?, firstFragment: Int)? {
        let top = boxes(in: data)
        guard let moov = top.first(where: { $0.type == "moov" }) else {
            if top.contains(where: { $0.type == "moof" || $0.type == "mdat" }) { throw ParseError(message: "moov не в начале файла") }
            return nil
        }
        guard let trak = find(["trak"], in: data, within: moov),
              let mdhd = find(["mdia", "mdhd"], in: data, within: trak),
              let stsd = find(["mdia", "minf", "stbl", "stsd"], in: data, within: trak) else {
            throw ParseError(message: "в moov нет трека со звуком")
        }
        let mdhdVersion = data[data.startIndex + mdhd.payload]
        let timescale = mdhdVersion == 1 ? u32(data, mdhd.payload + 20) : u32(data, mdhd.payload + 12)
        guard timescale > 0 else { throw ParseError(message: "шкала времени 0") }
        let entryOffset = stsd.payload + 8
        let entrySize = Int(u32(data, entryOffset))
        guard entrySize > 8, entryOffset + entrySize <= stsd.end else { throw ParseError(message: "битая запись stsd") }
        let entry = Data(data[(data.startIndex + entryOffset)..<(data.startIndex + entryOffset + entrySize)])

        var priming: Int64 = 0
        if let elst = find(["edts", "elst"], in: data, within: trak) {
            let version = data[data.startIndex + elst.payload]
            let count = u32(data, elst.payload + 4)
            if count > 0 {
                priming = version == 1
                    ? Int64(bitPattern: u64(data, elst.payload + 16))
                    : Int64(Int32(bitPattern: u32(data, elst.payload + 12)))
                if priming < 0 { priming = 0 }
            }
        }
        let tkhd = find(["tkhd"], in: data, within: trak)
        let trackId = tkhd.map { data[data.startIndex + $0.payload] == 1 ? u32(data, $0.payload + 20) : u32(data, $0.payload + 12) } ?? 1
        var defaultDuration: UInt32?
        if let trex = find(["mvex", "trex"], in: data, within: moov) {
            let value = u32(data, trex.payload + 12)
            defaultDuration = value > 0 ? value : nil
        }
        let initSegment = InitSegment(sampleEntry: entry, timescale: timescale, priming: priming, trackId: trackId,
                                      defaultSampleDuration: defaultDuration)

        var index: SegmentIndex?
        var firstFragment = moov.end
        if let sidx = top.first(where: { $0.type == "sidx" }) {
            index = try parseSegmentIndex(data, sidx)
            firstFragment = index?.segments.first?.offset ?? sidx.end
        } else if let moof = top.first(where: { $0.type == "moof" }) {
            firstFragment = moof.offset
        } else if top.last?.type == "moov" || top.last?.type == "ftyp" {
            // sidx может идти сразу за moov, а он ещё не дочитан
            let after = moov.end
            if data.count < after + 8 { return nil }
            if type(data, after) == "sidx" { return nil }
        }
        return (initSegment, index, firstFragment)
    }

    static func parseSegmentIndex(_ data: Data, _ sidx: Box) throws -> SegmentIndex {
        let version = data[data.startIndex + sidx.payload]
        var p = sidx.payload + 4 + 4 // version/flags, reference_ID
        let timescale = u32(data, p); p += 4
        var time: UInt64
        var firstOffset: UInt64
        if version == 0 {
            time = UInt64(u32(data, p)); firstOffset = UInt64(u32(data, p + 4)); p += 8
        } else {
            time = u64(data, p); firstOffset = u64(data, p + 8); p += 16
        }
        p += 2
        let count = Int(u16(data, p)); p += 2
        guard timescale > 0, p + count * 12 <= sidx.end else { throw ParseError(message: "битый sidx") }
        var offset = sidx.end + Int(firstOffset)
        var segments: [Segment] = []
        for _ in 0..<count {
            let reference = u32(data, p)
            let size = Int(reference & 0x7FFF_FFFF)
            let duration = UInt64(u32(data, p + 4))
            segments.append(Segment(offset: offset, size: size, duration: duration, startTime: time))
            offset += size
            time += duration
            p += 12
        }
        return SegmentIndex(timescale: timescale, segments: segments)
    }

    // MARK: - Фрагмент

    /// Разбор `moof` в начале `data` (дальше — его `mdat`). Смещения — от начала `moof`; `moofOffset` — где `moof`
    /// лежит в файле (нужен, только если в `tfhd` задан абсолютный `base_data_offset`).
    public static func parseFragment(_ data: Data, moofOffset: Int = 0, defaultDuration: UInt32?) throws -> Fragment {
        guard let moof = boxes(in: data).first, moof.type == "moof" else { throw ParseError(message: "нет moof") }
        guard let traf = boxes(in: data, from: moof.payload, to: moof.end).first(where: { $0.type == "traf" }) else {
            throw ParseError(message: "нет traf")
        }
        var baseOffset = 0 // default-base-is-moof и прочие случаи YouTube: база — начало moof
        var fragmentDefaultDuration = defaultDuration
        var defaultSize: UInt32?
        var baseTime: UInt64?
        var sizes: [Int] = []
        var durations: [UInt32] = []
        var dataOffset: Int?
        for box in boxes(in: data, from: traf.payload, to: traf.end) {
            switch box.type {
            case "tfhd":
                let flags = u32(data, box.payload) & 0xFFFFFF
                var p = box.payload + 8
                if flags & 0x1 != 0 { baseOffset = Int(u64(data, p)) - moofOffset; p += 8 }
                if flags & 0x2 != 0 { p += 4 }
                if flags & 0x8 != 0 { fragmentDefaultDuration = u32(data, p); p += 4 }
                if flags & 0x10 != 0 { defaultSize = u32(data, p); p += 4 }
            case "tfdt":
                let version = data[data.startIndex + box.payload]
                baseTime = version == 1 ? u64(data, box.payload + 4) : UInt64(u32(data, box.payload + 4))
            case "trun":
                let flags = u32(data, box.payload) & 0xFFFFFF
                let count = Int(u32(data, box.payload + 4))
                var p = box.payload + 8
                var runOffset = 0
                if flags & 0x1 != 0 { runOffset = Int(Int32(bitPattern: u32(data, p))); p += 4 }
                if flags & 0x4 != 0 { p += 4 }
                let stride = (flags & 0x100 != 0 ? 4 : 0) + (flags & 0x200 != 0 ? 4 : 0) + (flags & 0x400 != 0 ? 4 : 0) + (flags & 0x800 != 0 ? 4 : 0)
                guard p + count * stride <= box.end else { throw ParseError(message: "битый trun") }
                for _ in 0..<count {
                    var duration = fragmentDefaultDuration ?? 1024
                    var size = Int(defaultSize ?? 0)
                    if flags & 0x100 != 0 { duration = u32(data, p); p += 4 }
                    if flags & 0x200 != 0 { size = Int(u32(data, p)); p += 4 }
                    if flags & 0x400 != 0 { p += 4 }
                    if flags & 0x800 != 0 { p += 4 }
                    sizes.append(size)
                    durations.append(duration)
                }
                if dataOffset == nil { dataOffset = baseOffset + runOffset }
            default:
                break
            }
        }
        guard !sizes.isEmpty, let dataOffset, sizes.allSatisfy({ $0 > 0 }) else { throw ParseError(message: "пустой фрагмент") }
        return Fragment(baseDecodeTime: baseTime, sizes: sizes, durations: durations, dataOffset: dataOffset)
    }
}
