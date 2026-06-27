//
//  ImageHTTPServer.swift
//  experiment-camera
//
//  Split from CameraCaptureNetworking.swift.
//

import Foundation
import Network
import UIKit

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
