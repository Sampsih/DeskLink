import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import VideoToolbox

private final class VideoEncoder {
    private var session: VTCompressionSession?
    private let free = DispatchSemaphore(value: 1)
    private let wire: Wire

    init(width: Int, height: Int, wire: Wire) throws {
        self.wire = wire
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw DeskError.system("Не удалось запустить кодирование H.264 (\(status)).")
        }
        let properties = [
            kVTCompressionPropertyKey_RealTime as String: true,
            kVTCompressionPropertyKey_AllowFrameReordering as String: false,
            kVTCompressionPropertyKey_ProfileLevel as String: kVTProfileLevel_H264_Baseline_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate as String: 5_000_000,
            kVTCompressionPropertyKey_ExpectedFrameRate as String: 30,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration as String: 2
        ] as CFDictionary
        VTSessionSetProperties(session, propertyDictionary: properties)
        let prepared = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepared == noErr else {
            VTCompressionSessionInvalidate(session)
            self.session = nil
            throw DeskError.system("Кодек H.264 недоступен (\(prepared)).")
        }
    }

    deinit {
        if let session { VTCompressionSessionInvalidate(session) }
    }

    func encode(_ sample: CMSampleBuffer) {
        guard let session, let image = sample.imageBuffer, free.wait(timeout: .now()) == .success else { return }
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: image, presentationTimeStamp: sample.presentationTimeStamp,
            duration: .invalid, frameProperties: nil, infoFlagsOut: nil,
            outputHandler: { [free, wire] status, _, sample in
                guard status == noErr, let sample, let payload = Self.packet(sample) else {
                    free.signal()
                    return
                }
                wire.send(.video, payload) { free.signal() }
            }
        )
        if status != noErr { free.signal() }
    }

    private static func packet(_ sample: CMSampleBuffer) -> Data? {
        guard let block = sample.dataBuffer else { return nil }
        let count = CMBlockBufferGetDataLength(block)
        guard count > 0, count < PacketType.video.limit - 1024 else { return nil }
        var body = Data()
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
        let flags = (attachments as? [[CFString: Any]])?.first
        let isKeyFrame = flags?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        if isKeyFrame, let format = sample.formatDescription {
            for index in 0...1 {
                var bytes: UnsafePointer<UInt8>?
                var size = 0
                let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &bytes, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                )
                guard status == noErr, let bytes, (1...Int(UInt16.max)).contains(size) else { return nil }
                body.append(UInt8(size >> 8))
                body.append(UInt8(size & 255))
                body.append(bytes, count: size)
            }
        } else {
            body.append(contentsOf: [0, 0, 0, 0])
        }
        var frame = Data(count: count)
        let status = frame.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!)
        }
        guard status == noErr else { return nil }
        body.append(frame)
        return body
    }
}

final class ScreenStream: NSObject, SCStreamOutput, SCStreamDelegate {
    private let streamQueue = DispatchQueue(label: "DeskLink.capture", qos: .userInteractive)
    private let wire: Wire
    private let onFailure: (Error) -> Void
    private var stream: SCStream?
    private var encoder: VideoEncoder?
    private var soundEnabled = true
    private var enabled = true

    init(wire: Wire, onFailure: @escaping (Error) -> Void) {
        self.wire = wire
        self.onFailure = onFailure
    }

    func start(display: SCDisplay, audio: Bool) async throws {
        let scale = min(1.0, 1920.0 / Double(max(1, display.width)), 1200.0 / Double(max(1, display.height)))
        let width = max(2, Int(Double(display.width) * scale) / 2 * 2)
        let height = max(2, Int(Double(display.height) * scale) / 2 * 2)
        let settings = SCStreamConfiguration()
        settings.width = width
        settings.height = height
        settings.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        settings.queueDepth = 3
        settings.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        settings.showsCursor = true
        settings.capturesAudio = true
        settings.sampleRate = 48_000
        settings.channelCount = 2
        settings.excludesCurrentProcessAudio = true

        let encoder = try VideoEncoder(width: width, height: height, wire: wire)
        streamQueue.sync {
            self.encoder = encoder
            self.soundEnabled = audio
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: settings, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: streamQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: streamQueue)
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() async {
        streamQueue.sync {
            enabled = false
            encoder = nil
        }
        try? await stream?.stopCapture()
        stream = nil
    }

    func setAudio(_ enabled: Bool) {
        streamQueue.async { self.soundEnabled = enabled }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure(error)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard enabled, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        switch type {
        case .screen:
            let frames = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]]
            if let raw = frames?.first?[.status] as? Int, raw != SCFrameStatus.complete.rawValue { return }
            encoder?.encode(sampleBuffer)
        case .audio:
            if soundEnabled { transmitAudio(sampleBuffer) }
        default:
            break
        }
    }

    private func transmitAudio(_ sample: CMSampleBuffer) {
        guard let info = sample.formatDescription?.audioStreamBasicDescription,
              info.mFormatID == kAudioFormatLinearPCM,
              info.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              info.mBitsPerChannel == 32, info.mSampleRate == 48_000, info.mChannelsPerFrame == 2,
              (1...8192).contains(sample.numSamples) else { return }
        try? sample.withAudioBufferList { list, _ in
            let frameCount = sample.numSamples
            let channelBytes = frameCount * MemoryLayout<Float>.size
            var pcm = Data()
            switch list.count {
            case 1:
                guard let data = list[0].mData, Int(list[0].mDataByteSize) >= channelBytes * 2 else { return }
                let samples = data.assumingMemoryBound(to: Float.self)
                var planar = [Float](repeating: 0, count: frameCount * 2)
                for index in 0..<frameCount {
                    planar[index] = samples[index * 2]
                    planar[frameCount + index] = samples[index * 2 + 1]
                }
                planar.withUnsafeBytes { pcm.append(contentsOf: $0) }
            case 2:
                for buffer in list {
                    guard let data = buffer.mData, Int(buffer.mDataByteSize) >= channelBytes else { return }
                    pcm.append(data.assumingMemoryBound(to: UInt8.self), count: channelBytes)
                }
            default:
                return
            }
            wire.send(.audio, pcm)
        }
    }
}
