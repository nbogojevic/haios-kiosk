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

@MainActor
final class CameraCaptureService: ObservableObject {
    @Published private(set) var authorizationDenied = false
    @Published private(set) var captureCount = 0
    @Published private(set) var captureInterval: TimeInterval = 10
    @Published private(set) var isRunning = false
    @Published private(set) var wantsToRun = false
    @Published private(set) var lastCaptureDate: Date?
    @Published private(set) var errorMessage: String?

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoOutputQueue = DispatchQueue(label: "CameraCaptureService.VideoOutput")
    private let frameCaptureProcessor = VideoFrameCaptureProcessor()
    private var onCapture: ((Date, String) -> Void)?
    private var isConfigured = false
    private var timer: Timer?

    init() {
        frameCaptureProcessor.onCapture = { [weak self] result in
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
            return "Allow camera access in Settings to capture an image every \(captureIntervalDescription)."
        }

        if let errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }

        if isRunning {
            return "The app silently saves one front-camera image immediately, then continues every \(captureIntervalDescription)."
        }

        return "Tap the camera button to silently capture from the front camera every \(captureIntervalDescription)."
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
        wantsToRun = true
        await startCaptureIfNeeded()
    }

    func resumeIfNeeded() async {
        guard wantsToRun else {
            return
        }

        await startCaptureIfNeeded()
    }

    func pause() {
        stopSession()
    }

    func stop() {
        wantsToRun = false
        stopSession()
    }

    private func startCaptureIfNeeded() async {
        let isAuthorized = await requestAuthorizationIfNeeded()
        authorizationDenied = !isAuthorized

        guard isAuthorized else {
            stopSession()
            return
        }

        errorMessage = nil

        guard configureSessionIfNeeded() else {
            stopSession()
            return
        }

        guard !isRunning else {
            return
        }

        session.startRunning()
        isRunning = session.isRunning
        scheduleTimedCaptures(capturingImmediately: true)
    }

    private func stopSession() {
        timer?.invalidate()
        timer = nil
        frameCaptureProcessor.cancelPendingCapture()

        if session.isRunning {
            session.stopRunning()
        }

        isRunning = false
    }

    private func configureSessionIfNeeded() -> Bool {
        guard !isConfigured else {
            return true
        }

        session.beginConfiguration()
        session.sessionPreset = .photo
        defer { session.commitConfiguration() }

        do {
            let camera = try frontCameraDevice()
            let input = try AVCaptureDeviceInput(device: camera)

            guard session.canAddInput(input) else {
                errorMessage = CameraCaptureError.unableToAddCameraInput.errorDescription
                return false
            }

            session.addInput(input)

            guard session.canAddOutput(videoOutput) else {
                errorMessage = CameraCaptureError.unableToAddVideoOutput.errorDescription
                return false
            }

            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
            videoOutput.setSampleBufferDelegate(frameCaptureProcessor, queue: videoOutputQueue)
            session.addOutput(videoOutput)

            if let connection = videoOutput.connection(with: .video), connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true
            }

            isConfigured = true
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
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

    private func scheduleTimedCaptures(capturingImmediately: Bool) {
        timer?.invalidate()

        if capturingImmediately {
            requestFrameCapture()
        }

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
        guard isConfigured, isRunning else {
            return
        }

        frameCaptureProcessor.requestCapture()
    }

    private func handleCaptureResult(_ result: Result<(Date, String), Error>) {
        switch result {
        case let .success((timestamp, imagePath)):
            captureCount += 1
            lastCaptureDate = timestamp
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
}

private final class VideoFrameCaptureProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let ciContext = CIContext()
    private let lock = NSLock()
    private var pendingCapture = false
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
        guard takePendingCaptureFlag() else {
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

    private func takePendingCaptureFlag() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard pendingCapture else {
            return false
        }

        pendingCapture = false
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
