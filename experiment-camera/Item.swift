//
//  Item.swift
//  experiment-camera
//
//  Created by Nenad BOGOJEVIC on 19/06/2026.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    var imagePath: String?

    init(timestamp: Date, imagePath: String? = nil) {
        self.timestamp = timestamp
        self.imagePath = imagePath
    }
}
