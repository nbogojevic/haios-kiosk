//
//  RTSPRequest.swift
//  experiment-camera
//
//  Split from RTSPServer.swift.
//

import Foundation
import Network

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
