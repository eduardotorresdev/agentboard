import CoreMedia
import Foundation
import IOSurface
import QuartzCore
import VideoToolbox

/// Encodes a screen's frames as H.264 for a card stream: real time, no reordering, low-latency
/// rate control. Hands out Annex B access units, the parameter sets in front of each keyframe,
/// so a client can start at any keyframe.
final class VideoEncoder {
    private var session: VTCompressionSession?
    private var width = 0
    private var height = 0
    private var forceKey = true
    private var start: CFTimeInterval?
    /// Called on VideoToolbox's thread with each unit and whether it is a keyframe.
    let output: (Data, Bool) -> Void

    init(output: @escaping (Data, Bool) -> Void) { self.output = output }

    func requestKeyFrame() { forceKey = true }

    // shortcut: the surface is encoded in place while the simulator may already draw the next frame (rare tearing); copy it first if that shows.
    func encode(_ surface: IOSurface) {
        var buffer: Unmanaged<CVPixelBuffer>?
        guard CVPixelBufferCreateWithIOSurface(nil, unsafeBitCast(surface, to: IOSurfaceRef.self), nil, &buffer) == kCVReturnSuccess,
              let pixels = buffer?.takeRetainedValue() else { return }
        encode(pixels)
    }

    /// Makes the session for frames of this size ahead of the first: starting one takes about
    /// 2 s, which a viewer would otherwise wait.
    func prepare(width: Int, height: Int) {
        guard session == nil || width != self.width || height != self.height else { return }
        invalidate()
        session = Self.makeSession(width: width, height: height)
        self.width = width
        self.height = height
        forceKey = true
    }

    /// Whether frames of this size go out without a new session.
    func fits(width: Int, height: Int) -> Bool { session != nil && width == self.width && height == self.height }

    func encode(_ pixels: CVPixelBuffer) {
        prepare(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        guard let session else { return }
        let now = CACurrentMediaTime()
        let time = CMTime(seconds: now - (start ?? now), preferredTimescale: 1_000_000)
        if start == nil { start = now }
        let properties = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceKey = false
        let output = output
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: time, duration: .invalid,
                                        frameProperties: properties, infoFlagsOut: nil) { status, _, sample in
            guard status == noErr, let sample, let unit = Self.annexB(sample) else { return }
            output(unit.data, unit.key)
        }
    }

    func invalidate() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }

    deinit { invalidate() }

    private static func makeSession(width: Int, height: Int) -> VTCompressionSession? {
        let specification = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        var session: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                         encoderSpecification: specification, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr, let session else { return nil }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Main_AutoLevel,
            // A keyframe at least every 4 s, so a client that lost one recovers.
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 4,
            kVTCompressionPropertyKey_AverageBitRate: max(2_000_000, width * height * 4),
        ]
        for (key, value) in properties { VTSessionSetProperty(session, key: key, value: value as CFTypeRef) }
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }

    /// A sample's AVCC NAL units as Annex B, SPS and PPS first on a keyframe.
    static func annexB(_ sample: CMSampleBuffer) -> (data: Data, key: Bool)? {
        guard let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        let start = Data([0, 0, 0, 1])
        var data = Data()
        if key {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                         parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                         nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
                data += start + Data(bytes: pointer, count: size)
            }
        }
        // 4-byte big-endian lengths before each unit.
        var avcc = Data(count: CMBlockBufferGetDataLength(block))
        let copied = avcc.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        guard copied == noErr else { return nil }
        var offset = 0
        while offset + 4 <= avcc.count {
            let size = avcc[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            offset += 4
            guard offset + size <= avcc.count else { return nil }
            data += start + avcc[offset..<offset + size]
            offset += size
        }
        return (data, key)
    }
}
