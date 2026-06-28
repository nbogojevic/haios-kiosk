//
//  H264VideoEncoder.swift
//  experiment-camera
//
//  Split from RTSPServer.swift.
//

import Foundation
@preconcurrency import AVFoundation
import VideoToolbox

struct H264ParameterSets {
    let sps: Data
    let pps: Data

    nonisolated var fmtpAttributeSuffix: String {
        guard sps.count >= 4 else {
            return ""
        }

        let profileLevelID = String(format: "%02X%02X%02X", sps[1], sps[2], sps[3])
        let spsBase64 = sps.base64EncodedString()
        let ppsBase64 = pps.base64EncodedString()
        return ";profile-level-id=\(profileLevelID);sprop-parameter-sets=\(spsBase64),\(ppsBase64)"
    }
}

struct EncodedH264AccessUnit {
    let presentationTimeStamp: CMTime
    let nalUnits: [Data]
    let isKeyframe: Bool
    let parameterSets: H264ParameterSets?
}

struct UnsafeSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer
}

final class H264VideoEncoder {
    private let encodingQueue = DispatchQueue(label: "CameraCaptureService.RTSPServer.H264Encoder")
    nonisolated(unsafe) private var compressionSession: VTCompressionSession?
    nonisolated(unsafe) private let onAccessUnit: (EncodedH264AccessUnit) -> Void

    init(onAccessUnit: @escaping (EncodedH264AccessUnit) -> Void) {
        self.onAccessUnit = onAccessUnit
    }

    nonisolated func encode(_ sampleBuffer: CMSampleBuffer) {
        let wrappedSampleBuffer = UnsafeSampleBuffer(value: sampleBuffer)
        encodingQueue.async { [weak self] in
            self?.encodeOnQueue(wrappedSampleBuffer.value)
        }
    }

    nonisolated func reset() {
        encodingQueue.async { [weak self] in
            guard let self else {
                return
            }

            if let compressionSession = self.compressionSession {
                VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(compressionSession)
            }
            self.compressionSession = nil
        }
    }

    private func encodeOnQueue(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let width = Int32(CVPixelBufferGetWidth(imageBuffer))
        let height = Int32(CVPixelBufferGetHeight(imageBuffer))

        if compressionSession == nil {
            guard let session = makeCompressionSession(width: width, height: height) else {
                return
            }
            compressionSession = session
        }

        guard let compressionSession else {
            return
        }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: imageBuffer,
            presentationTimeStamp: timestamp,
            duration: duration,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    private func makeCompressionSession(width: Int32, height: Int32) -> VTCompressionSession? {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: Self.compressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let session else {
            return nil
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 30 as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }

    private func handleEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return
        }

        let isKeyframe = Self.isKeyframe(sampleBuffer)
        let parameterSets = Self.parameterSets(from: sampleBuffer)
        let nalUnits = Self.nalUnits(from: dataBuffer)
        guard !nalUnits.isEmpty else {
            return
        }

        let accessUnit = EncodedH264AccessUnit(
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            nalUnits: nalUnits,
            isKeyframe: isKeyframe,
            parameterSets: parameterSets
        )
        onAccessUnit(accessUnit)
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let firstAttachment = attachments.first else {
            return false
        }

        let isNonSync = firstAttachment[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        return !isNonSync
    }

    private static func parameterSets(from sampleBuffer: CMSampleBuffer) -> H264ParameterSets? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }

        var spsPointer: UnsafePointer<UInt8>?
        var spsSize = 0
        var ppsPointer: UnsafePointer<UInt8>?
        var ppsSize = 0
        var parameterSetCount = 0

        let spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: nil
        )
        let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer,
            parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: nil
        )

        guard spsStatus == noErr,
              ppsStatus == noErr,
              let spsPointer,
              let ppsPointer,
              spsSize > 0,
              ppsSize > 0 else {
            return nil
        }

        return H264ParameterSets(
            sps: Data(bytes: spsPointer, count: spsSize),
            pps: Data(bytes: ppsPointer, count: ppsSize)
        )
    }

    private static func nalUnits(from dataBuffer: CMBlockBuffer) -> [Data] {
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        guard status == kCMBlockBufferNoErr,
              let dataPointer,
              totalLength > 4 else {
            return []
        }

        var nalUnits: [Data] = []
        var cursor = 0
        let basePointer = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: UInt8.self)

        while cursor + 4 <= totalLength {
            let lengthSlice = Data(bytes: basePointer.advanced(by: cursor), count: 4)
            let nalLength = Int(lengthSlice.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            cursor += 4

            guard nalLength > 0, cursor + nalLength <= totalLength else {
                break
            }

            let nalData = Data(bytes: basePointer.advanced(by: cursor), count: nalLength)
            nalUnits.append(nalData)
            cursor += nalLength
        }

        return nalUnits
    }

    private static let compressionOutputCallback: VTCompressionOutputCallback = { refCon, _, status, _, sampleBuffer in
        guard status == noErr,
              let refCon,
              let sampleBuffer else {
            return
        }

        let encoder = Unmanaged<H264VideoEncoder>.fromOpaque(refCon).takeUnretainedValue()
        encoder.handleEncodedSampleBuffer(sampleBuffer)
    }
}
