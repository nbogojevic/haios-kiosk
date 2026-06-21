//
//  ExperimentCameraTests.swift
//  experiment-cameraTests
//
//  Created by Nenad BOGOJEVIC on 19/06/2026.
//

import Foundation
import Testing
import UIKit
@testable import experiment_camera

struct ExperimentCameraTests {
    @Test func pruneCapturedImagesKeepsNewestTenJPEGs() throws {
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
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let removedFiles = try CaptureRetentionPolicy.pruneCapturedImages(in: missingDirectory)

        #expect(removedFiles.isEmpty)
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
        #expect(DeviceCameraOrientation.landscapeLeft.videoRotationAngle == 0)
        #expect(DeviceCameraOrientation.landscapeRight.videoRotationAngle == 180)
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
}
