import Foundation

/// Что файл говорит о себе: теги iTunes (`moov/udta/meta/ilst`), которые читают Музыка, QuickTime, «Файлы» и проводники.
public struct Mp4Tags: Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    /// Обложка: JPEG или PNG (другие форматы в файл не кладутся).
    public var cover: Data?

    public init(title: String? = nil, artist: String? = nil, album: String? = nil, cover: Data? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.cover = cover
    }
}

/// «Сохранить файлом» (задание 0009; Windows `Mp4Writer`, Android `FileExport` + `Mp4Tags`): DASH-m4a YouTube —
/// фрагментированный MP4 — превращается в обычный .m4a без перекодирования: те же кадры AAC одним `mdat`, `moov` с
/// таблицами отсчётов в начале, теги названия, исполнителя, альбома и обложка.
///
/// Зачем свой писатель: `AVAssetExportSession` читает фрагментированный файл целиком и считает длительность вдвое
/// больше настоящей (сумма `mdhd` и фрагментов, docs/PROMPT.md §9 п. 21) — файл выходит неверным. Здесь длительность —
/// сумма длительностей отсчётов, а разгон кодека из `elst` исходного файла остаётся правкой в `elst` нового.
///
/// Поток YouTube на Apple всегда AAC (itag 140, запасной 139; Opus AVFoundation не играет и не скачивается), поэтому
/// перекодирования, как у Android, нет: `stsd` берётся из исходного файла как есть.
public enum Mp4Writer {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// Поток не собран целиком: обрезан файл или не хватает фрагментов.
        case incomplete(String)
        case noAudio
        /// Больше 4 ГБ — таблицы со 32-битными смещениями не годятся.
        case tooLarge

