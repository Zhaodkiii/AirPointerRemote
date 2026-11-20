import CryptoKit
import Network
import VideoToolbox
import Foundation

/// Loopback exercise using the same TLS, framing and H.264 path as a physical pairing.
@main struct LinkedScreenChecks {
    private static func verifyAdaptiveQuality() {
        var quality = LinkedVideoQuality()
        precondition(quality.evaluate(now: 1, oldestAge: 0.36, windowFull: true) == 1)
        quality.applied(1, at: 1)
        precondition(quality.evaluate(now: 2, oldestAge: 0.6, windowFull: true) == nil)
        precondition(quality.evaluate(now: 3, oldestAge: 0.6, windowFull: true) == 2)
        quality.applied(2, at: 3)
        precondition(quality.evaluate(now: 6, oldestAge: 0.6, windowFull: true) == nil)
        precondition(quality.evaluate(now: 7, oldestAge: 0.6, windowFull: true) == 3)
        quality.applied(3, at: 7)
        precondition(quality.profile.fps == 20)
        precondition(quality.evaluate(now: 25, oldestAge: 0, windowFull: false) == nil)
        for second in 26...36 {
            for _ in 0..<10 { quality.record(now: Double(second), delay: 0.045) }
            let upgrade = quality.evaluate(now: Double(second), oldestAge: 0, windowFull: false)
            precondition(upgrade == (second == 36 ? 2 : nil))
        }
    }

    static func main() throws {
        verifyAdaptiveQuality()
        let offer = LinkedOffer(key: SymmetricKey(size: .bits256), first: 1, second: 2)
        try verifyWrongKeyIsRefused(offer)
        let listener = try NWListener(using: offer.parameters)
        var server: LinkedChannel?
        var client: LinkedChannel?
        var passed = false
        let encoder = LinkedEncoder(width: 320, height: 180)!
        let decoder = LinkedDecoder()
        var firstSample: CMSampleBuffer?
        var framesDecoded = 0
        precondition(decoder.sample(from: Data([1, 0])) == nil)
        listener.newConnectionHandler = { conn in
            server = LinkedChannel(conn)
            server?.onMessage = { message in
                if message.kind == .frameAck {
                    if framesDecoded == 1, let firstSample {
                        encoder.encode(firstSample, keyFrame: true) { packet in
                            precondition(packet != nil)
                            server?.send(packet!, frame: true)
                        }
                    } else {
                        passed = framesDecoded == 2
                    }
                    return
                }
                precondition(message.kind == .insert && message.text == "中文 🖱️")
                precondition(message.styles?.first?.style == 3 && message.selection != nil)
                var pixels: CVPixelBuffer?
                precondition(CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA,
                    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels) == 0)
                var format: CMVideoFormatDescription?
                CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels!, formatDescriptionOut: &format)
                var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
                var sample: CMSampleBuffer?
                CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels!, formatDescription: format!,
                    sampleTiming: &timing, sampleBufferOut: &sample)
                firstSample = sample
                encoder.encode(sample!) { packet in
                    precondition(packet != nil)
                    server?.send(packet!, frame: true)
                }
            }
            server?.start()
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                let conn = NWConnection(host: "127.0.0.1", port: listener.port!, using: offer.parameters)
                client = LinkedChannel(conn)
                client?.onReady = {
                    var edit = LinkedMessage(.insert, text: "中文 🖱️")
                    edit.styles = [.init(start: 0, count: 2, style: 3)]
                    edit.selection = UUID()
                    client?.send(edit)
                }
                client?.onFrame = { bytes in
                    let resumed = framesDecoded == 1
                    let output = (resumed ? LinkedDecoder() : decoder).sample(from: bytes)
                    precondition(output?.formatDescription?.dimensions.width == 320)
                    var decoded: VTDecompressionSession?
                    precondition(VTDecompressionSessionCreate(allocator: nil, formatDescription: output!.formatDescription!,
                        decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: nil,
                        decompressionSessionOut: &decoded) == noErr)
                    let status = VTDecompressionSessionDecodeFrame(decoded!, sampleBuffer: output!, flags: [],
                        infoFlagsOut: nil) { error, _, buffer, _, _ in
                        precondition(error == noErr && buffer != nil)
                        DispatchQueue.main.async {
                            framesDecoded += 1
                            client?.send(.init(.frameAck))
                        }
                    }
                    precondition(status == noErr)
                    VTDecompressionSessionWaitForAsynchronousFrames(decoded!)
                }
                client?.start()
            }
        }
        listener.start(queue: .main)
        let deadline = Date().addingTimeInterval(12)
        while !passed && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        precondition(passed, "No authenticated frame round trip")
        listener.cancel(); server?.close(); client?.close()
        print("Passed: wrong PSK rejected, TLS-PSK localhost, Unicode control, H.264 encode/transport/decode, fresh decoder after resume, frame acknowledgement.")
    }
    private static func verifyWrongKeyIsRefused(_ offer: LinkedOffer) throws {
        let server = try NWListener(using: offer.parameters)
        let wrong = LinkedOffer(key: SymmetricKey(size: .bits256), first: 1, second: 2)
        var peers: [NWConnection] = []
        var rejected = false
        server.newConnectionHandler = { connection in
            peers.append(connection)
            connection.stateUpdateHandler = { state in
                if case .failed(.tls) = state { rejected = true }
                if case .ready = state { preconditionFailure("Server accepted incorrect credentials") }
            }
            connection.start(queue: .main)
        }
        server.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            let client = NWConnection(host: "127.0.0.1", port: server.port!, using: wrong.parameters)
            peers.append(client)
            client.stateUpdateHandler = { state in
                if case .waiting(.tls) = state { rejected = true }
                if case .ready = state { preconditionFailure("Client authenticated with incorrect credentials") }
                if case .failed(.tls) = state { rejected = true }
            }
            client.start(queue: .main)
        }
        server.start(queue: .main)
        let deadline = Date().addingTimeInterval(8)
        while !rejected && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        for peer in peers { peer.cancel() }
        server.cancel()
        precondition(rejected, "The handshake did not reject incorrect credentials")
    }

}
