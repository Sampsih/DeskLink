import AVFoundation
import CoreMedia
import Foundation

final class VideoPlayback {
    let layer = AVSampleBufferDisplayLayer()
    private var format: CMVideoFormatDescription?
    private var configuration: [Data]?

    init() {
        layer.videoGravity = .resizeAspect
    }

    func clear() {
        format = nil
        configuration = nil
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    func show(_ packet: Data) -> Bool {
        var offset = 0
        var parameterSets: [Data] = []
        for _ in 0..<2 {
            guard offset + 2 <= packet.count else { return false }
            let count = Int(packet[offset]) * 256 + Int(packet[offset + 1])
            offset += 2
            guard offset + count < packet.count else { return false }
            parameterSets.append(packet.subdata(in: offset..<(offset + count)))
            offset += count
        }
        if !parameterSets[0].isEmpty && !parameterSets[1].isEmpty && parameterSets != configuration {
            var newFormat: CMVideoFormatDescription?
            let status = parameterSets[0].withUnsafeBytes { first in
                parameterSets[1].withUnsafeBytes { second in
                    let pointers = [first.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                    second.baseAddress!.assumingMemoryBound(to: UInt8.self)]
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers,
                        parameterSetSizes: parameterSets.map(\.count), nalUnitHeaderLength: 4,
                        formatDescriptionOut: &newFormat
                    )
                }
            }
            guard status == noErr, let newFormat else { return false }
            format = newFormat
            configuration = parameterSets
        }
        guard let format else { return false }
        let size = packet.count - offset
        var memory: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: size,
                                                blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                offsetToData: 0, dataLength: size, flags: 0,
                                                blockBufferOut: &memory) == noErr, let memory else { return false }
        let written = packet.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!.advanced(by: offset),
                                          blockBuffer: memory, offsetIntoDestination: 0, dataLength: size)
        }
        guard written == noErr else { return false }
        var frame: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleSize = size
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: memory, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                        sampleBufferOut: &frame) == noErr, let frame,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(frame, createIfNecessary: true) else {
            return false
        }
        let item = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(item, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        let renderer = layer.sampleBufferRenderer
        if renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            guard !parameterSets[0].isEmpty else { return false }
        }
        renderer.enqueue(frame)
        return true
    }
}

final class AudioPlayback {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private var queued = 0
    private var generation = 0

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func play(_ data: Data) {
        let frameCount = data.count / 8
        guard (1...8192).contains(frameCount), data.count == frameCount * 8, queued < 12,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channel = buffer.floatChannelData else { return }
        if !engine.isRunning {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback)
                try AVAudioSession.sharedInstance().setActive(true)
                try engine.start()
                player.play()
            } catch {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                return
            }
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let bytes = frameCount * 4
        data.withUnsafeBytes {
            if let source = $0.baseAddress {
                memcpy(channel[0], source, bytes)
                memcpy(channel[1], source.advanced(by: bytes), bytes)
            }
        }
        queued += 1
        let current = generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.queued -= 1
            }
        }
    }

    func stop() {
        generation += 1
        queued = 0
        guard engine.isRunning else { return }
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
