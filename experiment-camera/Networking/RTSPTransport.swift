//
//  RTSPTransport.swift
//  experiment-camera
//
//  Split from RTSPServer.swift.
//

import Foundation

struct RTSPTransport {
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
