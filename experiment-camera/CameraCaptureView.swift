//
//  CameraCaptureView.swift
//  experiment-camera
//
//  Created by Nenad BOGOJEVIC on 19/06/2026.
//

import Foundation
import Combine
@preconcurrency import AVFoundation
import CoreImage
import UIKit

enum CaptureRetentionPolicy {
    static let maxRetainedImages = 10

    static func pruneCapturedImages(
        in directoryURL: URL,
        keepingNewest limit: Int = maxRetainedImages,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return []
        }

        let retainedImageCount = max(limit, 0)
        let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey, .isRegularFileKey]
        let imageFiles = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )
        .filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
        .compactMap { fileURL -> (url: URL, timestamp: Date)? in
            let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys)
            guard resourceValues?.isRegularFile == true else {
                return nil
            }

            let timestamp = resourceValues?.contentModificationDate ?? resourceValues?.creationDate ?? .distantPast
            return (url: fileURL, timestamp: timestamp)
        }
        .sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.url.lastPathComponent > rhs.url.lastPathComponent
            }

            return lhs.timestamp > rhs.timestamp
        }

        guard imageFiles.count > retainedImageCount else {
            return []
        }

        var removedFiles: [URL] = []

        for file in imageFiles.dropFirst(retainedImageCount) {
            try fileManager.removeItem(at: file.url)
            removedFiles.append(file.url)
        }

        return removedFiles
    }
}

@MainActor
final class CameraCaptureService: ObservableObject {
    private static let initialCaptureDelay: TimeInterval = 10
    private static let latestImageServerPort: UInt16 = 2112

    @Published private(set) var authorizationDenied = false
    @Published private(set) var captureCount = 0
    @Published private(set) var captureInterval: TimeInterval = 10
    @Published private(set) var isRunning = false
    @Published private(set) var wantsToRun = false
    @Published private(set) var lastCaptureDate: Date?
    @Published private(set) var hasCapturedImageSinceSessionStart = false
    @Published private(set) var errorMessage: String?

    private let sessionController = CaptureSessionController()
    private let latestImageServer = LatestImageHTTPServer(port: latestImageServerPort)
    private var onCapture: ((Date, String) -> Void)?
    private var timer: Timer?

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true

        latestImageServer.infoProvider = { [weak self] in
            self?.infoSnapshot() ?? .unavailable
        }
        latestImageServer.cameraControlHandler = { [weak self] shouldRun in
            await self?.setCameraRunning(shouldRun) ?? false
        }
        latestImageServer.start()

