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
                modelContext.insert(Item(timestamp: Date(timeIntervalSince1970: 1_719_000_000)))
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
}
