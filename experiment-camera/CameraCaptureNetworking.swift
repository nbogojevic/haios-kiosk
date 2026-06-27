//
//  CameraCaptureNetworking.swift
//  experiment-camera
//
//  Created by GitHub Copilot on 20/06/2026.
//

import Foundation
import Darwin
import Network
import UIKit
@preconcurrency import AVFoundation
import VideoToolbox

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

struct HTTPServerAuthentication {
    static let usernameStorageKey = "httpServerUsername"
    static let passwordStorageKey = "httpServerPassword"
    static let defaultUsername = "kamera"
    static let defaultPassword = "lozinka"

    let username: String
    let password: String
    let isEnabled: Bool

    static func currentCredentials(userDefaults: UserDefaults = .standard) -> HTTPServerAuthentication {
        let storedUsername = userDefaults.string(forKey: usernameStorageKey)
        let storedPassword = userDefaults.string(forKey: passwordStorageKey)

        if isBlank(storedUsername), isBlank(storedPassword) {
            return HTTPServerAuthentication(username: "", password: "", isEnabled: false)
        }

        return HTTPServerAuthentication(
            username: sanitizedCredential(
                storedUsername,
                defaultValue: defaultUsername
            ),
            password: sanitizedCredential(
                storedPassword,
                defaultValue: defaultPassword
            ),
            isEnabled: true
        )
    }

    nonisolated func authorizes(headerValue: String?) -> Bool {
        guard isEnabled else {
            return true
        }

        guard let headerValue else {
            return false
        }

        let parts = headerValue.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2,
              parts[0].lowercased() == "basic",
              let decodedData = Data(base64Encoded: String(parts[1])),
              let decodedValue = String(data: decodedData, encoding: .utf8),
              let separatorIndex = decodedValue.firstIndex(of: ":") else {
            return false
        }

        let providedUsername = String(decodedValue[..<separatorIndex])
        let providedPassword = String(decodedValue[decodedValue.index(after: separatorIndex)...])
        return secureCompare(providedUsername, username) && secureCompare(providedPassword, password)
    }

    private static func isBlank(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
    }