        sessionController.onCapture = { [weak self] result in
            Task { @MainActor in
                self?.handleCaptureResult(result)
            }
        }
    }

    var buttonTitle: String {
        wantsToRun ? "Stop Camera" : "Start Camera"
    }

    var buttonIconName: String {
        wantsToRun ? "stop.circle.fill" : "camera.fill"
    }

    var statusTitle: String {
        if authorizationDenied {
            return "Camera access needed"
        }

        if let errorMessage, !errorMessage.isEmpty {
            return "Camera unavailable"
        }

        if isRunning {
            return "Front camera recording"
        }

        return "Camera is stopped"
    }

    var statusMessage: String {
        if authorizationDenied {
            return "Allow camera access in Settings to capture an image every \(captureIntervalDescription). Latest saved image remains available at at webserver listening on port \(Self.latestImageServerPort) while the app is running. The service is advertised over Bonjour."
        }

        if let errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }

        if isRunning {
            return "The app saves image every \(captureIntervalDescription)."
        }

        return "Tap the camera button to capture from the front camera every \(captureIntervalDescription)."
    }

    private var captureIntervalDescription: String {
        let roundedSeconds = max(Int(captureInterval.rounded()), 1)
        return roundedSeconds == 1 ? "1 second" : "\(roundedSeconds) seconds"
    }

    func setCaptureHandler(_ handler: @escaping (Date, String) -> Void) {
        onCapture = handler
    }

    func clearCaptureHandler() {
        onCapture = nil
    }

    func setCaptureInterval(seconds: Int) {
        let sanitizedSeconds = max(seconds, 1)
        let updatedInterval = TimeInterval(sanitizedSeconds)

        guard captureInterval != updatedInterval else {
            return
        }

        captureInterval = updatedInterval

        if isRunning {
            scheduleTimedCaptures(capturingImmediately: false)
        }
    }

    func start() async {
        _ = await setCameraRunning(true)
    }

    func resumeIfNeeded() async {
        guard wantsToRun else {
            return
        }

        await startCaptureIfNeeded()
    }

    func pause() {
        Task {
            await stopSession()
        }
    }

    func stop() {
        Task {
            _ = await self.setCameraRunning(false)
        }
    }

    func setCameraRunning(_ shouldRun: Bool) async -> Bool {
        if shouldRun {
            wantsToRun = true
            await startCaptureIfNeeded()
            return isRunning
        }

        wantsToRun = false
        await stopSession()
        return isRunning
    }

    private func startCaptureIfNeeded() async {
        let isAuthorized = await requestAuthorizationIfNeeded()
        authorizationDenied = !isAuthorized

        guard isAuthorized else {
            await stopSession()
            return
        }

        errorMessage = nil

        guard !isRunning else {
            return
        }

        do {
            let didStart = try await sessionController.start()
            isRunning = didStart

            guard didStart else {
                errorMessage = "The camera session could not be started."
                return
            }

            hasCapturedImageSinceSessionStart = false
            scheduleTimedCaptures(capturingImmediately: true)
        } catch {
            errorMessage = error.localizedDescription
            await stopSession()
        }
    }

    private func stopSession() async {
        timer?.invalidate()
        timer = nil
        isRunning = false
        hasCapturedImageSinceSessionStart = false

        _ = await sessionController.stop()
    }

    private func scheduleTimedCaptures(capturingImmediately: Bool) {
        timer?.invalidate()

        timer = Timer.scheduledTimer(withTimeInterval: captureInterval, repeats: true) { [weak self] _ in
            guard let self else {
                return
            }

            Task { @MainActor in
                self.requestFrameCapture()
            }
        }

        if capturingImmediately {
            timer?.fireDate = Date().addingTimeInterval(Self.initialCaptureDelay)
        }
    }

    private func requestFrameCapture() {
        guard isRunning else {
            return
        }

        sessionController.requestCapture()
    }

    private func handleCaptureResult(_ result: Result<(Date, String), Error>) {
        switch result {
        case let .success((timestamp, imagePath)):
            captureCount += 1
            lastCaptureDate = timestamp
            hasCapturedImageSinceSessionStart = true
            onCapture?(timestamp, imagePath)
        case let .failure(error):
            errorMessage = error.localizedDescription
        }
    }

    private func requestAuthorizationIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func infoSnapshot() -> DeviceInfoSnapshot {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let batteryState = UIDevice.current.batteryState
        let batteryLevel = UIDevice.current.batteryLevel
        let percentageFull = batteryLevel >= 0 ? Int((batteryLevel * 100).rounded()) : nil

        return DeviceInfoSnapshot(
            deviceName: UIDevice.current.name,
            ipAddress: DeviceIPAddressProvider.currentIPAddress() ?? "Unavailable",
            battery: .init(
                state: batteryState.description,
                percentageFull: percentageFull,
                isCharging: batteryState == .charging || batteryState == .full
            ),
            camera: .init(
                isFilming: isRunning,
                wantsToRun: wantsToRun,
                status: "not_streaming",
                captureIntervalSeconds: Int(captureInterval.rounded()),
                captureCount: captureCount,
                lastCaptureAt: lastCaptureDate.map(formatter.string(from:)),
                hasCapturedImageSinceStart: hasCapturedImageSinceSessionStart,
                errorMessage: errorMessage
            )
        )
    }
}

private final class CaptureSessionController: @unchecked Sendable {
    private static let portraitVideoRotationAngle: CGFloat = 90

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoOutputQueue = DispatchQueue(label: "CameraCaptureService.VideoOutput")
    private let sessionQueue = DispatchQueue(label: "CameraCaptureService.Session")
    private let frameCaptureProcessor = VideoFrameCaptureProcessor()
    private var isConfigured = false

    var onCapture: ((Result<(Date, String), Error>) -> Void)? {
        get { frameCaptureProcessor.onCapture }
        set { frameCaptureProcessor.onCapture = newValue }
    }

