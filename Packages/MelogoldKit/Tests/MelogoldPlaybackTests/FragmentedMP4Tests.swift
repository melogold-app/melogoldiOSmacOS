import CoreMedia
import Foundation
import Testing
@testable import MelogoldPlayback

/// Синтетический DASH-m4a как у YouTube: `ftyp`, `moov` (mp4a + esds AAC-LC 44,1 кГц стерео, `elst` с разгоном 1600),
/// `sidx`, два фрагмента по три отсчёта. Музыки внутри нет — байты отсчётов условные.
enum SyntheticMP4 {
    static func box(_ type: String, _ payload: Data) -> Data {
        var data = Data()
        data.append(be32(UInt32(8 + payload.count)))
        data.append(Data(type.utf8))
        data.append(payload)
        return data
    }

    static func full(_ type: String, version: UInt8 = 0, flags: UInt32 = 0, _ payload: Data) -> Data {
        var head = Data([version])
        head.append(contentsOf: [UInt8(flags >> 16 & 0xFF), UInt8(flags >> 8 & 0xFF), UInt8(flags & 0xFF)])
        return box(type, head + payload)
    }

    static func be16(_ value: UInt16) -> Data { Data([UInt8(value >> 8), UInt8(value & 0xFF)]) }
    static func be32(_ value: UInt32) -> Data { Data([UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]) }

    static var mp4a: Data {
        var entry = Data(count: 6) + be16(1) // reserved, data_reference_index
        entry += Data(count: 8) + be16(2) + be16(16) + Data(count: 4) + be32(44_100 << 16)
        // esds: ES_Descriptor → DecoderConfigDescriptor(AAC) → DecoderSpecificInfo 0x12 0x10
        let dsi = Data([0x05, 0x02, 0x12, 0x10])
        let dcd = Data([0x04, 0x11, 0x40, 0x15, 0x00, 0x00, 0x00]) + be32(128_000) + be32(128_000) + dsi
        let sl = Data([0x06, 0x01, 0x02])
        let es = Data([0x03, UInt8(3 + dcd.count + sl.count), 0x00, 0x01, 0x00]) + dcd + sl
        entry += full("esds", es)
        return box("mp4a", entry)
    }

    static func make() -> (file: Data, fragmentSizes: [Int]) {
        let ftyp = box("ftyp", Data("dash".utf8) + be32(0) + Data("iso6mp41".utf8))
        let mdhd = full("mdhd", be32(0) + be32(0) + be32(44_100) + be32(6144) + be16(0x55C4) + be16(0))
        let stsd = full("stsd", be32(1) + mp4a)
        let stbl = box("stbl", stsd + full("stts", be32(0)) + full("stsc", be32(0)) + full("stsz", be32(0) + be32(0)) + full("stco", be32(0)))
        let minf = box("minf", full("smhd", be32(0)) + stbl)
        let hdlr = full("hdlr", be32(0) + Data("soun".utf8) + Data(count: 12) + Data([0]))
        let mdia = box("mdia", mdhd + hdlr + minf)
        let tkhd = full("tkhd", flags: 3, be32(0) + be32(0) + be32(1) + be32(0) + be32(6144) + Data(count: 60))
        let elst = full("elst", be32(1) + be32(4544) + be32(1600) + be16(1) + be16(0))
        let trak = box("trak", tkhd + box("edts", elst) + mdia)
        let trex = full("trex", be32(1) + be32(1) + be32(1024) + be32(0) + be32(0))
        let moov = box("moov", full("mvhd", be32(0) + be32(0) + be32(44_100) + be32(6144) + Data(count: 80)) + box("mvex", trex) + trak)

        func fragment(baseTime: UInt32, samples: [Int]) -> Data {
            let tfhd = full("tfhd", flags: 0x02002A, be32(1) + be32(1) + be32(1024) + be32(0))
            let tfdt = full("tfdt", be32(baseTime))
            var trunPayload = be32(UInt32(samples.count)) + be32(0)
            for size in samples { trunPayload += be32(UInt32(size)) }
            var trun = full("trun", flags: 0x201, trunPayload)
            let traf = box("traf", tfhd + tfdt + trun)
            let moofSize = 8 + 16 + traf.count
            // data_offset trun — от начала moof до байтов mdat
            let dataOffset = UInt32(moofSize + 8)
            trun = full("trun", flags: 0x201, be32(UInt32(samples.count)) + be32(dataOffset) + samples.reduce(Data()) { $0 + be32(UInt32($1)) })
            let moof = box("moof", full("mfhd", be32(1)) + box("traf", tfhd + tfdt + trun))
            let mdat = box("mdat", Data(repeating: 0xAB, count: samples.reduce(0, +)))
            return moof + mdat
        }
        let first = fragment(baseTime: 0, samples: [300, 310, 320])
        let second = fragment(baseTime: 3072, samples: [330, 340, 350])
        var sidxPayload = be32(1) + be32(44_100) + be32(0) + be32(0) + be16(0) + be16(2)
        sidxPayload += be32(UInt32(first.count)) + be32(3072) + be32(0x9000_0000)
        sidxPayload += be32(UInt32(second.count)) + be32(3072) + be32(0x9000_0000)
        let sidx = full("sidx", sidxPayload)
        return (ftyp + moov + sidx + first + second, [first.count, second.count])
    }
}

