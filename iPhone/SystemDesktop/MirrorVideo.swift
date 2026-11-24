import AVFoundation
import ImageIO

/// Converts completed mirror paints into live, display-immediately samples for AVKit.
@MainActor
final class MirrorVideo {
    let layer = AVSampleBufferDisplayLayer()
    private(set) var lastFrame: CVPixelBuffer?
    var paused = false

    func receive(_ jpeg: Data) {
        let renderer = layer.sampleBufferRenderer
        if renderer.requiresFlushToResumeDecoding || renderer.status == .failed { renderer.flush() }
        guard !paused, renderer.isReadyForMoreMediaData,
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        var pixels: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary] as CFDictionary
        guard CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, attributes, &pixels) == kCVReturnSuccess,
              let pixels else { return }
        CVPixelBufferLockBaseAddress(pixels, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: image.width, height: image.height,
                                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        guard context != nil else { return }
        var format: CMVideoFormatDescription?
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &format) == noErr,
              let format, CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels, formatDescription: format,
                sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        lastFrame = pixels
        renderer.enqueue(sample)
    }

    func reset() {
        paused = false
        lastFrame = nil
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true)
    }
}