    private static func sanitizedCredential(_ value: String?, defaultValue: String) -> String {
        guard let value else {
            return defaultValue
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? defaultValue : trimmedValue
    }

    nonisolated private func secureCompare(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        var difference = lhsBytes.count ^ rhsBytes.count
        let maxCount = max(lhsBytes.count, rhsBytes.count)

        for index in 0..<maxCount {
            let lhsByte = index < lhsBytes.count ? lhsBytes[index] : 0
            let rhsByte = index < rhsBytes.count ? rhsBytes[index] : 0
            difference |= Int(lhsByte ^ rhsByte)
        }

        return difference == 0
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

final class ImageHTTPServer {
    nonisolated static let serviceType = "_latestimg._tcp"
    nonisolated private static let infoPath = "/info"
    nonisolated private static let latestImagePath = "/latestImage.jpg"
    nonisolated private static let mjpegPath = "/mjpeg"
    nonisolated private static let cameraPath = "/camera"

    private let port: NWEndpoint.Port
    private let listenerQueue = DispatchQueue(label: "CameraCaptureService.HTTPServer.Listener")
    private let connectionQueue = DispatchQueue(label: "CameraCaptureService.HTTPServer.Connection")
    private let streamCountLock = NSLock()
    private var listener: NWListener?
    private var isStarted = false
    private var activeMJPEGStreamCount = 0
    var infoProvider: (() async -> DeviceInfoSnapshot)?
    var cameraControlHandler: ((Bool) async -> Bool)?
    nonisolated(unsafe) var authenticationProvider: () -> HTTPServerAuthentication = {
        HTTPServerAuthentication.currentCredentials()
    }

    init(port: UInt16) {
        self.port = NWEndpoint.Port(rawValue: port) ?? .init(integerLiteral: 2112)
    }

    func start() {
        guard !isStarted else {
            return
        }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            let listener = try NWListener(using: parameters, on: port)
            // Publishing `listener.service` makes this TCP listener visible via Bonjour.
            // Bonjour advertises:
            // - `name`: a human-readable instance name shown to clients
            // - `type`: the service type (`_latestimg._tcp`)
            // - `txtRecord`: small metadata key/value pairs clients can read before connecting
            listener.service = NWListener.Service(
                name: bonjourServiceName(),
                type: Self.serviceType,
                txtRecord: bonjourTXTRecord()
            )
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else {
                    return
                }

                switch state {
                case .failed, .cancelled:
                    self.isStarted = false
                    self.listener = nil
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }

            self.listener = listener
            self.isStarted = true
            listener.start(queue: listenerQueue)
        } catch {
            isStarted = false
            listener = nil
            print("Image HTTP server failed to start: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isStarted = false
    }

    private func bonjourServiceName() -> String {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "experiment-camera"
        let deviceName = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Bonjour instance name example: "experiment-camera on Nenad’s iPhone".
        // This is the friendly service name clients see during discovery.
        return "\(appName) on \(deviceName)"
    }

    private func bonjourTXTRecord() -> Data {
        // TXT records are metadata published with the Bonjour service.
        // Values advertised here:
        // - `path`        = "/latestImage.jpg"    -> HTTP path clients should request
        // - `format`      = "image/jpeg"          -> MIME type of the served resource
        // - `mjpeg_path`  = "/mjpeg"              -> MJPEG multipart stream of captured frames
        // - `mjpeg_format`= "multipart/x-mixed-replace" -> MIME type of the live stream
        // - `info_path`   = "/info"               -> JSON device and camera status
        // - `info_format` = "application/json"    -> MIME type of the served metadata
        // - `camera_path` = "/camera"             -> plain-text camera power endpoint
        // - `camera_format` = "text/plain"        -> MIME type of the served camera power state
        NetService.data(fromTXTRecord: [
            "path": Data(Self.latestImagePath.utf8),
            "format": Data("image/jpeg".utf8),
            "mjpeg_path": Data(Self.mjpegPath.utf8),
            "mjpeg_format": Data("multipart/x-mixed-replace".utf8),
            "info_path": Data(Self.infoPath.utf8),
            "info_format": Data("application/json".utf8),
            "camera_path": Data(Self.cameraPath.utf8),
            "camera_format": Data("text/plain".utf8)
        ])
    }

    nonisolated private func handleNewConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveRequest(on: connection)
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }

        connection.start(queue: connectionQueue)
    }

    nonisolated private static let maxHTTPRequestBytes = 256 * 1_024

    nonisolated private func receiveRequest(on connection: NWConnection, accumulatedData: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            Task {
                guard error == nil else {
                    let response = Self.errorResponse(status: "400 Bad Request", message: "The request could not be read.")
                    connection.send(content: response, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    return
                }

                var bufferedData = accumulatedData
                if let data {
                    bufferedData.append(data)
                }

                if bufferedData.count > Self.maxHTTPRequestBytes {
                    let response = Self.errorResponse(status: "413 Payload Too Large", message: "The request exceeded the maximum supported size.")
                    connection.send(content: response, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    return
                }

                switch Self.parseRequest(from: bufferedData) {
                case let .request(request):
                    await self.handleRequest(request, on: connection)
                case .incomplete:
                    guard !isComplete else {
                        let response = Self.errorResponse(status: "400 Bad Request", message: "The request ended before all headers or body bytes were received.")
                        connection.send(content: response, completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                        return
                    }

                    self.receiveRequest(on: connection, accumulatedData: bufferedData)
                case .invalid:
                    let response = Self.errorResponse(status: "400 Bad Request", message: "The request was malformed.")
                    connection.send(content: response, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
            }
        }
    }

    private func handleRequest(_ request: HTTPRequest, on connection: NWConnection) async {
        guard isAuthorized(request) else {
            let response = Self.unauthorizedResponse(omitBody: request.omitBody)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        if request.path == Self.cameraPath {
            let response = await cameraResponse(for: request)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        guard request.method == "GET" || request.method == "HEAD" else {
            let body = Data("Only GET and HEAD are supported.".utf8)
            let response = Self.response(
                status: "405 Method Not Allowed",
                headers: [
                    "Allow": "GET, HEAD",
                    "Content-Type": "text/plain; charset=utf-8"
                ],
                body: body,
                omitBody: request.omitBody,
                contentLength: body.count
            )

            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        if request.path == Self.mjpegPath {
            await streamMJPEG(on: connection, omitBody: request.omitBody)
            return
        }

        let response = await responseData(path: request.path, omitBody: request.omitBody)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func cameraResponse(for request: HTTPRequest) async -> Data {
        switch request.method {
        case "GET", "HEAD":
            return cameraStateResponse(isOn: await currentCameraIsOn(), omitBody: request.omitBody)
        case "POST":
            guard let command = request.trimmedBody?.uppercased(), ["ON", "OFF"].contains(command) else {
                let body = Data("Camera POST body must be ON or OFF.".utf8)
                return Self.response(
                    status: "400 Bad Request",
                    headers: [
                        "Allow": "GET, HEAD, POST",
                        "Content-Type": "text/plain; charset=utf-8"
                    ],
                    body: body,
                    omitBody: request.omitBody,
                    contentLength: body.count
                )
            }

            let requestedIsOn = command == "ON"
            let isOn: Bool

            if let cameraControlHandler {
                isOn = await cameraControlHandler(requestedIsOn)
            } else {
                isOn = await currentCameraIsOn()
            }

            return cameraStateResponse(isOn: isOn, omitBody: request.omitBody)
        default:
            let body = Data("Only GET, HEAD, and POST are supported.".utf8)
            return Self.response(
                status: "405 Method Not Allowed",
                headers: [
                    "Allow": "GET, HEAD, POST",
                    "Content-Type": "text/plain; charset=utf-8"
                ],
                body: body,
                omitBody: request.omitBody,
                contentLength: body.count
            )
        }
    }

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        guard Self.requiresAuthentication(path: request.path) else {
            return true
        }

        return authenticationProvider().authorizes(headerValue: request.headers["authorization"])
    }

    nonisolated private static func requiresAuthentication(path: String) -> Bool {
        path == infoPath || path == latestImagePath || path == mjpegPath || path == cameraPath
    }

    private func currentCameraIsOn() async -> Bool {
        let info = await infoProvider?() ?? .unavailable
        return info.camera.isFilming
    }

    private func cameraStateResponse(isOn: Bool, omitBody: Bool) -> Data {
        let body = Data((isOn ? "ON" : "OFF").utf8)
        return Self.response(
            status: "200 OK",
            headers: [
                "Allow": "GET, HEAD, POST",
                "Cache-Control": "no-store",
                "Content-Type": "text/plain; charset=utf-8"
            ],
            body: body,
            omitBody: omitBody,
            contentLength: body.count
        )
    }

    private func responseData(path: String, omitBody: Bool) async -> Data {
        guard path == Self.latestImagePath else {
            guard path == Self.infoPath else {
                return Self.errorResponse(status: "404 Not Found", message: "The requested resource was not found.", omitBody: omitBody)
            }

            let info = await infoProvider?() ?? .unavailable
            let body = info.withCameraStatus(currentStreamingStatus(for: info)).responseBody()
            return Self.response(
                status: "200 OK",
                headers: [
                    "Content-Type": "application/json; charset=utf-8",
                    "Cache-Control": "no-store"
                ],
                body: body,
                omitBody: omitBody,
                contentLength: body.count
            )
        }

        do {
            guard let latestImageURL = try LatestCaptureFileLocator.latestImageURL() else {
                return Self.errorResponse(status: "404 Not Found", message: "No captured image is available yet.", omitBody: omitBody)
            }

            let imageData = try Data(contentsOf: latestImageURL)
            return Self.response(
                status: "200 OK",
                headers: [
                    "Content-Type": "image/jpeg",
                    "Cache-Control": "no-store"
                ],
                body: imageData,
                omitBody: omitBody,
                contentLength: imageData.count
            )
        } catch {
            return Self.errorResponse(status: "500 Internal Server Error", message: "The latest image could not be loaded.", omitBody: omitBody)
        }
    }

    private func streamMJPEG(on connection: NWConnection, omitBody: Bool) async {
        let boundary = "Boundary-\(UUID().uuidString)"
        let headers = Self.headerResponse(
            status: "200 OK",
            headers: [
                "Cache-Control": "no-store",
                "Connection": "close",
                "Content-Type": "multipart/x-mixed-replace; boundary=\(boundary)",
                "Pragma": "no-cache"
            ]
        )

        guard await send(headers, on: connection) == nil else {
            connection.cancel()
            return
        }

        guard !omitBody else {
            connection.cancel()
            return
        }

        let waitingForFirstImagePlaceholder = Self.placeholderImageJPEGData(style: .waitingForFirstImage)
        let cameraOffPlaceholder = Self.placeholderImageJPEGData(style: .cameraOff)
        var lastFrameIdentity: MJPEGFrameIdentity?
        var numberOfSameFramesSent = 0

        incrementActiveMJPEGStreamCount()
        defer { decrementActiveMJPEGStreamCount() }

        while !Task.isCancelled {
            let update = await nextMJPEGFrameUpdate(
                after: lastFrameIdentity,
                waitingForFirstImagePlaceholder: waitingForFirstImagePlaceholder,
                cameraOffPlaceholder: cameraOffPlaceholder
            )
            
            
            switch update {
            case let .frame(identity, imageData):
                if lastFrameIdentity == nil ||
                    (identity == .placeholder(.waitingForFirstImage) && (lastFrameIdentity != .placeholder(.waitingForFirstImage) || numberOfSameFramesSent < 1)) ||
                    (identity == .placeholder(.cameraOff) && (lastFrameIdentity != .placeholder(.cameraOff) || numberOfSameFramesSent < 1)) ||
                    (identity != .placeholder(.cameraOff) && identity != .placeholder(.waitingForFirstImage)) {
                    if (identity == lastFrameIdentity) {
                        numberOfSameFramesSent += 1
                    } else {
                        numberOfSameFramesSent = 0
                    }
                    let part = Self.mjpegFrame(boundary: boundary, imageData: imageData)
                    guard await send(part, on: connection) == nil else {
                        connection.cancel()
                        return
                    }
                }

                lastFrameIdentity = identity
            case .noChange:
                break
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func nextMJPEGFrameUpdate(
        after lastFrameIdentity: MJPEGFrameIdentity?,
        waitingForFirstImagePlaceholder: Data,
        cameraOffPlaceholder: Data
    ) async -> MJPEGFrameUpdate {
        let info = await infoProvider?() ?? .unavailable
        let streamState = MJPEGStreamState(cameraInfo: info.camera)

        switch streamState {
        case .cameraOff:
            let identity: MJPEGFrameIdentity = .placeholder(.cameraOff)
            return .frame(identity: identity, imageData: cameraOffPlaceholder)
        case .waitingForFirstImage:
            let identity: MJPEGFrameIdentity = .placeholder(.waitingForFirstImage)
            return .frame(identity: identity, imageData: waitingForFirstImagePlaceholder)
        case .live:
            break
        }

        do {
            guard let latestImage = try LatestCaptureFileLocator.latestImageFile() else {
                let identity: MJPEGFrameIdentity = .placeholder(.waitingForFirstImage)
                return .frame(identity: identity, imageData: waitingForFirstImagePlaceholder)
            }

            let identity: MJPEGFrameIdentity = .latestImage(
                path: latestImage.url.path,
                modificationTimeIntervalSinceReferenceDate: latestImage.modificationDate.timeIntervalSinceReferenceDate
            )

            guard lastFrameIdentity != identity else {
                return .noChange
            }

            let imageData = try Data(contentsOf: latestImage.url)
            return .frame(identity: identity, imageData: imageData)
        } catch {
            let identity: MJPEGFrameIdentity = .placeholder(.waitingForFirstImage)
            return .frame(identity: identity, imageData: waitingForFirstImagePlaceholder)
        }
    }

    private func currentStreamingStatus(for info: DeviceInfoSnapshot) -> String {
        guard currentActiveMJPEGStreamCount() > 0 else {
            return "not_streaming"
        }

        return MJPEGStreamState(cameraInfo: info.camera).cameraStatus
    }

    private func currentActiveMJPEGStreamCount() -> Int {
        streamCountLock.lock()
        defer { streamCountLock.unlock() }
        return activeMJPEGStreamCount
    }

    private func incrementActiveMJPEGStreamCount() {
        streamCountLock.lock()
        activeMJPEGStreamCount += 1
        streamCountLock.unlock()
    }

    private func decrementActiveMJPEGStreamCount() {
        streamCountLock.lock()
        activeMJPEGStreamCount = max(activeMJPEGStreamCount - 1, 0)
        streamCountLock.unlock()
    }

    private func send(_ data: Data, on connection: NWConnection) async -> NWError? {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error)
            })
        }
    }

    nonisolated private static func parseRequest(from requestData: Data) -> HTTPRequestParseResult {
        guard let headerDelimiterRange = requestData.range(of: Data("\r\n\r\n".utf8)) else {
            return .incomplete
        }

        let headerBlock = requestData[..<headerDelimiterRange.lowerBound]
        guard let headerText = String(data: headerBlock, encoding: .utf8) else {
            return .invalid
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            return .invalid
        }

        let components = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard components.count >= 2 else {
            return .invalid
        }

        let method = String(components[0]).uppercased()
        let rawPath = String(components[1])
        let path = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)
            ?? rawPath

        var headers: [String: String] = [:]
        var contentLength = 0
        for line in lines.dropFirst() {
            let headerParts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard headerParts.count == 2 else {
                continue
            }

            let name = String(headerParts[0]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let rawValue = String(headerParts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = rawValue

            if name == "content-length" {
                guard let parsedLength = Int(rawValue), parsedLength >= 0 else {
                    return .invalid
                }

                contentLength = parsedLength
            }
        }

        let bodyStartIndex = headerDelimiterRange.upperBound
        let requiredByteCount = bodyStartIndex + contentLength
        guard requestData.count >= requiredByteCount else {
            return .incomplete
        }

        let body: Data
        if contentLength == 0 {
            body = Data()
        } else {
            body = requestData.subdata(in: bodyStartIndex..<requiredByteCount)
        }

        return .request(
            HTTPRequest(
                method: method,
                path: path,
                headers: headers,
                body: body,
                omitBody: method == "HEAD"
            )
        )
    }

    private static func placeholderImageJPEGData(style: MJPEGPlaceholderStyle) -> Data {
        let size = CGSize(width: 1280, height: 720)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let bounds = CGRect(origin: .zero, size: size)
            UIColor.systemGray4.setFill()
            context.fill(bounds)

            switch style {
            case .waitingForFirstImage:
                UIColor.systemGreen.withAlphaComponent(0.12).setFill()
            case .cameraOff:
                UIColor.systemRed.withAlphaComponent(0.06).setFill()
            }

            context.fill(bounds)

            let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 180, weight: .regular)
            let icon = UIImage(systemName: "camera.fill", withConfiguration: symbolConfiguration)
            let tintedIcon = icon?.withTintColor(UIColor.systemGray2, renderingMode: .alwaysOriginal)
            let iconSize = CGSize(width: 220, height: 180)
            let iconOrigin = CGPoint(
                x: (size.width - iconSize.width) / 2,
                y: (size.height - iconSize.height) / 2
            )
            tintedIcon?.draw(in: CGRect(origin: iconOrigin, size: iconSize))

            let title = switch style {
            case .waitingForFirstImage:
                "Waiting..."
            case .cameraOff:
                "Camera Off"
            }

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center

            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 42, weight: .semibold),
                .foregroundColor: UIColor.systemGray,
                .paragraphStyle: paragraphStyle
            ]

            let titleRect = CGRect(
                x: 120,
                y: iconOrigin.y + iconSize.height + 28,
                width: size.width - 240,
                height: 52
            )

            title.draw(in: titleRect, withAttributes: titleAttributes)
        }

        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }

    nonisolated private static func mjpegFrame(boundary: String, imageData: Data) -> Data {
        var frameData = Data()
        let frameHeaders = [
            "--\(boundary)",
            "Content-Type: image/jpeg",
            "Content-Length: \(imageData.count)",
            ""
        ]

        frameData.append(Data(frameHeaders.joined(separator: "\r\n").utf8))
        frameData.append(Data("\r\n".utf8))
        frameData.append(imageData)
        frameData.append(Data("\r\n".utf8))
        return frameData
    }

    nonisolated private static func headerResponse(status: String, headers: [String: String]) -> Data {
        var responseHeaders = ["HTTP/1.1 \(status)"]

        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            responseHeaders.append("\(name): \(value)")
        }

        responseHeaders.append("")
        responseHeaders.append("")
        return Data(responseHeaders.joined(separator: "\r\n").utf8)
    }

    nonisolated private static func errorResponse(status: String, message: String, omitBody: Bool = false) -> Data {
        let body = Data(message.utf8)
        return response(
            status: status,
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: body,
            omitBody: omitBody,
            contentLength: body.count
        )
    }

    nonisolated private static func unauthorizedResponse(omitBody: Bool) -> Data {
        let body = Data("Authentication is required.".utf8)
        return response(
            status: "401 Unauthorized",
            headers: [
                "Cache-Control": "no-store",
                "Content-Type": "text/plain; charset=utf-8",
                "WWW-Authenticate": "Basic realm=\"experiment-camera\", charset=\"UTF-8\""
            ],
            body: body,
            omitBody: omitBody,
            contentLength: body.count
        )
    }

    nonisolated private static func response(
        status: String,
        headers: [String: String],
        body: Data,
        omitBody: Bool,
        contentLength: Int
    ) -> Data {
        var responseData = Data()
        var responseHeaders = ["HTTP/1.1 \(status)", "Connection: close", "Content-Length: \(contentLength)"]

        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            responseHeaders.append("\(name): \(value)")
        }

        responseHeaders.append("")
        responseHeaders.append("")

        if let headerData = responseHeaders.joined(separator: "\r\n").data(using: .utf8) {
            responseData.append(headerData)
        }

        if !omitBody {
            responseData.append(body)
        }

        return responseData
    }
}

final class RTSPServer {
    nonisolated static let serviceType = "_rtsp._tcp"
    nonisolated static let streamPath = "/stream"
    nonisolated static let supportedMethods = "OPTIONS, DESCRIBE, SETUP, PLAY, PAUSE, TEARDOWN"

    private let port: NWEndpoint.Port
    private let listenerQueue = DispatchQueue(label: "CameraCaptureService.RTSPServer.Listener")
    private let connectionQueue = DispatchQueue(label: "CameraCaptureService.RTSPServer.Connection")
    private let streamQueue = DispatchQueue(label: "CameraCaptureService.RTSPServer.Stream")
    private let stateLock = NSLock()
    nonisolated(unsafe) private var listener: NWListener?
    nonisolated(unsafe) private var isStarted = false
    nonisolated(unsafe) private var activeSession: RTSPSessionState?
    nonisolated(unsafe) private var activeConnection: NWConnection?
    nonisolated(unsafe) private var latestParameterSets: H264ParameterSets?
    private lazy var encoder = H264VideoEncoder { [weak self] accessUnit in
        self?.streamQueue.async {
            self?.sendEncodedAccessUnit(accessUnit)
        }
    }
    nonisolated(unsafe) var authenticationProvider: () -> HTTPServerAuthentication = {
        HTTPServerAuthentication.currentCredentials()
    }

    init(port: UInt16) {
        self.port = NWEndpoint.Port(rawValue: port) ?? .init(integerLiteral: 2113)
    }

    func start() {
        guard !isStarted else {
            return
        }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            let listener = try NWListener(using: parameters, on: port)
            listener.service = NWListener.Service(
                name: bonjourServiceName(),
                type: Self.serviceType,
                txtRecord: bonjourTXTRecord()
            )
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else {
                    return
                }

                switch state {
                case .failed, .cancelled:
                    self.isStarted = false
                    self.listener = nil
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }

            self.listener = listener
            self.isStarted = true
            listener.start(queue: listenerQueue)
        } catch {
            isStarted = false
            listener = nil
            print("RTSP spike server failed to start: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isStarted = false

        stateLock.lock()
        activeSession = nil
        activeConnection = nil
        stateLock.unlock()

        encoder.reset()
    }

    nonisolated func enqueueSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        let wrappedSampleBuffer = UnsafeSampleBuffer(value: sampleBuffer)
        streamQueue.async { [weak self] in
            guard let self, self.isSessionPlaying else {
                return
            }

            Task { @MainActor [weak self] in
                self?.encoder.encode(wrappedSampleBuffer.value)
            }
        }
    }

    nonisolated private func handleNewConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveRequest(on: connection)
            case .failed, .cancelled:
                self?.clearSessionIfNeeded(for: connection)
                connection.cancel()
            default:
                break
            }
        }

        connection.start(queue: connectionQueue)
    }

