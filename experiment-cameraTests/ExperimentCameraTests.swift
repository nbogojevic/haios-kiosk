//
//  ExperimentCameraTests.swift
//  experiment-cameraTests
//
//  Created by Nenad BOGOJEVIC on 19/06/2026.
//

import Foundation
import Testing
import UIKit
import Network
@testable import experiment_camera

struct ExperimentCameraTests {
    @Test func pruneCapturedImagesKeepsNewestTenJPEGs() throws {
        let defaults = UserDefaults.standard
        let previousMode = defaults.string(forKey: CaptureRetentionPolicy.modeStorageKey)
        defaults.set(CaptureRetentionPolicy.Mode.count.rawValue, forKey: CaptureRetentionPolicy.modeStorageKey)
        defer {
            if let previousMode {
                defaults.set(previousMode, forKey: CaptureRetentionPolicy.modeStorageKey)
            } else {
                defaults.removeObject(forKey: CaptureRetentionPolicy.modeStorageKey)
            }
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let baseDate = Date(timeIntervalSinceReferenceDate: 10_000)

        for index in 0..<12 {
            let fileURL = temporaryDirectory.appendingPathComponent("frame-\(index).jpg")
            try Data("image-\(index)".utf8).write(to: fileURL)
            try FileManager.default.setAttributes(
                [.modificationDate: baseDate.addingTimeInterval(TimeInterval(index))],
                ofItemAtPath: fileURL.path
            )
        }

        let noteURL = temporaryDirectory.appendingPathComponent("ignore.txt")
        try Data("note".utf8).write(to: noteURL)

        let removedFiles = try CaptureRetentionPolicy.pruneCapturedImages(in: temporaryDirectory)
        let remainingFileNames = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path).sorted()

        #expect(removedFiles.count == 2)
        #expect(removedFiles.map(\.lastPathComponent).sorted() == ["frame-0.jpg", "frame-1.jpg"])
        #expect(remainingFileNames.count == 11)
        #expect(remainingFileNames.contains("ignore.txt"))
        #expect(!remainingFileNames.contains("frame-0.jpg"))
        #expect(!remainingFileNames.contains("frame-1.jpg"))
        #expect(remainingFileNames.contains("frame-11.jpg"))
    }

    @Test func pruneCapturedImagesReturnsEmptyWhenDirectoryDoesNotExist() throws {
        let defaults = UserDefaults.standard
        let previousMode = defaults.string(forKey: CaptureRetentionPolicy.modeStorageKey)
        defaults.set(CaptureRetentionPolicy.Mode.count.rawValue, forKey: CaptureRetentionPolicy.modeStorageKey)
        defer {
            if let previousMode {
                defaults.set(previousMode, forKey: CaptureRetentionPolicy.modeStorageKey)
            } else {
                defaults.removeObject(forKey: CaptureRetentionPolicy.modeStorageKey)
            }
        }

        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let removedFiles = try CaptureRetentionPolicy.pruneCapturedImages(in: missingDirectory)

        #expect(removedFiles.isEmpty)
    }

    @Test func pruneCapturedImagesTieredKeepsEverySixtiethFromOldestTier() throws {
        let defaults = UserDefaults.standard
        let previousMode = defaults.string(forKey: CaptureRetentionPolicy.modeStorageKey)
        let previousStorageMB = defaults.object(forKey: CaptureRetentionPolicy.maxStorageMBStorageKey) as? Int
        defaults.set(CaptureRetentionPolicy.Mode.tieredAndSize.rawValue, forKey: CaptureRetentionPolicy.modeStorageKey)
        defaults.set(5_000, forKey: CaptureRetentionPolicy.maxStorageMBStorageKey)
        defer {
            if let previousMode {
                defaults.set(previousMode, forKey: CaptureRetentionPolicy.modeStorageKey)
            } else {
                defaults.removeObject(forKey: CaptureRetentionPolicy.modeStorageKey)
            }

            if let previousStorageMB {
                defaults.set(previousStorageMB, forKey: CaptureRetentionPolicy.maxStorageMBStorageKey)
            } else {
                defaults.removeObject(forKey: CaptureRetentionPolicy.maxStorageMBStorageKey)
            }
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let baseDate = Date().addingTimeInterval(-40 * 24 * 60 * 60)

        for index in 0..<120 {
            let fileURL = temporaryDirectory.appendingPathComponent("frame-\(index).jpg")
            try Data("image-\(index)".utf8).write(to: fileURL)
            try FileManager.default.setAttributes(
                [.modificationDate: baseDate.addingTimeInterval(TimeInterval(index))],
                ofItemAtPath: fileURL.path
            )
        }

        _ = try CaptureRetentionPolicy.pruneCapturedImages(in: temporaryDirectory)
        let remainingFileNames = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path).sorted()

        #expect(remainingFileNames == ["frame-0.jpg", "frame-60.jpg"])
    }

