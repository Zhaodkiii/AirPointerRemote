import Foundation
import CoreMedia

/// Reconstructs the H.264 sample for the system video renderer.
final class LinkedDecoder {
    private var lastSPS = Data()
    private var lastPPS = Data()
    private var format: CMVideoFormatDescription?

    func sample(from packet: Data) -> CMSampleBuffer? {
        var offset = 0
        func parameter() -> Data? {
            guard offset + 2 <= packet.count else { return nil }
            let count = Int(packet.integer(at: offset, as: UInt16.self))
            offset += 2
            guard count > 0, offset + count < packet.count else { return nil }
            defer { offset += count }
            return packet.subdata(in: offset..<offset + count)
        }
        guard let sps = parameter(), let pps = parameter() else { return nil }
        if sps != lastSPS || pps != lastPPS {
            var updated: CMVideoFormatDescription?
            let result = sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2,
                    parameterSetPointers: [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!],
                    parameterSetSizes: [s.count, p.count], nalUnitHeaderLength: 4, formatDescriptionOut: &updated)
            } }
            guard result == noErr else { return nil }
            format = updated; lastSPS = sps; lastPPS = pps
        }
        var block: CMBlockBuffer?
        var length = packet.count - offset
        guard let format, length > 4,
              CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length,
                blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0,
                blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = packet.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!.advanced(by: offset), blockBuffer: block,
                offsetIntoDestination: 0, dataLength: length)
        }
        var sample: CMSampleBuffer?
        var time = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        guard copied == noErr, CMSampleBufferCreateReady(allocator: nil, dataBuffer: block,
            formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &time,
            sampleSizeEntryCount: 1, sampleSizeArray: &length, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let list = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(list, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