    nonisolated private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }

            Task {
                let response = self.response(for: RTSPRequest.parse(from: data, error: error, connection: connection))
                guard await self.send(response.data, on: connection) == nil else {
                    connection.cancel()
                    return
                }

                guard response.keepConnectionOpen else {
                    connection.cancel()
                    return
                }

                self.receiveRequest(on: connection)
            }
        }
    }

    nonisolated private func response(for request: RTSPRequest?) -> RTSPResponse {
        guard let request else {
            let body = Data("Invalid RTSP request.".utf8)
            return RTSPResponse(
                data: Self.messageResponse(
                    status: "400 Bad Request",
                    cSeq: nil,
                    body: body,
                    contentType: "text/plain; charset=utf-8"
                ),
                keepConnectionOpen: false
            )
        }

        guard Self.isSupportedStreamPath(request.path) else {
            let body = Data("RTSP stream not found.".utf8)
            return RTSPResponse(
                data: Self.messageResponse(
                    status: "404 Not Found",
                    cSeq: request.cSeq,
                    body: body,
                    contentType: "text/plain; charset=utf-8"
                ),
                keepConnectionOpen: false
            )
        }

        guard isAuthorized(request) else {
            return unauthorizedResponse(cSeq: request.cSeq)
        }

        switch request.method {
        case "OPTIONS":
            return RTSPResponse(
                data: Self.headerResponse(
                    status: "200 OK",
                    cSeq: request.cSeq,
                    headers: [
                        "Public": Self.supportedMethods,
                        "Server": appName()
                    ]
                ),
                keepConnectionOpen: true
            )
        case "DESCRIBE":
            let streamURL = streamURLString()
            let body = Data(Self.sdpDescription(appName: appName(), streamURL: streamURL, parameterSets: currentParameterSets()).utf8)
            return RTSPResponse(
                data: Self.messageResponse(
                    status: "200 OK",
                    cSeq: request.cSeq,
                    headers: [
                        "Content-Base": "\(streamURL)/",
                        "Content-Location": streamURL,
                        "Server": appName()
                    ],
                    body: body,
                    contentType: "application/sdp"
                ),
                keepConnectionOpen: true
            )
        case "SETUP":
            guard let transportHeader = request.headers["transport"],
                  let transport = RTSPTransport(headerValue: transportHeader) else {
                let body = Data("Only RTP/AVP/TCP interleaved transport is supported.".utf8)
                return RTSPResponse(
                    data: Self.messageResponse(
                        status: "461 Unsupported Transport",
                        cSeq: request.cSeq,
                        headers: ["Public": Self.supportedMethods],
                        body: body,
                        contentType: "text/plain; charset=utf-8"
                    ),
                    keepConnectionOpen: false
                )
            }

            stateLock.lock()
            defer { stateLock.unlock() }

            if let activeSession, activeSession.connectionID != request.connectionID {
                let body = Data("Only one RTSP client is supported at a time.".utf8)
                return RTSPResponse(
                    data: Self.messageResponse(
                        status: "453 Not Enough Bandwidth",
                        cSeq: request.cSeq,
                        headers: ["Public": Self.supportedMethods],
                        body: body,
                        contentType: "text/plain; charset=utf-8"
                    ),
                    keepConnectionOpen: false
                )
            }

            let streamURL = streamURLString()
            let sessionID = activeSession?.id ?? Self.randomSessionIdentifier()
            let streamState = RTSPSessionState(
                id: sessionID,
                connectionID: request.connectionID,
                transport: transport,
                sequenceNumber: activeSession?.sequenceNumber ?? UInt16.random(in: 1...UInt16.max),
                ssrc: activeSession?.ssrc ?? UInt32.random(in: 1...UInt32.max),
                timestampBase: activeSession?.timestampBase ?? UInt32.random(in: 1...UInt32.max),
                streamStartPTS: activeSession?.streamStartPTS,
                isPlaying: false
            )

            activeSession = streamState
            activeConnection = request.connection

            return RTSPResponse(
                data: Self.headerResponse(
                    status: "200 OK",
                    cSeq: request.cSeq,
                    headers: [
                        "Server": appName(),
                        "Session": "\(sessionID);timeout=60",
                        "Transport": transport.responseHeaderValue(ssrc: streamState.ssrc),
                        "RTP-Info": "url=\(streamURL)"
                    ]
                ),
                keepConnectionOpen: true
            )
        case "PLAY":
            stateLock.lock()
            guard var streamState = activeSession,
                  streamState.connectionID == request.connectionID,
                  Self.normalizedSessionIdentifier(from: request.headers["session"]) == streamState.id else {
                stateLock.unlock()
                let body = Data("RTSP session was not found. Send SETUP first.".utf8)
                return RTSPResponse(
                    data: Self.messageResponse(
                        status: "454 Session Not Found",
                        cSeq: request.cSeq,
                        headers: ["Public": Self.supportedMethods],
                        body: body,
                        contentType: "text/plain; charset=utf-8"
                    ),
                    keepConnectionOpen: false
                )
            }

            streamState.isPlaying = true
            if streamState.streamStartPTS == nil {
                streamState.streamStartPTS = .invalid
            }
            activeSession = streamState
            stateLock.unlock()

            let streamURL = streamURLString()
            return RTSPResponse(
                data: Self.headerResponse(
                    status: "200 OK",
                    cSeq: request.cSeq,
                    headers: [
                        "Server": appName(),
                        "Session": "\(streamState.id);timeout=60",
                        "RTP-Info": "url=\(streamURL);seq=\(streamState.sequenceNumber);rtptime=\(streamState.timestampBase)"
                    ]
                ),
                keepConnectionOpen: true
            )
        case "PAUSE":
            stateLock.lock()
            guard var streamState = activeSession,
                  streamState.connectionID == request.connectionID,
                  Self.normalizedSessionIdentifier(from: request.headers["session"]) == streamState.id else {
                stateLock.unlock()
                let body = Data("RTSP session was not found.".utf8)
                return RTSPResponse(
                    data: Self.messageResponse(
                        status: "454 Session Not Found",
                        cSeq: request.cSeq,
                        headers: ["Public": Self.supportedMethods],
                        body: body,
                        contentType: "text/plain; charset=utf-8"
                    ),
                    keepConnectionOpen: false
                )
            }

            streamState.isPlaying = false
            activeSession = streamState
            stateLock.unlock()

            return RTSPResponse(
                data: Self.headerResponse(
                    status: "200 OK",
                    cSeq: request.cSeq,
                    headers: [
                        "Server": appName(),
                        "Session": "\(streamState.id);timeout=60"
                    ]
                ),
                keepConnectionOpen: true
            )
        case "TEARDOWN":
            stateLock.lock()
            if let streamState = activeSession,
               streamState.connectionID == request.connectionID,
               Self.normalizedSessionIdentifier(from: request.headers["session"]) == streamState.id {
                activeSession = nil
                activeConnection = nil
            }
            stateLock.unlock()

            Task { @MainActor [weak self] in
                self?.encoder.reset()
            }

            return RTSPResponse(
                data: Self.headerResponse(
                    status: "200 OK",
                    cSeq: request.cSeq,
                    headers: ["Server": appName()]
                ),
                keepConnectionOpen: false
            )
        default:
            let body = Data("Supported RTSP methods: \(Self.supportedMethods).".utf8)
            return RTSPResponse(
                data: Self.messageResponse(
                    status: "405 Method Not Allowed",
                    cSeq: request.cSeq,
                    headers: ["Public": Self.supportedMethods],
                    body: body,
                    contentType: "text/plain; charset=utf-8"
                ),
                keepConnectionOpen: false
            )
        }
    }

    private func bonjourServiceName() -> String {
        let deviceName = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(appName()) on \(deviceName)"
    }

    nonisolated private func isAuthorized(_ request: RTSPRequest) -> Bool {
        authenticationProvider().authorizes(headerValue: request.headers["authorization"])
    }

    nonisolated private func unauthorizedResponse(cSeq: String?) -> RTSPResponse {
        let body = Data("Authentication is required.".utf8)
        return RTSPResponse(
            data: Self.messageResponse(
                status: "401 Unauthorized",
                cSeq: cSeq,
                headers: [
                    "Server": appName(),
                    "WWW-Authenticate": "Basic realm=\"experiment-camera\", charset=\"UTF-8\""
                ],
                body: body,
                contentType: "text/plain; charset=utf-8"
            ),
            keepConnectionOpen: true
        )
    }

    private func bonjourTXTRecord() -> Data {
        NetService.data(fromTXTRecord: [
            "path": Data(Self.streamPath.utf8),
            "format": Data("rtsp".utf8),
            "transport": Data("RTP/AVP/TCP".utf8)
        ])
    }

    nonisolated private func appName() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "experiment-camera"
    }

    nonisolated private var isSessionPlaying: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeSession?.isPlaying == true
    }

    nonisolated private func currentParameterSets() -> H264ParameterSets? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return latestParameterSets
    }

    nonisolated private func clearSessionIfNeeded(for connection: NWConnection) {
        stateLock.lock()
        if activeSession?.connectionID == ObjectIdentifier(connection),
           activeConnection === connection {
            activeSession = nil
            activeConnection = nil
            stateLock.unlock()
            Task { @MainActor [weak self] in
                self?.encoder.reset()
            }
            return
        }

        stateLock.unlock()
    }

    nonisolated private func sendEncodedAccessUnit(_ accessUnit: EncodedH264AccessUnit) {
        stateLock.lock()
        guard var streamState = activeSession,
              streamState.isPlaying,
              let connection = activeConnection else {
            stateLock.unlock()
            return
        }

        if let parameterSets = accessUnit.parameterSets {
            latestParameterSets = parameterSets
        }

        if streamState.streamStartPTS == nil || streamState.streamStartPTS == .invalid {
            streamState.streamStartPTS = accessUnit.presentationTimeStamp
        }

        let packetizationPayloads = self.packetizationPayloads(for: accessUnit)
        let transport = streamState.transport
        activeSession = streamState
        stateLock.unlock()

        for (payload, marker) in packetizationPayloads {
            let packets = Self.rtpPackets(
                payload: payload,
                marker: marker,
                timestamp: streamState.rtpTimestamp(for: accessUnit.presentationTimeStamp),
                sequenceNumber: &streamState.sequenceNumber,
                ssrc: streamState.ssrc
            )

            for packet in packets {
                let framedPacket = Self.interleavedData(channel: transport.rtpChannel, payload: packet)
                connection.send(content: framedPacket, completion: .contentProcessed { [weak self, weak connection] error in
                    guard let self else {
                        return
                    }

                    guard error == nil else {
                        if let connection {
                            self.clearSessionIfNeeded(for: connection)
                            connection.cancel()
                        }
                        return
                    }
                })
            }
        }

        stateLock.lock()
        if activeSession?.id == streamState.id {
            activeSession?.sequenceNumber = streamState.sequenceNumber
        }
        stateLock.unlock()
    }

    nonisolated private func packetizationPayloads(for accessUnit: EncodedH264AccessUnit) -> [(Data, Bool)] {
        var payloads: [(Data, Bool)] = []

        if accessUnit.isKeyframe,
           let parameterSets = accessUnit.parameterSets ?? currentParameterSets(),
           let stapA = Self.stapAParameterSetNALU(from: parameterSets) {
            payloads.append((stapA, false))
        }

        for (index, nalUnit) in accessUnit.nalUnits.enumerated() {
            payloads.append((nalUnit, index == accessUnit.nalUnits.count - 1))
        }

        return payloads
    }

    nonisolated private func streamURLString() -> String {
        let ipAddress = DeviceIPAddressProvider.currentIPAddress() ?? "0.0.0.0"
        let host = ipAddress.contains(":") ? "[\(ipAddress)]" : ipAddress
        return "rtsp://\(host):\(port.rawValue)\(Self.streamPath)"
    }

    nonisolated private func send(_ data: Data, on connection: NWConnection) async -> NWError? {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error)
            })
        }
    }

    nonisolated static func sdpDescription(appName: String, streamURL: String) -> String {
        sdpDescription(appName: appName, streamURL: streamURL, parameterSets: nil)
    }

    nonisolated private static func sdpDescription(appName: String, streamURL: String, parameterSets: H264ParameterSets?) -> String {
        let lines = [
            "v=0",
            "o=- 0 0 IN IP4 0.0.0.0",
            "s=\(appName)",
            "t=0 0",
            "a=control:*",
            "m=video 0 RTP/AVP 96",
            "a=rtpmap:96 H264/90000",
            "a=fmtp:96 packetization-mode=1\(parameterSets?.fmtpAttributeSuffix ?? "")",
            "a=control:trackID=0",
            "a=x-stream-url:\(streamURL)"
        ]

        return lines.joined(separator: "\r\n") + "\r\n"
    }

    nonisolated private static func interleavedData(channel: UInt8, payload: Data) -> Data {
        var framed = Data()
        framed.append(0x24)
        framed.append(channel)

        let length = UInt16(min(payload.count, Int(UInt16.max))).bigEndian
        withUnsafeBytes(of: length) { framed.append(contentsOf: $0) }
        framed.append(payload)
        return framed
    }

    nonisolated private static func stapAParameterSetNALU(from parameterSets: H264ParameterSets) -> Data? {
        guard parameterSets.sps.count <= UInt16.max,
              parameterSets.pps.count <= UInt16.max else {
            return nil
        }

        var payload = Data([24])
        var spsLength = UInt16(parameterSets.sps.count).bigEndian
        var ppsLength = UInt16(parameterSets.pps.count).bigEndian
        withUnsafeBytes(of: &spsLength) { payload.append(contentsOf: $0) }
        payload.append(parameterSets.sps)
        withUnsafeBytes(of: &ppsLength) { payload.append(contentsOf: $0) }
        payload.append(parameterSets.pps)
        return payload
    }

    nonisolated private static func rtpPackets(
        payload: Data,
        marker: Bool,
        timestamp: UInt32,
        sequenceNumber: inout UInt16,
        ssrc: UInt32
    ) -> [Data] {
        let maxPayloadSize = 1_200
        guard payload.count > maxPayloadSize else {
            let packet = rtpPacket(payload: payload, marker: marker, sequenceNumber: sequenceNumber, timestamp: timestamp, ssrc: ssrc)
            sequenceNumber &+= 1
            return [packet]
        }

        guard let firstByte = payload.first else {
            return []
        }

        let nri = firstByte & 0x60
        let nalType = firstByte & 0x1F
        let fuIndicator = nri | 28
        let fragmentPayloadSize = maxPayloadSize - 2
        var packets: [Data] = []
        var offset = 1

        while offset < payload.count {
            let bytesRemaining = payload.count - offset
            let fragmentSize = min(fragmentPayloadSize, bytesRemaining)
            let isFirst = offset == 1
            let isLast = offset + fragmentSize >= payload.count
            let fuHeader: UInt8 = (isFirst ? 0x80 : 0x00) | (isLast ? 0x40 : 0x00) | nalType

            var fragment = Data([fuIndicator, fuHeader])
            fragment.append(payload.subdata(in: offset..<(offset + fragmentSize)))

            let packet = rtpPacket(
                payload: fragment,
                marker: marker && isLast,
                sequenceNumber: sequenceNumber,
                timestamp: timestamp,
                ssrc: ssrc
            )
            packets.append(packet)
            sequenceNumber &+= 1
            offset += fragmentSize
        }

        return packets
    }

    nonisolated private static func rtpPacket(payload: Data, marker: Bool, sequenceNumber: UInt16, timestamp: UInt32, ssrc: UInt32) -> Data {
        var packet = Data(capacity: payload.count + 12)
        packet.append(0x80)
        packet.append((marker ? 0x80 : 0x00) | 96)

        var sequence = sequenceNumber.bigEndian
        var ts = timestamp.bigEndian
        var streamID = ssrc.bigEndian

        withUnsafeBytes(of: &sequence) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &ts) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &streamID) { packet.append(contentsOf: $0) }
        packet.append(payload)
        return packet
    }

    nonisolated private static func normalizedSessionIdentifier(from value: String?) -> String? {
        guard let value else {
            return nil
        }

        return value
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    nonisolated private static func randomSessionIdentifier() -> String {
        String(UInt32.random(in: 1...UInt32.max))
    }

    nonisolated private static func isSupportedStreamPath(_ path: String) -> Bool {
        if path == streamPath {
            return true
        }

        if path == "\(streamPath)/trackID=0" || path == "\(streamPath)/streamid=0" {
            return true
        }

        return false
    }

    nonisolated private static func messageResponse(
        status: String,
        cSeq: String?,
        headers: [String: String] = [:],
        body: Data,
        contentType: String
    ) -> Data {
        var mergedHeaders = headers
        mergedHeaders["Content-Length"] = "\(body.count)"
        mergedHeaders["Content-Type"] = contentType

        var responseData = headerResponse(status: status, cSeq: cSeq, headers: mergedHeaders)
        responseData.append(body)
        return responseData
    }

    nonisolated private static func headerResponse(
        status: String,
        cSeq: String?,
        headers: [String: String] = [:]
    ) -> Data {
        var lines = ["RTSP/1.0 \(status)"]

        if let cSeq {
            lines.append("CSeq: \(cSeq)")
        }

        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            lines.append("\(name): \(value)")
        }

        lines.append("")
        lines.append("")
        return Data(lines.joined(separator: "\r\n").utf8)
    }
}

