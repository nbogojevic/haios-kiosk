//
//  RTSPServer.swift
//  experiment-camera
//
//  Split from CameraCaptureNetworking.swift.
//

import Foundation
import Network
import UIKit
@preconcurrency import AVFoundation

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