@Suite("Фрагментированный MP4 — свой разбор (docs/PROMPT.md §4)")
struct FragmentedMP4Tests {
    @Test func headerAndIndex() throws {
        let (file, sizes) = SyntheticMP4.make()
        let (initSegment, index, firstFragment) = try #require(try FragmentedMP4.parseHeader(file))
        #expect(initSegment.timescale == 44_100)
        #expect(initSegment.priming == 1600)
        #expect(initSegment.defaultSampleDuration == 1024)
        let segments = try #require(index).segments
        #expect(segments.count == 2)
        #expect(segments[0].offset == firstFragment)
        #expect(segments[0].size == sizes[0])
        #expect(segments[1].startTime == 3072)
        #expect(segments[1].end == file.count)
        #expect(index?.segment(at: 0.05) == 0)
        #expect(index?.segment(at: 0.08) == 1)
    }

    @Test func headerNeedsMoreBytes() throws {
        let (file, _) = SyntheticMP4.make()
        #expect(try FragmentedMP4.parseHeader(file.prefix(40)) == nil)
    }

    @Test func fragmentSamples() throws {
        let (file, sizes) = SyntheticMP4.make()
        let (_, index, _) = try #require(try FragmentedMP4.parseHeader(file))
        let segment = try #require(index?.segments[1])
        let data = file[segment.offset..<segment.end]
        let fragment = try FragmentedMP4.parseFragment(Data(data), moofOffset: segment.offset, defaultDuration: 1024)
        #expect(fragment.baseDecodeTime == 3072)
        #expect(fragment.sizes == [330, 340, 350])
        #expect(fragment.durations == [1024, 1024, 1024])
        #expect(fragment.dataOffset + fragment.sizes.reduce(0, +) == sizes[1])
    }

    @Test func sampleBuffersForRenderer() throws {
        let (file, _) = SyntheticMP4.make()
        let (initSegment, index, _) = try #require(try FragmentedMP4.parseHeader(file))
        let format = try AudioSamples.formatDescription(sampleEntry: initSegment.sampleEntry)
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
        #expect(asbd.mSampleRate == 44_100)
        #expect(asbd.mChannelsPerFrame == 2)
        let segment = try #require(index?.segments[0])
        let data = Data(file[segment.offset..<segment.end])
        let fragment = try FragmentedMP4.parseFragment(data, defaultDuration: 1024)
        let buffers = try AudioSamples.sampleBuffers(fragmentData: data, fragment: fragment, format: format, timescale: 44_100,
                                                     pts: .zero, packetsPerBuffer: 2)
        #expect(buffers.count == 2)
        #expect(CMSampleBufferGetNumSamples(buffers[0]) == 2)
        #expect(CMSampleBufferGetPresentationTimeStamp(buffers[1]).value == 2048)
        // Перемотка внутрь фрагмента: отсчёты до времени не нужны.
        let trimmed = try AudioSamples.sampleBuffers(fragmentData: data, fragment: fragment, format: format, timescale: 44_100,
                                                     pts: .zero, trimBefore: CMTime(value: 2100, timescale: 44_100), packetsPerBuffer: 2)
        #expect(trimmed.count == 1)
    }
}
