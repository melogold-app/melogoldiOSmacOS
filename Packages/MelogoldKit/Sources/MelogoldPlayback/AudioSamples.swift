import AVFoundation
import CoreMedia
import Foundation

/// Сжатые отсчёты AAC для `AVSampleBufferAudioRenderer`: формат — из записи `stsd` (вместе с `esds`), буферы —
/// группы отсчётов с описаниями пакетов. Декодирует сам рендерер.
public enum AudioSamples {
    public struct FormatError: Error {}

    /// Описание формата из записи `mp4a` (ISO SoundDescription).
    public static func formatDescription(sampleEntry: Data) throws -> CMAudioFormatDescription {
        var description: CMAudioFormatDescription?
        let status = sampleEntry.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return CMAudioFormatDescriptionCreateFromBigEndianSoundDescriptionData(
                allocator: nil, bigEndianSoundDescriptionData: base, size: sampleEntry.count, flavor: .isoFamily,
                formatDescriptionOut: &description
            )
        }
        guard status == noErr, let description else { throw FormatError() }
        return description
    }

    /// Буферы по ~1 с (`packetsPerBuffer` пакетов) из байтов фрагмента. `pts` — время первого отсчёта на шкале
    /// синхронизатора; отсчёты раньше `trimBefore` (перемотка внутрь фрагмента) не попадают.
    public static func sampleBuffers(
        fragmentData: Data, fragment: FragmentedMP4.Fragment, format: CMAudioFormatDescription, timescale: UInt32,
        pts: CMTime, trimBefore: CMTime? = nil, packetsPerBuffer: Int = 43
    ) throws -> [CMSampleBuffer] {
        var buffers: [CMSampleBuffer] = []
        var index = 0
        var byteOffset = fragment.dataOffset
        var time = pts
        let scale = CMTimeScale(timescale)
        while index < fragment.sizes.count {
            let end = min(index + packetsPerBuffer, fragment.sizes.count)
            let sizes = fragment.sizes[index..<end]
            let total = sizes.reduce(0, +)
            let durationTicks = fragment.durations[index..<end].reduce(Int64(0)) { $0 + Int64($1) }
            let duration = CMTime(value: durationTicks, timescale: scale)
            defer {
                byteOffset += total
                time = CMTimeAdd(time, duration)
                index = end
            }
            if let trimBefore, CMTimeCompare(CMTimeAdd(time, duration), trimBefore) <= 0 { continue }
            guard byteOffset + total <= fragmentData.count else { throw FragmentedMP4.ParseError(message: "mdat короче, чем trun") }

            var packets: [AudioStreamPacketDescription] = []
            packets.reserveCapacity(sizes.count)
            var offset: Int64 = 0
            for size in sizes {
                packets.append(AudioStreamPacketDescription(mStartOffset: offset, mVariableFramesInPacket: 0, mDataByteSize: UInt32(size)))
                offset += Int64(size)
            }
            var block: CMBlockBuffer?
            var status = CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: total, blockAllocator: nil, customBlockSource: nil,
                offsetToData: 0, dataLength: total, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
            )
            guard status == kCMBlockBufferNoErr, let block else { throw FormatError() }
            let start = fragmentData.startIndex + byteOffset
            status = fragmentData[start..<(start + total)].withUnsafeBytes { raw in
                CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: total)
            }
            guard status == kCMBlockBufferNoErr else { throw FormatError() }
            var sample: CMSampleBuffer?
            status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: sizes.count,
                presentationTimeStamp: time, packetDescriptions: packets, sampleBufferOut: &sample
            )
            guard status == noErr, let sample else { throw FormatError() }
            buffers.append(sample)
        }
        return buffers
    }
}
