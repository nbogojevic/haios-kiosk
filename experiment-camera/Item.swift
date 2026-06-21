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

extension Item {
    var resolvedImageURL: URL? {
        guard let imagePath, !imagePath.isEmpty else {
            return nil
        }

        let fileManager = FileManager.default

        // Support both plain file paths and previously persisted file:// URL strings.
        if let fileURL = URL(string: imagePath), fileURL.isFileURL,
           fileManager.fileExists(atPath: fileURL.path) {
            return fileURL
        }

        let pathURL = URL(fileURLWithPath: imagePath)
        if fileManager.fileExists(atPath: pathURL.path) {
            return pathURL
        }

        // If an old sandbox path was persisted, try restoring by filename in Documents/Captures.
        let fileName = (URL(string: imagePath)?.isFileURL == true ? URL(string: imagePath)?.lastPathComponent : nil)
            ?? pathURL.lastPathComponent
        guard !fileName.isEmpty else {
            return nil
        }

        let fallbackURL = Self.capturesDirectoryURL.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: fallbackURL.path) else {
            return nil
        }

        return fallbackURL
    }

    private static var capturesDirectoryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Captures", isDirectory: true)
    }
}