    @Test func pruneCapturedImagesTieredRemovesOldestWhenStorageLimitIsExceeded() throws {
        let defaults = UserDefaults.standard
        let previousMode = defaults.string(forKey: CaptureRetentionPolicy.modeStorageKey)
        let previousStorageMB = defaults.object(forKey: CaptureRetentionPolicy.maxStorageMBStorageKey) as? Int
        defaults.set(CaptureRetentionPolicy.Mode.tieredAndSize.rawValue, forKey: CaptureRetentionPolicy.modeStorageKey)
        defaults.set(1, forKey: CaptureRetentionPolicy.maxStorageMBStorageKey)
        defer {
            if let previousMode {
                defaults.set(previousMode, forKey: CaptureRetentionPolicy.modeStorageKey)
            } else {
                defaults.removeObject(forKey: CaptureRetentionPolicy.modeStorageKey)
            }

            if let previousStorageMB {
                defaults.set(previousStorageMB, forKey: CaptureRetentionPolicy.maxStorageMBStorageKey)
            } else {
                defaults.removeObject(forKey: CaptureRetentionPolicy.maxStorageMBStorageKey)
            }
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let baseDate = Date().addingTimeInterval(-2 * 60 * 60)
        let payload = Data(repeating: 1, count: 700_000)

        for index in 0..<3 {
            let fileURL = temporaryDirectory.appendingPathComponent("frame-\(index).jpg")
            try payload.write(to: fileURL)
            try FileManager.default.setAttributes(
                [.modificationDate: baseDate.addingTimeInterval(TimeInterval(index))],
                ofItemAtPath: fileURL.path
            )
        }

        _ = try CaptureRetentionPolicy.pruneCapturedImages(in: temporaryDirectory)
        let remainingFileNames = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path).sorted()

        #expect(remainingFileNames.count == 1)
        #expect(remainingFileNames == ["frame-2.jpg"])
    }

    @Test func mjpegStreamStateWaitsForCurrentSessionFirstImage() {
        let waitingCameraInfo = DeviceInfoSnapshot.CameraInfo(
            isFilming: true,
            wantsToRun: true,
            status: "not_streaming",
            captureIntervalSeconds: 1,
            captureCount: 4,
            lastCaptureAt: "2026-06-20T08:30:00Z",
            hasCapturedImageSinceStart: false,
            errorMessage: nil
        )
        let liveCameraInfo = DeviceInfoSnapshot.CameraInfo(
            isFilming: true,
            wantsToRun: true,
            status: "not_streaming",
            captureIntervalSeconds: 1,
            captureCount: 5,
            lastCaptureAt: "2026-06-20T08:30:10Z",
            hasCapturedImageSinceStart: true,
            errorMessage: nil
        )
        let cameraOffInfo = DeviceInfoSnapshot.CameraInfo(
            isFilming: false,
            wantsToRun: false,
            status: "not_streaming",
            captureIntervalSeconds: 1,
            captureCount: 5,
            lastCaptureAt: "2026-06-20T08:30:10Z",
            hasCapturedImageSinceStart: true,
            errorMessage: nil
        )

        #expect(MJPEGStreamState(cameraInfo: waitingCameraInfo) == .waitingForFirstImage)
        #expect(MJPEGStreamState(cameraInfo: waitingCameraInfo).cameraStatus == "streaming_waiting_for_first_image")
        #expect(MJPEGStreamState(cameraInfo: liveCameraInfo) == .live)
        #expect(MJPEGStreamState(cameraInfo: liveCameraInfo).cameraStatus == "streaming_live")
        #expect(MJPEGStreamState(cameraInfo: cameraOffInfo) == .cameraOff)
        #expect(MJPEGStreamState(cameraInfo: cameraOffInfo).cameraStatus == "streaming_camera_off")
    }