private struct RTSPSessionState {
    let id: String
    let connectionID: ObjectIdentifier
    let transport: RTSPTransport
    var sequenceNumber: UInt16
    let ssrc: UInt32
    let timestampBase: UInt32
    var streamStartPTS: CMTime?
    var isPlaying: Bool

    nonisolated func rtpTimestamp(for pts: CMTime) -> UInt32 {
        guard let streamStartPTS,
              streamStartPTS != .invalid,
              pts.isNumeric,
              streamStartPTS.isNumeric else {
            return timestampBase
        }

        let elapsed = max(CMTimeGetSeconds(pts) - CMTimeGetSeconds(streamStartPTS), 0)
        return timestampBase &+ UInt32((elapsed * 90_000).rounded())
    }
}

private struct RTSPTransport {
    let rtpChannel: UInt8
    let rtcpChannel: UInt8

    nonisolated init?(headerValue: String) {
        let components = headerValue
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        guard components.contains("rtp/avp/tcp") else {
            return nil
        }

        if let interleavedPart = components.first(where: { $0.hasPrefix("interleaved=") }) {
            let pair = interleavedPart.replacingOccurrences(of: "interleaved=", with: "")
            let values = pair.split(separator: "-")
            guard values.count == 2,
                  let rtp = UInt8(values[0]),
                  let rtcp = UInt8(values[1]) else {
                return nil
            }

            rtpChannel = rtp
            rtcpChannel = rtcp
        } else {
            rtpChannel = 0
            rtcpChannel = 1
        }
    }

