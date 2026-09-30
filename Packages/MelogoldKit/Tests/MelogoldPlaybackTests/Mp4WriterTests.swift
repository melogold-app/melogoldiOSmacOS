import AVFoundation
import Foundation
import Testing
@testable import MelogoldPlayback

/// DASH-m4a как у YouTube (`ftyp`, `moov` без отсчётов, `sidx`, пары `moof`+`mdat`), но с кадрами, у которых байты —
/// по номеру: в результате видно, какой кадр где лежит. Музыки внутри нет.
private enum SampleFile {
    struct Built {
        var file: Data
        var frames: [Data]
        /// Сколько кадров в каждом фрагменте.
        var perFragment: [Int]
    }

    static let timescale: UInt32 = 44_100
    static let priming: UInt32 = 1600

    static func frame(_ number: Int, size: Int) -> Data {
        Data((0..<size).map { UInt8(truncatingIfNeeded: number * 7 + $0) })
    }

    /// `fragments` фрагментов по `perFragment` кадров, последний — вдвое короче. `sidx` — по желанию (у части файлов его нет).
    static func make(fragments: Int, perFragment: Int, withSidx: Bool = true) -> Built {
        typealias S = SyntheticMP4
        let ftyp = S.box("ftyp", Data("dash".utf8) + S.be32(0) + Data("iso6mp41".utf8))
        let mdhd = S.full("mdhd", S.be32(0) + S.be32(0) + S.be32(timescale) + S.be32(0) + S.be16(0x55C4) + S.be16(0))
        let stbl = S.box("stbl", S.full("stsd", S.be32(1) + S.mp4a) + S.full("stts", S.be32(0)) + S.full("stsc", S.be32(0))
                         + S.full("stsz", S.be32(0) + S.be32(0)) + S.full("stco", S.be32(0)))
        let minf = S.box("minf", S.full("smhd", S.be32(0)) + stbl)
        let hdlr = S.full("hdlr", S.be32(0) + Data("soun".utf8) + Data(count: 12) + Data([0]))
        let tkhd = S.full("tkhd", flags: 3, S.be32(0) + S.be32(0) + S.be32(1) + S.be32(0) + S.be32(0) + Data(count: 60))
        let elst = S.full("elst", S.be32(1) + S.be32(0) + S.be32(priming) + S.be16(1) + S.be16(0))
        let trak = S.box("trak", tkhd + S.box("edts", elst) + S.box("mdia", mdhd + hdlr + minf))
        let trex = S.full("trex", S.be32(1) + S.be32(1) + S.be32(1024) + S.be32(0) + S.be32(0))
        let moov = S.box("moov", S.full("mvhd", S.be32(0) + S.be32(0) + S.be32(timescale) + S.be32(0) + Data(count: 80)) + S.box("mvex", trex) + trak)

        var frames: [Data] = []
        var perFragmentCounts: [Int] = []
        var chunks: [Data] = []
        var number = 0
        for index in 0..<fragments {
            let count = index == fragments - 1 ? max(1, perFragment / 2) : perFragment
            let samples = (0..<count).map { _ -> Data in
                number += 1
                return frame(number, size: 20 + number % 5)
            }
            frames += samples
            perFragmentCounts.append(count)
            let tfhd = S.full("tfhd", flags: 0x02002A, S.be32(1) + S.be32(1) + S.be32(1024) + S.be32(0))
            let tfdt = S.full("tfdt", S.be32(UInt32(index * perFragment * 1024)))
            func moof(dataOffset: Int) -> Data {
                var trunPayload = S.be32(UInt32(count)) + S.be32(UInt32(dataOffset))
                for sample in samples { trunPayload += S.be32(UInt32(sample.count)) }
                let trun = S.full("trun", flags: 0x201, trunPayload)
                return S.box("moof", S.full("mfhd", S.be32(UInt32(index + 1))) + S.box("traf", tfhd + tfdt + trun))
            }
            // Смещение данных — от начала moof: сначала moof с условным смещением, чтобы узнать его длину
            let moofLength = moof(dataOffset: 0).count
            let mdat = S.box("mdat", samples.reduce(Data()) { $0 + $1 })
            chunks.append(moof(dataOffset: moofLength + 8) + mdat)
        }
        var sidxPayload = S.be32(1) + S.be32(timescale) + S.be32(0) + S.be32(0) + S.be16(0) + S.be16(UInt16(chunks.count))
        for chunk in chunks { sidxPayload += S.be32(UInt32(chunk.count)) + S.be32(UInt32(1024 * perFragment)) + S.be32(0x9000_0000) }
        let sidx = S.full("sidx", sidxPayload)
        let file = ftyp + moov + (withSidx ? sidx : Data()) + chunks.reduce(Data()) { $0 + $1 }
        return Built(file: file, frames: frames, perFragment: perFragmentCounts)
    }
}

