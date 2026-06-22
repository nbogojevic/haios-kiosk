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
    static let storageKey = "maxRetainedImages"
    static let defaultMaxRetainedImages = 300
    static let modeStorageKey = "captureRetentionMode"
    static let maxStorageMBStorageKey = "maxRetainedImageStorageMB"
    static let defaultMaxRetainedImageStorageMB = 100

    enum Mode: String, CaseIterable, Identifiable {
        case count
        case tieredAndSize

        var id: String { rawValue }

        var title: String {
            switch self {
            case .count:
                return "Newest count"
            case .tieredAndSize:
                return "Tiered + size"
            }
        }
    }

    private struct TierRule {
        let maxAge: TimeInterval?
        let stride: Int
    }

    private struct CapturedImageFile {
        let url: URL
        let timestamp: Date
        let byteSize: Int64
    }

    static let defaultMode: Mode = .tieredAndSize

    static var maxRetainedImages: Int {
        let storedValue = UserDefaults.standard.object(forKey: storageKey) as? Int
        return max(storedValue ?? defaultMaxRetainedImages, 0)
    }

    static var mode: Mode {
        guard let rawValue = UserDefaults.standard.string(forKey: modeStorageKey),
              let configuredMode = Mode(rawValue: rawValue) else {
            return defaultMode
        }

        return configuredMode
    }

    static var maxRetainedImageStorageMB: Int {
        let storedValue = UserDefaults.standard.object(forKey: maxStorageMBStorageKey) as? Int
        return max(storedValue ?? defaultMaxRetainedImageStorageMB, 1)
    }

    static func helperText(
        for mode: Mode = mode,
        maxRetainedImages: Int = maxRetainedImages,
        maxRetainedImageStorageMB: Int = maxRetainedImageStorageMB
    ) -> String {
        switch mode {
        case .count:
            let count = max(maxRetainedImages, 0)
            if count == 1 {
                return "Keep the newest photo and delete older photos."
            }

            return "Keep the newest \(count) photos and delete older photos."
        case .tieredAndSize:
            let clampedStorageMB = max(maxRetainedImageStorageMB, 1)
            return "Keep all photos from the last 24 hours, then keep every 2nd photo until 7 days, every 10th until 30 days, and every 60th after that. Total storage is capped at \(clampedStorageMB) MB by removing oldest remaining photos."
        }
    }

    static func pruneCapturedImages(
        in directoryURL: URL,
        keepingNewest limit: Int = maxRetainedImages,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return []
        }

        let imageFiles = try capturedImageFiles(in: directoryURL, fileManager: fileManager)
        guard !imageFiles.isEmpty else {
            return []
        }

        switch mode {
        case .count:
            return try pruneByCount(imageFiles, retainedImageCount: max(limit, 0), fileManager: fileManager)
        case .tieredAndSize:
            return try pruneByTieredAndSize(imageFiles, fileManager: fileManager)
        }
    }

    static func totalCapturedImageStorageBytes(
        in directoryURL: URL,
        fileManager: FileManager = .default
    ) -> Int64 {
        guard fileManager.fileExists(atPath: directoryURL.path),
              let imageFiles = try? capturedImageFiles(in: directoryURL, fileManager: fileManager) else {
            return 0
        }

        return imageFiles.reduce(Int64(0)) { $0 + $1.byteSize }
    }

    private static func capturedImageFiles(in directoryURL: URL, fileManager: FileManager) throws -> [CapturedImageFile] {
        let resourceKeys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .creationDateKey,
            .isRegularFileKey,
            .fileSizeKey
        ]

        return try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )
        .filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
        .compactMap { fileURL -> CapturedImageFile? in
            let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys)
            guard resourceValues?.isRegularFile == true else {
                return nil
            }

            let timestamp = resourceValues?.contentModificationDate ?? resourceValues?.creationDate ?? .distantPast
            let byteSize = Int64(resourceValues?.fileSize ?? 0)
            return CapturedImageFile(url: fileURL, timestamp: timestamp, byteSize: byteSize)
        }
    }

    private static func pruneByCount(
        _ imageFiles: [CapturedImageFile],
        retainedImageCount: Int,
        fileManager: FileManager
    ) throws -> [URL] {
        let sortedNewestFirst = imageFiles.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.url.lastPathComponent > rhs.url.lastPathComponent
            }

            return lhs.timestamp > rhs.timestamp
        }

        guard sortedNewestFirst.count > retainedImageCount else {
            return []
        }

        return try removeFiles(sortedNewestFirst.dropFirst(retainedImageCount).map(\.url), fileManager: fileManager)
    }

    private static func pruneByTieredAndSize(_ imageFiles: [CapturedImageFile], fileManager: FileManager) throws -> [URL] {
        let now = Date()
        let tierRules = retentionTierRules
        let sortedOldestFirst = imageFiles.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.url.lastPathComponent < rhs.url.lastPathComponent
            }

            return lhs.timestamp < rhs.timestamp
        }

        var removed = Set<URL>()
        var keptFiles: [CapturedImageFile] = []

        for (globalIndex, file) in sortedOldestFirst.enumerated() {
            let age = now.timeIntervalSince(file.timestamp)
            let stride = strideForAge(age, tierRules: tierRules)
            if globalIndex.isMultiple(of: stride) {
                keptFiles.append(file)
            } else {
                removed.insert(file.url)
            }
        }

        if let maxBytes = maxRetainedImageStorageBytes {
            var totalKeptBytes = keptFiles.reduce(Int64(0)) { $0 + $1.byteSize }
            for file in keptFiles where totalKeptBytes > maxBytes {
                removed.insert(file.url)
                totalKeptBytes -= file.byteSize
            }
        }

        return try removeFiles(Array(removed), fileManager: fileManager)
    }

    private static func removeFiles(_ files: [URL], fileManager: FileManager) throws -> [URL] {
        var removedFiles: [URL] = []

        for fileURL in files {
            try fileManager.removeItem(at: fileURL)
            removedFiles.append(fileURL)
        }

        return removedFiles
    }

    private static var maxRetainedImageStorageBytes: Int64? {
        Int64(maxRetainedImageStorageMB) * 1_000_000
    }

    private static var retentionTierRules: [TierRule] {
        [
            TierRule(maxAge: 24 * 60 * 60, stride: 1),
            TierRule(maxAge: 7 * 24 * 60 * 60, stride: 2),
            TierRule(maxAge: 30 * 24 * 60 * 60, stride: 10),
            TierRule(maxAge: nil, stride: 60)
        ]
    }

    private static func strideForAge(_ age: TimeInterval, tierRules: [TierRule]) -> Int {
        guard let tier = tierRules.first(where: { rule in
            guard let maxAge = rule.maxAge else {
                return true
            }

            return age <= maxAge
        }) else {
            return 1
        }

        return max(tier.stride, 1)
    }
}

