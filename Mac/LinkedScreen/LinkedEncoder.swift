import VideoToolbox
import Foundation

/// One AVCC access unit per packet. SPS/PPS travel with the frame so the receiver can initialize immediately.
final class LinkedEncoder {
    static let desktopBitRate = 3_000_000
    private var encoder: VTCompressionSession?
    init?(width: Int, height: Int) {
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &encoder) == noErr,
              let encoder else { return nil }
        VTSessionSetProperties(encoder, propertyDictionary: [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_AverageBitRate: Self.desktopBitRate,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 30,
            kVTCompressionPropertyKey_ExpectedFrameRate: 30
        ] as CFDictionary)
    }

    func setBitRate(_ bitRate: Int) -> Bool {
        guard let encoder else { return false }
        return VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate,
                                    value: NSNumber(value: bitRate)) == noErr
    }

    func setExpectedFrameRate(_ fps: Int) {
        guard let encoder else { return }
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
    }

    deinit { if let encoder { VTCompressionSessionInvalidate(encoder) } }

    func encode(_ sample: CMSampleBuffer, keyFrame: Bool = false, completion: @escaping (Data?) -> Void) {
        guard let encoder, let image = sample.imageBuffer else { completion(nil); return }
        let frameProperties = keyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(encoder, imageBuffer: image,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), duration: .invalid,
            frameProperties: frameProperties, infoFlagsOut: nil) { error, _, encoded in
                let packet = error == noErr ? encoded.flatMap(Self.packet) : nil
                DispatchQueue.main.async { completion(packet) }
            }
        if status != noErr { completion(nil) }
    }

    private static func packet(_ sample: CMSampleBuffer) -> Data? {
        guard let format = sample.formatDescription, let block = sample.dataBuffer else { return nil }
        var data = Data()
        for index in 0..<2 {
            var bytes: UnsafePointer<UInt8>?
            var count = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                parameterSetPointerOut: &bytes, parameterSetSizeOut: &count, parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil) == noErr, let bytes, (1...65535).contains(count) else { return nil }
            data.appendInteger(UInt16(count))
            data.append(bytes, count: count)
        }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0, data.count + length < 4 * 1024 * 1024 else { return nil }
        var body = Data(count: length)
        let result = body.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
        }
        guard result == noErr else { return nil }
        data.append(body)
        return data
    }
}