/// Поиск боксов в готовом файле по пути вида «moov/trak/mdia/minf/stbl/stsz».
private struct Boxes {
    let data: Data

    /// Начало содержимого и конец бокса по пути; `meta` — полный бокс, дети идут после версии и флагов.
    func find(_ path: String) -> Range<Int>? {
        var start = 0
        var end = data.count
        for name in path.split(separator: "/") {
            var found = false
            var offset = start
            while offset + 8 <= end {
                let size = Int(u32(offset))
                // Latin-1, чтобы байт 0xA9 в ©nam читался как «©»
                let type = String(data: data[(data.startIndex + offset + 4)..<(data.startIndex + offset + 8)], encoding: .isoLatin1) ?? ""
                guard size >= 8, offset + size <= end else { return nil }
                if type == String(name) {
                    start = offset + 8 + (type == "meta" ? 4 : 0)
                    end = offset + size
                    found = true
                    break
                }
                offset += size
            }
            if !found { return nil }
        }
        return start..<end
    }

    func u32(_ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base]) << 24 | UInt32(data[base + 1]) << 16 | UInt32(data[base + 2]) << 8 | UInt32(data[base + 3])
    }

    func slice(_ range: Range<Int>) -> Data {
        Data(data[(data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound)])
    }
}

@Suite("Mp4Writer — fMP4 YouTube в обычный .m4a (задание 0009)")
struct Mp4WriterTests {
    private let tags = Mp4Tags(title: "Бармалей", artist: "Gorilla Glue, Lil Nakur", album: "Сингл")

    @Test func framesAreTheSameAndInOrder() throws {
        let sample = SampleFile.make(fragments: 3, perFragment: 4)
        let m4a = try Mp4Writer.fromFragmented(sample.file, tags: tags)
        let boxes = Boxes(data: m4a)

        #expect(String(decoding: m4a[4..<8], as: UTF8.self) == "ftyp")
        let stsz = try #require(boxes.find("moov/trak/mdia/minf/stbl/stsz"))
        #expect(boxes.u32(stsz.lowerBound + 8) == UInt32(sample.frames.count))
        for (index, frame) in sample.frames.enumerated() {
            #expect(boxes.u32(stsz.lowerBound + 12 + index * 4) == UInt32(frame.count))
        }
        // mdat — все кадры подряд, и больше ничего
        let mdat = try #require(boxes.find("mdat"))
        #expect(boxes.slice(mdat) == sample.frames.reduce(Data()) { $0 + $1 })
        // moov стоит перед mdat: файл играет, ещё не дочитанный
        let moov = try #require(boxes.find("moov"))
        #expect(moov.lowerBound < mdat.lowerBound)
    }

    @Test func chunksPointAtFragments() throws {
        let sample = SampleFile.make(fragments: 3, perFragment: 4)
        let m4a = try Mp4Writer.fromFragmented(sample.file, tags: tags)
        let boxes = Boxes(data: m4a)

        // Куски — по фрагменту: смещение каждого указывает на его первый кадр
        let stco = try #require(boxes.find("moov/trak/mdia/minf/stbl/stco"))
        #expect(boxes.u32(stco.lowerBound + 4) == 3)
        let firsts = [0, 4, 8]
        for (chunk, first) in firsts.enumerated() {
            let offset = Int(boxes.u32(stco.lowerBound + 8 + chunk * 4))
            #expect(boxes.slice(offset..<(offset + sample.frames[first].count)) == sample.frames[first])
        }
        // stsc: два куска по 4 кадра и последний — по 2
        let stsc = try #require(boxes.find("moov/trak/mdia/minf/stbl/stsc"))
        #expect(boxes.u32(stsc.lowerBound + 4) == 2)
        #expect([boxes.u32(stsc.lowerBound + 8), boxes.u32(stsc.lowerBound + 12), boxes.u32(stsc.lowerBound + 16)] == [1, 4, 1])
        #expect([boxes.u32(stsc.lowerBound + 20), boxes.u32(stsc.lowerBound + 24), boxes.u32(stsc.lowerBound + 28)] == [3, 2, 1])
        // stts: все кадры по 1024 — одной записью
        let stts = try #require(boxes.find("moov/trak/mdia/minf/stbl/stts"))
        #expect(boxes.u32(stts.lowerBound + 4) == 1)
        #expect(boxes.u32(stts.lowerBound + 8) == UInt32(sample.frames.count))
        #expect(boxes.u32(stts.lowerBound + 12) == 1024)
    }