    nonisolated func responseHeaderValue(ssrc: UInt32) -> String {
        "RTP/AVP/TCP;unicast;interleaved=\(rtpChannel)-\(rtcpChannel);ssrc=\(String(format: "%08X", ssrc));mode=\"PLAY\""
    }
}

private struct H264ParameterSets {
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

private struct EncodedH264AccessUnit {
    let presentationTimeStamp: CMTime
    let nalUnits: [Data]
    let isKeyframe: Bool
    let parameterSets: H264ParameterSets?
}

private struct UnsafeSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer
}

private final class H264VideoEncoder {
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

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
    let omitBody: Bool

    var trimmedBody: String? {
        guard let string = String(data: body, encoding: .utf8) else {
            return nil
        }

        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private enum HTTPRequestParseResult {
    case request(HTTPRequest)
    case incomplete
    case invalid
}

struct RTSPRequest {
    let method: String
    let path: String
    let version: String
    let headers: [String: String]
    let connection: NWConnection

    nonisolated var cSeq: String? {
        headers["cseq"]
    }

    nonisolated var connectionID: ObjectIdentifier {
        ObjectIdentifier(connection)
    }

    nonisolated static func parse(from requestData: Data?, error: NWError?, connection: NWConnection) -> RTSPRequest? {
        guard error == nil,
              let requestData,
              let request = String(data: requestData, encoding: .utf8),
              let headerDelimiterRange = request.range(of: "\r\n\r\n") else {
            return nil
        }

        let headerBlock = String(request[..<headerDelimiterRange.lowerBound])
        let lines = headerBlock.components(separatedBy: "\r\n")

        guard let requestLine = lines.first, !requestLine.isEmpty else {
            return nil
        }

        let components = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard components.count >= 3 else {
            return nil
        }

        let method = String(components[0]).uppercased()
        let target = String(components[1])
        let version = String(components[2]).uppercased()
        guard version.hasPrefix("RTSP/") else {
            return nil
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                continue
            }

            let name = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        return RTSPRequest(
            method: method,
            path: normalizedPath(from: target),
            version: version,
            headers: headers,
            connection: connection
        )
    }

    nonisolated private static func normalizedPath(from target: String) -> String {
        if let url = URL(string: target), let scheme = url.scheme?.lowercased(), scheme == "rtsp" {
            return url.path.isEmpty ? "/" : url.path
        }

        let rawPath = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)
            ?? target
        return rawPath.isEmpty ? "/" : rawPath
    }
}

private struct RTSPResponse {
    let data: Data
    let keepConnectionOpen: Bool
}

private enum MJPEGFrameIdentity: Equatable {
    case placeholder(MJPEGPlaceholderStyle)
    case latestImage(path: String, modificationTimeIntervalSinceReferenceDate: TimeInterval)
}

private enum MJPEGFrameUpdate {
    case noChange
    case frame(identity: MJPEGFrameIdentity, imageData: Data)
}

private enum MJPEGPlaceholderStyle: Equatable {
    case waitingForFirstImage
    case cameraOff
}

enum DeviceIPAddressProvider {
    private enum InterfacePreference: Int {
        case wifiIPv4 = 0
        case wifiIPv6 = 1
        case cellularIPv4 = 2
        case cellularIPv6 = 3
        case otherIPv4 = 4
        case otherIPv6 = 5
    }