        public var description: String {
            switch self {
            case .incomplete(let reason): "поток не собран целиком: \(reason)"
            case .noAudio: "в файле нет кадров звука"
            case .tooLarge: "файл больше 4 ГБ"
            }
        }
    }

    /// Файл целиком (`source` — все байты потока) → .m4a с тегами.
    public static func fromFragmented(_ source: Data, tags: Mp4Tags) throws -> Data {
        let plan = try plan(for: source)
        let head = try header(plan, tags: tags)
        var output = Data(head)
        output.reserveCapacity(head.count + plan.mediaLength)
        for chunk in plan.chunks { output.append(source[chunk.source]) }
        return output
    }

    /// То же файлом в файл: исходный файл читается отображением в память, результат пишется кусками — трек в час
    /// длиной не занимает вдвое больше памяти. `destination` создаётся заново.
    public static func write(fragmentedFile source: URL, to destination: URL, tags: Mp4Tags) throws {
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        let plan = try plan(for: data)
        let head = try header(plan, tags: tags)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        do {
            try handle.write(contentsOf: head)
            for chunk in plan.chunks { try handle.write(contentsOf: data[chunk.source]) }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    // MARK: - Разбор исходного файла

    /// Один кусок (`chunk`) нового файла — один фрагмент исходного: его кадры лежат подряд.
    struct Chunk: Equatable {
        /// Где кадры фрагмента в исходном файле.
        let source: Range<Int>
        let samples: Int
        /// Смещение от начала `mdat` нового файла.
        let mediaOffset: Int
    }

    struct Plan {
        let initSegment: FragmentedMP4.InitSegment
        var sizes: [UInt32] = []
        var durations: [UInt32] = []
        var chunks: [Chunk] = []
        var mediaLength = 0
        var totalDuration: UInt64 { durations.reduce(0) { $0 + UInt64($1) } }
    }

    static func plan(for data: Data) throws -> Plan {
        guard let (initSegment, index, _) = try FragmentedMP4.parseHeader(data) else { throw Failure.incomplete("нет moov") }
        // Фрагменты — пары `moof` + `mdat` верхнего уровня; `sidx` не нужен, но, если он есть, сверяется
        let top = FragmentedMP4.boxes(in: data)
        guard top.last?.end == data.count else { throw Failure.incomplete("файл оборван на середине блока") }
        var fragments: [(moof: FragmentedMP4.Box, mdat: FragmentedMP4.Box)] = []
        var position = 0
        while position < top.count {
            guard top[position].type == "moof" else { position += 1; continue }
            guard position + 1 < top.count, top[position + 1].type == "mdat" else { throw Failure.incomplete("у moof нет mdat") }
            fragments.append((top[position], top[position + 1]))
            position += 2
        }
        if let index, index.segments.count != fragments.count || (index.segments.last?.end ?? 0) > data.count {
            throw Failure.incomplete("sidx обещает \(index.segments.count) фрагментов, в файле \(fragments.count)")
        }

        var plan = Plan(initSegment: initSegment)
        for (moof, mdat) in fragments {
            let moofBytes = Data(data[moof.offset..<moof.end])
            let fragment = try FragmentedMP4.parseFragment(moofBytes, moofOffset: moof.offset,
                                                           defaultDuration: initSegment.defaultSampleDuration)
            let length = fragment.sizes.reduce(0, +)
            let start = moof.offset + fragment.dataOffset
            guard start >= mdat.payload, start + length <= mdat.end else { throw Failure.incomplete("кадры вне mdat") }
            plan.chunks.append(Chunk(source: start..<(start + length), samples: fragment.sizes.count, mediaOffset: plan.mediaLength))
            plan.sizes.append(contentsOf: fragment.sizes.map { UInt32($0) })
            plan.durations.append(contentsOf: fragment.durations)
            plan.mediaLength += length
        }
        guard !plan.sizes.isEmpty else { throw Failure.noAudio }
        return plan
    }

    // MARK: - Сборка

    /// `ftyp`, `moov` и заголовок `mdat` — всё до первого кадра.
    static func header(_ plan: Plan, tags: Mp4Tags) throws -> [UInt8] {
        let ftyp = ftyp()
        // moov с условным началом mdat — только чтобы узнать его длину: смещения кусков в stco длины не меняют
        let probe = moov(plan, mediaStart: 0, tags: tags)
        let mediaStart = ftyp.count + probe.count + 8
        guard mediaStart + plan.mediaLength <= Int(UInt32.max) else { throw Failure.tooLarge }
        var output = ftyp
        output.append(contentsOf: moov(plan, mediaStart: mediaStart, tags: tags))
        output.append(contentsOf: be32(UInt32(plan.mediaLength + 8)))
        output.append(contentsOf: Array("mdat".utf8))
        return output
    }

    private static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private static func ftyp() -> [UInt8] {
        var w = BoxWriter()
        w.begin("ftyp")
        w.ascii("M4A ")
        w.u32(0x200)
        for brand in ["M4A ", "mp42", "isom", "iso2"] { w.ascii(brand) }
        w.end()
        return w.output
    }

    private static let matrix: [UInt32] = [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000]

    private static func moov(_ plan: Plan, mediaStart: Int, tags: Mp4Tags) -> [UInt8] {
        let timescale = plan.initSegment.timescale
        let total = plan.totalDuration
        // Разгон кодека: первые `priming` отсчётов не слышны — как в исходном файле, это правка `elst`; длительность
        // фильма и дорожки — уже без него
        let priming = plan.initSegment.priming > 0 && UInt64(plan.initSegment.priming) < total ? UInt64(plan.initSegment.priming) : 0
        let movieDuration = UInt32(clamping: total - priming)
        let mediaDuration = UInt32(clamping: total)

        var w = BoxWriter()
        w.begin("moov")

        w.beginFull("mvhd", 0, 0)
        w.u32(0)
        w.u32(0)
        w.u32(timescale)
        w.u32(movieDuration)
        w.u32(0x0001_0000) // скорость 1,0
        w.u16(0x0100) // громкость 1,0
        w.zeros(10)
        for value in matrix { w.u32(value) }
        w.zeros(24)
        w.u32(2) // следующий номер дорожки
        w.end()

        w.begin("trak")
        w.beginFull("tkhd", 0, 0x3) // включена, в фильме
        w.u32(0)
        w.u32(0)
        w.u32(1)
        w.u32(0)
        w.u32(movieDuration)
        w.zeros(8)
        w.u16(0)
        w.u16(0)
        w.u16(0x0100)
        w.u16(0)
        for value in matrix { w.u32(value) }
        w.u32(0)
        w.u32(0)
        w.end()

        if priming > 0 {
            w.begin("edts")
            w.beginFull("elst", 0, 0)
            w.u32(1)
            w.u32(movieDuration)
            w.u32(UInt32(priming))
            w.u16(1)
            w.u16(0)
            w.end()
            w.end()
        }

        w.begin("mdia")
        w.beginFull("mdhd", 0, 0)
        w.u32(0)
        w.u32(0)
        w.u32(timescale)
        w.u32(mediaDuration)
        w.u16(0x55C4) // «und»
        w.u16(0)
        w.end()
        w.beginFull("hdlr", 0, 0)
        w.u32(0)
        w.ascii("soun")
        w.zeros(12)
        w.raw(Array("SoundHandler\0".utf8))
        w.end()

        w.begin("minf")
        w.beginFull("smhd", 0, 0)
        w.u32(0)
        w.end()
        w.begin("dinf")
        w.beginFull("dref", 0, 0)
        w.u32(1)
        w.beginFull("url ", 0, 1)
        w.end()
        w.end()
        w.end()

        w.begin("stbl")
        w.beginFull("stsd", 0, 0)
        w.u32(1)
        w.raw(Array(plan.initSegment.sampleEntry)) // mp4a с esds — как в исходном файле
        w.end()

        // stts: одинаковые длительности подряд — одной записью
        var runs: [(count: UInt32, delta: UInt32)] = []
        for delta in plan.durations {
            if let last = runs.last, last.delta == delta {
                runs[runs.count - 1].count += 1
            } else {
                runs.append((1, delta))
            }
        }
        w.beginFull("stts", 0, 0)
        w.u32(UInt32(runs.count))
        for run in runs {
            w.u32(run.count)
            w.u32(run.delta)
        }
        w.end()

        // stsc: сколько кадров в куске — меняется редко (на последнем фрагменте)
        var groups: [(first: UInt32, samples: UInt32)] = []
        for (index, chunk) in plan.chunks.enumerated() where groups.last?.samples != UInt32(chunk.samples) {
            groups.append((UInt32(index + 1), UInt32(chunk.samples)))
        }
        w.beginFull("stsc", 0, 0)
        w.u32(UInt32(groups.count))
        for group in groups {
            w.u32(group.first)
            w.u32(group.samples)
            w.u32(1)
        }
        w.end()

        w.beginFull("stsz", 0, 0)
        w.u32(0)
        w.u32(UInt32(plan.sizes.count))
        for size in plan.sizes { w.u32(size) }
        w.end()

        w.beginFull("stco", 0, 0)
        w.u32(UInt32(plan.chunks.count))
        for chunk in plan.chunks { w.u32(UInt32(mediaStart + chunk.mediaOffset)) }
        w.end()

        w.end() // stbl
        w.end() // minf
        w.end() // mdia
        w.end() // trak

        udta(&w, tags: tags)
        w.end() // moov
        return w.output
    }

    /// `udta/meta/ilst`: ©nam, ©ART, ©alb, ©too и covr — как их пишет iTunes.
    private static func udta(_ w: inout BoxWriter, tags: Mp4Tags) {
        var items: [(type: [UInt8], kind: UInt32, data: [UInt8])] = []
        func text(_ name: String, _ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            items.append(([0xA9] + Array(name.utf8), 1, Array(value.utf8)))
        }
        text("nam", tags.title)
        text("ART", tags.artist)
        text("alb", tags.album)
        text("too", "Melogold")
        if let cover = tags.cover, cover.count > 4 {
            let head = Array(cover.prefix(4))
            if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
                items.append((Array("covr".utf8), 14, Array(cover)))
            } else if head.starts(with: [0xFF, 0xD8]) {
                items.append((Array("covr".utf8), 13, Array(cover)))
            }
        }

        w.begin("udta")
        w.beginFull("meta", 0, 0)
        w.beginFull("hdlr", 0, 0)
        w.u32(0)
        w.ascii("mdir")
        w.ascii("appl")
        w.zeros(9)
        w.end()
        w.begin("ilst")
        for item in items {
            w.begin(bytes: item.type)
            w.begin("data")
            w.u32(item.kind)
            w.u32(0)
            w.raw(item.data)
            w.end()
            w.end()
        }
        w.end()
        w.end()
        w.end()
    }

    /// Боксы MP4 по порядку: размер пишется, когда бокс закрыт.
    struct BoxWriter {
        private(set) var output: [UInt8] = []
        private var open: [Int] = []

        mutating func begin(_ type: String) {
            begin(bytes: Array(type.utf8))
        }

        mutating func begin(bytes type: [UInt8]) {
            open.append(output.count)
            u32(0)
            output.append(contentsOf: type)
        }

        mutating func beginFull(_ type: String, _ version: UInt8, _ flags: UInt32) {
            begin(type)
            u8(version)
            u8(UInt8(flags >> 16 & 0xFF))
            u8(UInt8(flags >> 8 & 0xFF))
            u8(UInt8(flags & 0xFF))
        }

        mutating func end() {
            let start = open.removeLast()
            let size = UInt32(output.count - start)
            output.replaceSubrange(start..<(start + 4), with: Mp4Writer.be32(size))
        }

        mutating func u8(_ value: UInt8) { output.append(value) }
        mutating func u16(_ value: UInt16) { output.append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)]) }
        mutating func u32(_ value: UInt32) { output.append(contentsOf: Mp4Writer.be32(value)) }
        mutating func ascii(_ text: String) { output.append(contentsOf: Array(text.utf8)) }
        mutating func raw(_ data: [UInt8]) { output.append(contentsOf: data) }
        mutating func zeros(_ count: Int) { output.append(contentsOf: [UInt8](repeating: 0, count: count)) }
    }
}
