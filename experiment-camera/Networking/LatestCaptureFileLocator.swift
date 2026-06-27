//
//  LatestCaptureFileLocator.swift
//  experiment-camera
//
//  Split from CameraCaptureNetworking.swift.
//

import Foundation

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