    nonisolated static func currentIPAddress() -> String? {
        var interfacePointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfacePointer) == 0, let firstInterface = interfacePointer else {
            return nil
        }

        defer { freeifaddrs(interfacePointer) }

        var current = firstInterface
        var candidates: [(priority: Int, address: String)] = []

        while true {
            let interface = current.pointee
            let flags = Int32(interface.ifa_flags)

            guard let socketAddress = interface.ifa_addr else {
                if let next = interface.ifa_next {
                    current = next
                    continue
                }

                break
            }

            let family = socketAddress.pointee.sa_family
            let isIPv4 = family == UInt8(AF_INET)
            let isIPv6 = family == UInt8(AF_INET6)

            guard (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  isIPv4 || isIPv6 else {
                if let next = interface.ifa_next {
                    current = next
                    continue
                }

                break
            }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            guard result == 0 else {
                if let next = interface.ifa_next {
                    current = next
                    continue
                }

                break
            }

            let address = String(cString: hostname)
            if isIPv6 && address.lowercased().hasPrefix("fe80") {
                if let next = interface.ifa_next {
                    current = next
                    continue
                }

                break
            }

            let interfaceName = String(cString: interface.ifa_name)
            if let preference = preference(for: interfaceName, isIPv4: isIPv4) {
                candidates.append((priority: preference.rawValue, address: address))
            }

            guard let next = interface.ifa_next else {
                break
            }

            current = next
        }

        return candidates.min(by: { $0.priority < $1.priority })?.address
    }

