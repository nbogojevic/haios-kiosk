//
//  DeviceInfoSnapshot.swift
//  experiment-camera
//
//  Split from CameraCaptureNetworking.swift.
//

import Foundation
import UIKit

struct DeviceInfoSnapshot: Encodable {
    struct BatteryInfo: Encodable {
        let state: String
        let percentageFull: Int?
        let isCharging: Bool
    }

    struct CameraInfo: Encodable {
        struct RetentionInfo: Encodable {
            let mode: String
            let maxRetainedImages: Int
            let maxRetainedImageStorageMB: Int
        }

        let isFilming: Bool
        let wantsToRun: Bool
        let status: String
        let captureIntervalSeconds: Int
        let captureCount: Int
        let lastCaptureAt: String?
        let hasCapturedImageSinceStart: Bool
        let errorMessage: String?
        let retention: RetentionInfo?

        init(
            isFilming: Bool,
            wantsToRun: Bool,
            status: String,
            captureIntervalSeconds: Int,
            captureCount: Int,
            lastCaptureAt: String?,
            hasCapturedImageSinceStart: Bool,
            errorMessage: String?,
            retention: RetentionInfo? = nil
        ) {
            self.isFilming = isFilming
            self.wantsToRun = wantsToRun
            self.status = status
            self.captureIntervalSeconds = captureIntervalSeconds
            self.captureCount = captureCount
            self.lastCaptureAt = lastCaptureAt
            self.hasCapturedImageSinceStart = hasCapturedImageSinceStart
            self.errorMessage = errorMessage
            self.retention = retention
        }
    }

    let deviceName: String
    let ipAddress: String
    let battery: BatteryInfo
    let camera: CameraInfo

    static let unavailable = DeviceInfoSnapshot(
        deviceName: UIDevice.current.name,
        ipAddress: "Unavailable",
        battery: .init(
            state: UIDevice.BatteryState.unknown.description,
            percentageFull: nil,
            isCharging: false
        ),
        camera: .init(
            isFilming: false,
            wantsToRun: false,
            status: "unavailable",
            captureIntervalSeconds: 0,
            captureCount: 0,
            lastCaptureAt: nil,
            hasCapturedImageSinceStart: false,
                errorMessage: "Camera status is unavailable.",
                retention: nil
        )
    )

    func responseBody() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)) ?? Data("{\"error\":\"Unable to encode device info.\"}".utf8)
    }

    func withCameraStatus(_ status: String) -> DeviceInfoSnapshot {
        DeviceInfoSnapshot(
            deviceName: deviceName,
            ipAddress: ipAddress,
            battery: battery,
            camera: .init(
                isFilming: camera.isFilming,
                wantsToRun: camera.wantsToRun,
                status: status,
                captureIntervalSeconds: camera.captureIntervalSeconds,
                captureCount: camera.captureCount,
                lastCaptureAt: camera.lastCaptureAt,
                hasCapturedImageSinceStart: camera.hasCapturedImageSinceStart,
                errorMessage: camera.errorMessage,
                retention: camera.retention
            )
        )
    }
}

enum MJPEGStreamState: Equatable {
    case cameraOff
    case waitingForFirstImage
    case live

    init(cameraInfo: DeviceInfoSnapshot.CameraInfo) {
        guard cameraInfo.isFilming else {
            self = .cameraOff
            return
        }

        self = cameraInfo.hasCapturedImageSinceStart ? .live : .waitingForFirstImage
    }

    var cameraStatus: String {
        switch self {
        case .cameraOff:
            "streaming_camera_off"
        case .waitingForFirstImage:
            "streaming_waiting_for_first_image"
        case .live:
            "streaming_live"
        }
    }
}

extension UIDevice.BatteryState {
    var description: String {
        switch self {
        case .unknown:
            return "unknown"
        case .unplugged:
            return "unplugged"
        case .charging:
            return "charging"
        case .full:
            return "full"
        @unknown default:
            return "unknown"
        }
    }
}
