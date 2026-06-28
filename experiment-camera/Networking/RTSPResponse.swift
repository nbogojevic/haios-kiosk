//
//  RTSPResponse.swift
//  experiment-camera
//
//  Split from RTSPServer.swift.
//

import Foundation

struct RTSPResponse {
    let data: Data
    let keepConnectionOpen: Bool
}