    @Test func durationIsTheSumOfSamples() throws {
        let sample = SampleFile.make(fragments: 3, perFragment: 4)
        let m4a = try Mp4Writer.fromFragmented(sample.file, tags: tags)
        let boxes = Boxes(data: m4a)
        let ticks = UInt32(sample.frames.count * 1024)

        let mdhd = try #require(boxes.find("moov/trak/mdia/mdhd"))
        #expect(boxes.u32(mdhd.lowerBound + 12) == SampleFile.timescale)
        #expect(boxes.u32(mdhd.lowerBound + 16) == ticks) // шкала — не сумма с фрагментами, длительность не удваивается
        // Разгон кодека из исходного `elst` остаётся правкой: фильм и дорожка — на него короче
        let mvhd = try #require(boxes.find("moov/mvhd"))
        #expect(boxes.u32(mvhd.lowerBound + 16) == ticks - SampleFile.priming)
        let elst = try #require(boxes.find("moov/trak/edts/elst"))
        #expect(boxes.u32(elst.lowerBound + 8) == ticks - SampleFile.priming)
        #expect(boxes.u32(elst.lowerBound + 12) == SampleFile.priming)
        // Форматы звука — из исходного файла как есть: AudioSpecificConfig в DecoderSpecificInfo
        let stsd = try #require(boxes.find("moov/trak/mdia/minf/stbl/stsd"))
        #expect(boxes.slice(stsd).range(of: Data([0x05, 0x02, 0x12, 0x10])) != nil)
    }

