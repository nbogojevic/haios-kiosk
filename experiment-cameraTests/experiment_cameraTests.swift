//
//  experiment_cameraTests.swift
//  experiment-cameraTests
//
//  Created by Nenad BOGOJEVIC on 19/06/2026.
//

import Foundation
import Testing
@testable import experiment_camera

struct experiment_cameraTests {
    @Test func pruneCapturedImagesKeepsNewestTenJPEGs() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let baseDate = Date(timeIntervalSinceReferenceDate: 10_000)

        for index in 0..<12 {
            let fileURL = temporaryDirectory.appendingPathComponent("frame-\(index).jpg")
            try Data("image-\(index)".utf8).write(to: fileURL)
            try FileManager.default.setAttributes(
                [.modificationDate: baseDate.addingTimeInterval(TimeInterval(index))],
                ofItemAtPath: fileURL.path
            )
        }

        let noteURL = temporaryDirectory.appendingPathComponent("ignore.txt")
        try Data("note".utf8).write(to: noteURL)

        let removedFiles = try CaptureRetentionPolicy.pruneCapturedImages(in: temporaryDirectory)
        let remainingFileNames = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path).sorted()

        #expect(removedFiles.count == 2)
        #expect(removedFiles.map(\.lastPathComponent).sorted() == ["frame-0.jpg", "frame-1.jpg"])
        #expect(remainingFileNames.count == 11)
        #expect(remainingFileNames.contains("ignore.txt"))
        #expect(!remainingFileNames.contains("frame-0.jpg"))
        #expect(!remainingFileNames.contains("frame-1.jpg"))
        #expect(remainingFileNames.contains("frame-11.jpg"))
    }

    @Test func pruneCapturedImagesReturnsEmptyWhenDirectoryDoesNotExist() throws {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let removedFiles = try CaptureRetentionPolicy.pruneCapturedImages(in: missingDirectory)

        #expect(removedFiles.isEmpty)
    }
}