    @Test func rtspRequestParsesAbsoluteStreamURLAndCSeq() {
        let payload = Data(
            """
            OPTIONS rtsp://192.168.1.5:2113/stream RTSP/1.0\r
            CSeq: 7\r
            User-Agent: VLC\r
            \r
            """.utf8
        )

        let connection = NWConnection(
            to: .hostPort(host: "127.0.0.1", port: 2113),
            using: .tcp
        )
        let request = RTSPRequest.parse(from: payload, error: nil, connection: connection)

        #expect(request?.method == "OPTIONS")
        #expect(request?.path == "/stream")
        #expect(request?.version == "RTSP/1.0")
        #expect(request?.cSeq == "7")
        #expect(request?.headers["user-agent"] == "VLC")
    }

    @Test func rtspSdpDescriptionIncludesCurrentVideoLinesAndStreamURL() {
        let streamURL = "rtsp://192.168.1.5:2113/stream"
        let sdp = RTSPServer.sdpDescription(appName: "experiment-camera", streamURL: streamURL)

        #expect(sdp.contains("m=video 0 RTP/AVP 96"))
        #expect(sdp.contains("a=rtpmap:96 H264/90000"))
        #expect(sdp.contains("a=fmtp:96 packetization-mode=1"))
        #expect(sdp.contains("a=control:trackID=0"))
        #expect(sdp.contains("a=x-stream-url:\(streamURL)"))
    }

    @Test func deviceCameraOrientationMapsAllFourMainDeviceOrientations() {
        #expect(DeviceCameraOrientation(deviceOrientation: .portrait) == .portrait)
        #expect(DeviceCameraOrientation(deviceOrientation: .portraitUpsideDown) == .portraitUpsideDown)
        #expect(DeviceCameraOrientation(deviceOrientation: .landscapeLeft) == .landscapeLeft)
        #expect(DeviceCameraOrientation(deviceOrientation: .landscapeRight) == .landscapeRight)
        #expect(DeviceCameraOrientation(deviceOrientation: .faceUp) == nil)
        #expect(DeviceCameraOrientation(deviceOrientation: .faceDown) == nil)
    }

    @Test func deviceCameraOrientationProvidesExpectedRotationAngles() {
        #expect(DeviceCameraOrientation.portrait.videoRotationAngle == 90)
        #expect(DeviceCameraOrientation.landscapeLeft.videoRotationAngle == 180)
        #expect(DeviceCameraOrientation.landscapeRight.videoRotationAngle == 0)
        #expect(DeviceCameraOrientation.portraitUpsideDown.videoRotationAngle == 270)
    }

    @Test func resolvedImageURLSupportsFileURLStrings() throws {
        let capturesDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: capturesDirectory, withIntermediateDirectories: true)

        let fileURL = capturesDirectory.appendingPathComponent("legacy-file-url-\(UUID().uuidString).jpg")
        try Data("image".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let item = Item(timestamp: Date(), imagePath: fileURL.absoluteString)

        #expect(item.resolvedImageURL?.path == fileURL.path)
    }

    @Test func resolvedImageURLFallsBackToCapturesFileNameForStaleSandboxPaths() throws {
        let capturesDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: capturesDirectory, withIntermediateDirectories: true)

        let fileName = "stale-container-\(UUID().uuidString).jpg"
        let currentLocation = capturesDirectory.appendingPathComponent(fileName)
        try Data("image".utf8).write(to: currentLocation)
        defer { try? FileManager.default.removeItem(at: currentLocation) }

        let stalePath = "/private/var/mobile/Containers/Data/Application/OLD-ID/Documents/Captures/\(fileName)"
        let item = Item(timestamp: Date(), imagePath: stalePath)

        #expect(item.resolvedImageURL?.path == currentLocation.path)
    }

    @Test func browserSessionNormalizedURLAcceptsHTTPAndHTTPS() {
        #expect(BrowserSession.normalizedURL(from: "http://example.com")?.absoluteString == "http://example.com")
        #expect(BrowserSession.normalizedURL(from: "https://example.com")?.absoluteString == "https://example.com")
        #expect(BrowserSession.normalizedURL(from: "example.com")?.absoluteString == "https://example.com")
    }

    @Test func browserSessionNormalizedURLRejectsUnsafeSchemes() {
        #expect(BrowserSession.normalizedURL(from: "file:///etc/passwd") == nil)
        #expect(BrowserSession.normalizedURL(from: "javascript:alert(1)") == nil)
        #expect(BrowserSession.normalizedURL(from: "ftp://example.com") == nil)
        #expect(BrowserSession.normalizedURL(from: "data:text/html,hello") == nil)
    }
}
