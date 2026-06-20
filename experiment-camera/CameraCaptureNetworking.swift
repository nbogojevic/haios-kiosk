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

struct DeviceInfoSnapshot: Encodable {
    struct BatteryInfo: Encodable {
        let state: String
        let percentageFull: Int?
        let isCharging: Bool
    }

    struct CameraInfo: Encodable {
        let isFilming: Bool
        let wantsToRun: Bool
        let status: String
        let captureIntervalSeconds: Int
        let captureCount: Int
        let lastCaptureAt: String?
        let hasCapturedImageSinceStart: Bool
        let errorMessage: String?
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
            errorMessage: "Camera status is unavailable."
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
                errorMessage: camera.errorMessage
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

final class LatestImageHTTPServer {
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
            print("Latest image HTTP server failed to start: \(error.localizedDescription)")
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

    private func handleNewConnection(_ connection: NWConnection) {
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

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, _, error in
            Task {
                guard let request = Self.parseRequest(from: data, error: error) else {
                    let response = Self.errorResponse(status: "400 Bad Request", message: "The request was empty.")
                    connection.send(content: response, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    return
                }

                if request.path == Self.cameraPath {
                    let response = await self?.cameraResponse(for: request)
                        ?? Self.errorResponse(status: "500 Internal Server Error", message: "The camera endpoint is unavailable.")

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
                    await self?.streamMJPEG(on: connection, omitBody: request.omitBody)
                    return
                }

                let response = await self?.responseData(path: request.path, omitBody: request.omitBody)
                    ?? Self.errorResponse(status: "500 Internal Server Error", message: "The server could not prepare a response.")

                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
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
                let part = Self.mjpegFrame(boundary: boundary, imageData: imageData)
                guard await send(part, on: connection) == nil else {
                    connection.cancel()
                    return
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

    nonisolated private static func parseRequest(from requestData: Data?, error: NWError?) -> HTTPRequest? {
        guard error == nil,
              let requestData,
              let request = String(data: requestData, encoding: .utf8),
              let headerDelimiterRange = request.range(of: "\r\n\r\n"),
              let requestLine = request.components(separatedBy: "\r\n").first,
              !requestLine.isEmpty else {
            return nil
        }

        let components = requestLine.split(separator: " ")
        guard components.count >= 2 else {
            return nil
        }

        let method = String(components[0]).uppercased()
        let rawPath = String(components[1])
        let path = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)
            ?? rawPath

        let bodyString = String(request[headerDelimiterRange.upperBound...])

        return HTTPRequest(
            method: method,
            path: path,
            body: Data(bodyString.utf8),
            omitBody: method == "HEAD"
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

    static func currentIPAddress() -> String? {
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

    private static func preference(for interfaceName: String, isIPv4: Bool) -> InterfacePreference? {
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