    nonisolated private static func preference(for interfaceName: String, isIPv4: Bool) -> InterfacePreference? {
        switch interfaceName {
        case "en0":
            return isIPv4 ? .wifiIPv4 : .wifiIPv6
        case "pdp_ip0":
            return isIPv4 ? .cellularIPv4 : .cellularIPv6
        default:
            return isIPv4 ? .otherIPv4 : .otherIPv6
        }
    }
}

enum LatestCaptureFileLocator {
    struct ImageFile {
        let url: URL
        let modificationDate: Date
    }

    static func latestImageURL() throws -> URL? {
        try latestImageFile()?.url
    }

    static func latestImageFile() throws -> ImageFile? {
        let capturesDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Captures", isDirectory: true)

        guard FileManager.default.fileExists(atPath: capturesDirectory.path) else {
            return nil
        }

        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey, .isRegularFileKey]
        let candidateFiles = try FileManager.default.contentsOfDirectory(
            at: capturesDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        return try candidateFiles
            .filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .compactMap { fileURL -> ImageFile? in
                let resourceValues = try fileURL.resourceValues(forKeys: keys)
                guard resourceValues.isRegularFile == true else {
                    return nil
                }

                let timestamp = resourceValues.contentModificationDate ?? resourceValues.creationDate ?? .distantPast
                return ImageFile(url: fileURL, modificationDate: timestamp)
            }
            .max(by: { $0.modificationDate < $1.modificationDate })
    }
}