    @Test func tagsAndCoverAreWritten() throws {
        let sample = SampleFile.make(fragments: 2, perFragment: 3)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4])
        var withCover = tags
        withCover.cover = jpeg
        let m4a = try Mp4Writer.fromFragmented(sample.file, tags: withCover)
        let boxes = Boxes(data: m4a)

        func text(_ item: String) throws -> String {
            let data = try #require(boxes.find("moov/udta/meta/ilst/\(item)/data"))
            #expect(boxes.u32(data.lowerBound) == 1)
            return String(decoding: boxes.slice((data.lowerBound + 8)..<data.upperBound), as: UTF8.self)
        }
        #expect(try text("©nam") == "Бармалей")
        #expect(try text("©ART") == "Gorilla Glue, Lil Nakur")
        #expect(try text("©alb") == "Сингл")
        #expect(try text("©too") == "Melogold")
        let cover = try #require(boxes.find("moov/udta/meta/ilst/covr/data"))
        #expect(boxes.u32(cover.lowerBound) == 13)
        #expect(boxes.slice((cover.lowerBound + 8)..<cover.upperBound) == jpeg)
    }

    @Test func pngCoverHasItsOwnKindAndUnknownFormatIsSkipped() throws {
        let sample = SampleFile.make(fragments: 1, perFragment: 3)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let m4a = try Mp4Writer.fromFragmented(sample.file, tags: Mp4Tags(title: "A", cover: png))
        let boxes = Boxes(data: m4a)
        let cover = try #require(boxes.find("moov/udta/meta/ilst/covr/data"))
        #expect(boxes.u32(cover.lowerBound) == 14)
        // WebP и прочее в файл не кладётся: плееры такую обложку не читают
        let webp = try Mp4Writer.fromFragmented(sample.file, tags: Mp4Tags(title: "A", cover: Data("RIFFxxxxWEBP".utf8)))
        #expect(Boxes(data: webp).find("moov/udta/meta/ilst/covr") == nil)
        // Пустые теги не пишутся вовсе
        let bare = try Mp4Writer.fromFragmented(sample.file, tags: Mp4Tags(title: "  ", artist: nil, album: ""))
        #expect(Boxes(data: bare).find("moov/udta/meta/ilst/©nam") == nil)
    }

    @Test func avFoundationReadsTheResult() async throws {
        let sample = SampleFile.make(fragments: 3, perFragment: 4)
        var withCover = tags
        withCover.cover = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mp4writer-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try Mp4Writer.fromFragmented(sample.file, tags: withCover).write(to: url)

        let asset = AVURLAsset(url: url)
        // Длительность — сумма кадров (без разгона кодека), а не вдвое больше; AVFoundation у AAC сама подрезает начало
        // по своему разгону, поэтому допуск — один кадр AAC (23 мс) на трек в 0,2 с; удвоение дало бы 0,39 с
        let duration = try await asset.load(.duration).seconds
        let expected = Double(sample.frames.count * 1024 - Int(SampleFile.priming)) / Double(SampleFile.timescale)
        #expect(abs(duration - expected) < 1024.0 / Double(SampleFile.timescale))
        #expect(duration < 0.3)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(tracks.count == 1)
        let track = try #require(tracks.first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
        #expect(asbd.mSampleRate == 44_100)
        #expect(asbd.mChannelsPerFrame == 2)

        let metadata = try await asset.load(.commonMetadata)
        func string(_ identifier: AVMetadataIdentifier) async throws -> String? {
            let items = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier)
            return try await items.first?.load(.stringValue)
        }
        #expect(try await string(.commonIdentifierTitle) == "Бармалей")
        #expect(try await string(.commonIdentifierArtist) == "Gorilla Glue, Lil Nakur")
        #expect(try await string(.commonIdentifierAlbumName) == "Сингл")
        let artwork = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork)
        #expect(try await artwork.first?.load(.dataValue) == Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4]))
    }

    @Test func worksWithoutSegmentIndex() throws {
        let sample = SampleFile.make(fragments: 3, perFragment: 4, withSidx: false)
        let m4a = try Mp4Writer.fromFragmented(sample.file, tags: tags)
        let boxes = Boxes(data: m4a)
        let mdat = try #require(boxes.find("mdat"))
        #expect(boxes.slice(mdat) == sample.frames.reduce(Data()) { $0 + $1 })
    }

    @Test func incompleteStreamIsRejected() throws {
        let sample = SampleFile.make(fragments: 3, perFragment: 4)
        // Оборван на середине последнего фрагмента
        #expect(throws: Mp4Writer.Failure.self) {
            try Mp4Writer.fromFragmented(sample.file.prefix(sample.file.count - 10), tags: tags)
        }
        // Нет целого последнего фрагмента: sidx обещает три
        let segment = try #require(try FragmentedMP4.parseHeader(sample.file)?.1?.segments.last)
        #expect(throws: Mp4Writer.Failure.self) {
            try Mp4Writer.fromFragmented(sample.file.prefix(segment.offset), tags: tags)
        }
        // Одно начало файла
        #expect(throws: (any Error).self) {
            try Mp4Writer.fromFragmented(sample.file.prefix(40), tags: tags)
        }
    }

    @Test func fileVariantWritesTheSameBytes() throws {
        let sample = SampleFile.make(fragments: 3, perFragment: 4)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mp4writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.m4a")
        let target = directory.appendingPathComponent("target.m4a")
        try sample.file.write(to: source)
        try Mp4Writer.write(fragmentedFile: source, to: target, tags: tags)
        #expect(try Data(contentsOf: target) == Mp4Writer.fromFragmented(sample.file, tags: tags))
        // Оборванный источник не оставляет файла
        let broken = directory.appendingPathComponent("broken.m4a")
        try sample.file.prefix(sample.file.count - 10).write(to: broken)
        let brokenTarget = directory.appendingPathComponent("broken-target.m4a")
        #expect(throws: Mp4Writer.Failure.self) { try Mp4Writer.write(fragmentedFile: broken, to: brokenTarget, tags: tags) }
        #expect(!FileManager.default.fileExists(atPath: brokenTarget.path))
    }

    /// Настоящий поток YouTube (файл загрузки или кэша, `MELOGOLD_MP4_SAMPLE=<путь>`) → .m4a рядом; без переменной —
    /// пропуск. Длительность результата у `AVURLAsset` совпадает с суммой отсчётов исходного файла, а не вдвое больше.
    @Test func realStreamFromEnvironment() async throws {
        guard let path = ProcessInfo.processInfo.environment["MELOGOLD_MP4_SAMPLE"], FileManager.default.fileExists(atPath: path) else { return }
        let source = URL(fileURLWithPath: path)
        let target = source.deletingPathExtension().appendingPathExtension("converted.m4a")
        try Mp4Writer.write(fragmentedFile: source, to: target, tags: Mp4Tags(title: "Never Gonna Give You Up", artist: "Rick Astley",
                                                                            album: "Whenever You Need Somebody"))
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        let plan = try Mp4Writer.plan(for: data)
        let expected = Double(plan.totalDuration - UInt64(max(0, plan.initSegment.priming))) / Double(plan.initSegment.timescale)
        let duration = try await AVURLAsset(url: target).load(.duration).seconds
        #expect(abs(duration - expected) < 0.05)
    }
}