enum DeviceCameraOrientation: CaseIterable, Sendable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight

    init?(deviceOrientation: UIDeviceOrientation) {
        switch deviceOrientation {
        case .portrait:
            self = .portrait
        case .portraitUpsideDown:
            self = .portraitUpsideDown
        case .landscapeLeft:
            self = .landscapeLeft
        case .landscapeRight:
            self = .landscapeRight
        default:
            return nil
        }
    }

    static func current(fallback: DeviceCameraOrientation = .portrait) -> DeviceCameraOrientation {
        if let orientation = DeviceCameraOrientation(deviceOrientation: UIDevice.current.orientation) {
            return orientation
        }

        return fallback
    }

    var isLandscape: Bool {
        switch self {
        case .landscapeLeft, .landscapeRight:
            return true
        case .portrait, .portraitUpsideDown:
            return false
        }
    }

    var videoRotationAngle: CGFloat {
        switch self {
        case .portrait:
            return 90
        case .portraitUpsideDown:
            return 270
        case .landscapeLeft:
            return 180
        case .landscapeRight:
            return 0
        }
    }

    @available(iOS, introduced: 13.0, deprecated: 17.0)
    func applyLegacyVideoOrientation(to connection: AVCaptureConnection) {
        switch self {
        case .portrait:
            connection.videoOrientation = .portrait
        case .portraitUpsideDown:
            connection.videoOrientation = .portraitUpsideDown
        case .landscapeLeft:
            connection.videoOrientation = .landscapeRight
        case .landscapeRight:
            connection.videoOrientation = .landscapeLeft
        }
    }
}

@MainActor
final class CameraCaptureService: ObservableObject {
    private static let imageServerPort: UInt16 = 2112
    private static let rtspServerPort: UInt16 = 2113

    @Published private(set) var authorizationDenied = false
    @Published private(set) var captureCount = 0
    @Published private(set) var captureInterval: TimeInterval = 10
    @Published private(set) var isRunning = false
    @Published private(set) var wantsToRun = false
    @Published private(set) var lastCaptureDate: Date?
    @Published private(set) var hasCapturedImageSinceSessionStart = false
    @Published private(set) var errorMessage: String?

    private let sessionController = CaptureSessionController()
    private let imageServer = ImageHTTPServer(port: imageServerPort)
    private let rtspServer = RTSPServer(port: rtspServerPort)
    private var onCapture: ((Date, String) -> Void)?
    private var timer: Timer?
    private var currentOrientation = DeviceCameraOrientation.current()
    private var isGeneratingOrientationNotifications = false

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        currentOrientation = DeviceCameraOrientation.current(fallback: currentOrientation)

        imageServer.infoProvider = { [weak self] in
            self?.infoSnapshot() ?? .unavailable
        }
        imageServer.cameraControlHandler = { [weak self] shouldRun in
            await self?.setCameraRunning(shouldRun) ?? false
        }
        imageServer.start()
        rtspServer.start()

