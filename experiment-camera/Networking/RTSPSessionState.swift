//
//  RTSPSessionState.swift
//  experiment-camera
//
//  Split from RTSPServer.swift.
//

@preconcurrency import AVFoundation

struct RTSPSessionState {
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
