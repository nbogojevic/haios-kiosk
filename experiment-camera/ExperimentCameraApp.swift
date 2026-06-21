//
//  ExperimentCameraApp.swift
//  experiment-camera
//
//  Created by Nenad BOGOJEVIC on 19/06/2026.
//

import SwiftUI
import SwiftData

@main
struct ExperimentCameraApp: App {
    private static let uiTestSeedCaptureItemArgument = "-uiTestSeedCaptureItem"
    @State private var showSplashScreen = true

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let isUITestSeededContainer = ProcessInfo.processInfo.arguments.contains(uiTestSeedCaptureItemArgument)
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: isUITestSeededContainer)

        do {
            let modelContainer = try ModelContainer(for: schema, configurations: [modelConfiguration])

            if isUITestSeededContainer {
                let modelContext = ModelContext(modelContainer)
                modelContext.insert(Item(
                    timestamp: Date(timeIntervalSince1970: 1_719_000_000),
                    imagePath: uiTestSeedImagePath
                ))
                try? modelContext.save()
            }

            return modelContainer
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ZStack {
                if showSplashScreen {
                    SplashScreenView()
                        .transition(.opacity)
                } else {
                    ContentView()
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        showSplashScreen = false
                    }
                }
            }
        }
        .modelContainer(sharedModelContainer)
    }

    private static var uiTestSeedImagePath: String? {
        let capturesDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Captures", isDirectory: true)
        let imageURL = capturesDirectory.appendingPathComponent("ui-test-seed.png")

        do {
            try FileManager.default.createDirectory(at: capturesDirectory, withIntermediateDirectories: true)

            if !FileManager.default.fileExists(atPath: imageURL.path),
               let imageData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9WlH0xQAAAAASUVORK5CYII=") {
                try imageData.write(to: imageURL, options: .atomic)
            }

            return imageURL.path
        } catch {
            return nil
        }
    }
}