        sessionController.onCapture = { [weak self] result in
            Task { @MainActor in
                self?.handleCaptureResult(result)
            }
        }
        sessionController.onVideoSampleBuffer = { [weak self] sampleBuffer in
            self?.rtspServer.enqueueSampleBuffer(sampleBuffer)
        }
    }

    var buttonTitle: String {
        wantsToRun ? "Stop Camera" : "Start Camera"
    }

    var buttonIconName: String {
        wantsToRun ? "stop.circle.fill" : "camera.fill"
    }

    var previewSession: AVCaptureSession {
        sessionController.previewSession
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
            return "Allow camera access in Settings to capture an image every \(captureIntervalDescription). Latest saved image remains available at the web server listening on port \(Self.imageServerPort) while the app is running. The service is advertised over Bonjour."
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
            scheduleTimedCaptures()
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
            beginGeneratingOrientationNotificationsIfNeeded()
            let captureOrientation = resolvedCaptureOrientation()
            let didStart = try await sessionController.start(videoOrientation: captureOrientation)
            isRunning = didStart

            guard didStart else {
                errorMessage = "The camera session could not be started."
                return
            }

            hasCapturedImageSinceSessionStart = false
            scheduleTimedCaptures()
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
        endGeneratingOrientationNotificationsIfNeeded()

        _ = await sessionController.stop()
    }

    private func scheduleTimedCaptures() {
        timer?.invalidate()

        timer = Timer.scheduledTimer(withTimeInterval: captureInterval, repeats: true) { [weak self] _ in
            guard let self else {
                return
            }

            Task { @MainActor in
                self.requestFrameCapture()
            }
        }
    }

    private func requestFrameCapture() {
        guard isRunning else {
            return
        }

        sessionController.requestCapture(with: resolvedCaptureOrientation())
    }

    private func resolvedCaptureOrientation() -> DeviceCameraOrientation {
        let orientation = DeviceCameraOrientation.current(fallback: currentOrientation)
        currentOrientation = orientation
        return orientation
    }

    private func beginGeneratingOrientationNotificationsIfNeeded() {
        guard !isGeneratingOrientationNotifications else {
            return
        }

        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        isGeneratingOrientationNotifications = true
    }

    private func endGeneratingOrientationNotificationsIfNeeded() {
        guard isGeneratingOrientationNotifications else {
            return
        }

        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        isGeneratingOrientationNotifications = false
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
                errorMessage: errorMessage,
                retention: .init(
                    mode: CaptureRetentionPolicy.mode.rawValue,
                    maxRetainedImages: CaptureRetentionPolicy.maxRetainedImages,
                    maxRetainedImageStorageMB: CaptureRetentionPolicy.maxRetainedImageStorageMB,
                )
            )
        )
    }
}

private final class CaptureSessionController: @unchecked Sendable {
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoOutputQueue = DispatchQueue(label: "CameraCaptureService.VideoOutput")
    private let sessionQueue = DispatchQueue(label: "CameraCaptureService.Session")
    private let frameCaptureProcessor = VideoFrameCaptureProcessor()
    private var isConfigured = false
    private var appliedVideoOrientation: DeviceCameraOrientation?

    var onCapture: ((Result<(Date, String), Error>) -> Void)? {
        get { frameCaptureProcessor.onCapture }
        set { frameCaptureProcessor.onCapture = newValue }
    }

    var onVideoSampleBuffer: ((CMSampleBuffer) -> Void)? {
        get { frameCaptureProcessor.onVideoSampleBuffer }
        set { frameCaptureProcessor.onVideoSampleBuffer = newValue }
    }

    var previewSession: AVCaptureSession {
        session
    }

    func start(videoOrientation: DeviceCameraOrientation) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }

                do {
                    try self.configureSessionIfNeeded()
                    self.applyVideoOrientation(videoOrientation)

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

    func requestCapture(with orientation: DeviceCameraOrientation) {
        sessionQueue.async { [weak self] in
            guard let self else {
                return
            }

            self.applyVideoOrientation(orientation)
            self.frameCaptureProcessor.requestCapture()
        }
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

        applyVideoOrientation(.portrait)

        isConfigured = true
    }

    private func applyVideoOrientation(_ orientation: DeviceCameraOrientation) {
        guard appliedVideoOrientation != orientation else {
            return
        }

        guard let connection = videoOutput.connection(with: .video) else {
            return
        }

        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }

        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(orientation.videoRotationAngle) {
                connection.videoRotationAngle = orientation.videoRotationAngle
            }
        } else if connection.isVideoOrientationSupported {
            orientation.applyLegacyVideoOrientation(to: connection)
        }

        appliedVideoOrientation = orientation
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
    var onVideoSampleBuffer: ((CMSampleBuffer) -> Void)?

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
        onVideoSampleBuffer?(sampleBuffer)

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
        let fileURL = capturesDirectory.appendingPathComponent("kiosk-\(sanitizedTimestamp).jpg")
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