    func start() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }

                do {
                    try self.configureSessionIfNeeded()

                    guard !self.session.isRunning else {
                        continuation.resume(returning: true)
                        return
                    }

                    self.session.startRunning()
                    continuation.resume(returning: self.session.isRunning)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async -> Bool {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }

                self.frameCaptureProcessor.cancelPendingCapture()

                if self.session.isRunning {
                    self.session.stopRunning()
                }

                continuation.resume(returning: self.session.isRunning)
            }
        }
    }

    func requestCapture() {
        frameCaptureProcessor.requestCapture()
    }

    private func configureSessionIfNeeded() throws {
        guard !isConfigured else {
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .photo
        defer { session.commitConfiguration() }

        let camera = try frontCameraDevice()
        let input = try AVCaptureDeviceInput(device: camera)

        guard session.canAddInput(input) else {
            throw CameraCaptureError.unableToAddCameraInput
        }

        session.addInput(input)

        guard session.canAddOutput(videoOutput) else {
            throw CameraCaptureError.unableToAddVideoOutput
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        videoOutput.setSampleBufferDelegate(frameCaptureProcessor, queue: videoOutputQueue)
        session.addOutput(videoOutput)

        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true
            }

            if #available(iOS 17.0, *) {
                if connection.isVideoRotationAngleSupported(Self.portraitVideoRotationAngle) {
                    connection.videoRotationAngle = Self.portraitVideoRotationAngle
                }
            } else if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }

        isConfigured = true
    }

    private func frontCameraDevice() throws -> AVCaptureDevice {
        if let trueDepthCamera = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) {
            return trueDepthCamera
        }

        if let wideAngleCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
            return wideAngleCamera
        }

        throw CameraCaptureError.frontCameraUnavailable
    }
}

private final class VideoFrameCaptureProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let ciContext = CIContext()
    private let lock = NSLock()
    private var pendingCapture = false
    private var lastDeliveredFrameTimestamp = CMTime.invalid
    var onCapture: ((Result<(Date, String), Error>) -> Void)?

    func requestCapture() {
        lock.lock()
        pendingCapture = true
        lock.unlock()
    }

    func cancelPendingCapture() {
        lock.lock()
        pendingCapture = false
        lock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard shouldCaptureFrame(with: sampleBuffer) else {
            return
        }

        do {
            let timestamp = Date()
            let fileURL = try saveFrame(from: sampleBuffer, takenAt: timestamp)
            onCapture?(.success((timestamp, fileURL.path)))
        } catch {
            onCapture?(.failure(error))
        }
    }

    private func shouldCaptureFrame(with sampleBuffer: CMSampleBuffer) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard pendingCapture else {
            return false
        }

        let currentTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard lastDeliveredFrameTimestamp == .invalid || CMTimeCompare(currentTimestamp, lastDeliveredFrameTimestamp) > 0 else {
            return false
        }

        pendingCapture = false
        lastDeliveredFrameTimestamp = currentTimestamp
        return true
    }

    private func saveFrame(from sampleBuffer: CMSampleBuffer, takenAt timestamp: Date) throws -> URL {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw CameraCaptureError.unableToCreateImageData
        }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else {
            throw CameraCaptureError.unableToCreateImageData
        }

        let uiImage = UIImage(cgImage: cgImage)
        guard let imageData = uiImage.jpegData(compressionQuality: 0.9) else {
            throw CameraCaptureError.unableToCreateImageData
        }

        let capturesDirectory = try capturesDirectoryURL()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let sanitizedTimestamp = formatter.string(from: timestamp).replacingOccurrences(of: ":", with: "-")
        let fileURL = capturesDirectory.appendingPathComponent("front-camera-\(sanitizedTimestamp).jpg")
        try imageData.write(to: fileURL, options: Data.WritingOptions.atomic)

        do {
            _ = try CaptureRetentionPolicy.pruneCapturedImages(in: capturesDirectory)
        } catch {
            print("Failed to prune older captured images: \(error.localizedDescription)")
        }

        return fileURL
    }

    private func capturesDirectoryURL() throws -> URL {
        let directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Captures", isDirectory: true)

        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        return directoryURL
    }
}

private enum CameraCaptureError: LocalizedError {
    case frontCameraUnavailable
    case unableToAddCameraInput
    case unableToAddVideoOutput
    case unableToCreateImageData

    var errorDescription: String? {
        switch self {
        case .frontCameraUnavailable:
            return "The front camera is not available on this device."
        case .unableToAddCameraInput:
            return "The app could not connect to the front camera."
        case .unableToAddVideoOutput:
            return "The app could not prepare silent frame capture output."
        case .unableToCreateImageData:
            return "The camera returned an empty image."
        }
    }
}
