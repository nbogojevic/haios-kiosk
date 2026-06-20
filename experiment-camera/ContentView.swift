//
//  ContentView.swift
//  experiment-camera
//
//  Created by Nenad BOGOJEVIC on 19/06/2026.
//

import SwiftUI
import SwiftData
import UIKit

struct ContentView: View {
    @AppStorage("captureIntervalSeconds") private var captureIntervalSeconds = 10
    @AppStorage(CaptureRetentionPolicy.storageKey) private var maxRetainedImages = CaptureRetentionPolicy.defaultMaxRetainedImages
    @AppStorage("startCameraOnLaunch") private var startCameraOnLaunch = false
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var cameraService = CameraCaptureService()
    @State private var showingSettings = false
    @State private var didConfigureInitialState = false

    var body: some View {
        NavigationStack {
            homeView
                .navigationTitle("Home")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showingSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }

                    ToolbarItemGroup(placement: .topBarTrailing) {
                        NavigationLink {
                            CameraControlView(cameraService: cameraService)
                        } label: {
                            Image(systemName: "camera")
                        }
                        .accessibilityLabel("Open camera controls")

                        NavigationLink {
                            CapturesView()
                        } label: {
                            Image(systemName: "photo")
                        }
                        .accessibilityLabel("Open captures")
                    }
                }
        }
        .onAppear {
            if !didConfigureInitialState {
                didConfigureInitialState = true

                cameraService.setCaptureInterval(seconds: captureIntervalSeconds)
                pruneStoredCaptures(keepingNewest: maxRetainedImages)
                cameraService.setCaptureHandler { timestamp, imagePath in
                    withAnimation {
                        insertCapturedItem(timestamp: timestamp, imagePath: imagePath)
                    }
                }

                if startCameraOnLaunch {
                    Task {
                        await cameraService.start()
                    }
                }
            }
        }
        .onChange(of: captureIntervalSeconds) { _, newValue in
            cameraService.setCaptureInterval(seconds: newValue)
        }
        .onChange(of: maxRetainedImages) { _, newValue in
            withAnimation {
                pruneStoredCaptures(keepingNewest: newValue)
            }
        }
        .onDisappear {
            cameraService.clearCaptureHandler()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                Task {
                    await cameraService.resumeIfNeeded()
                }
            case .inactive, .background:
                cameraService.pause()
            @unknown default:
                cameraService.pause()
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(
                captureIntervalSeconds: $captureIntervalSeconds,
                maxRetainedImages: $maxRetainedImages,
                startCameraOnLaunch: $startCameraOnLaunch
            )
        }
    }

    private var homeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                NavigationLink {
                    CameraControlView(cameraService: cameraService)
                } label: {
                    HomeNavigationCardView(title: "Camera controls", systemImage: "camera") {
                        Text("Open the camera screen to start or stop capture, review status, and monitor the latest capture time.")
                            .font(.body)
                            .foregroundStyle(.secondary)

                        Text(startCameraOnLaunch ? "The camera is set to start automatically when the app launches." : "The camera is currently set to remain off when the app launches.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                NavigationLink {
                    CapturesView()
                } label: {
                    HomeNavigationCardView(title: "Saved captures", systemImage: "photo.on.rectangle") {
                        Text("Open your saved captures to review individual photos or delete old entries.")
                            .font(.body)
                            .foregroundStyle(.secondary)

                        if let lastCaptureDate = cameraService.lastCaptureDate {
                            Text("Most recent capture: \(lastCaptureDate.formatted(date: .abbreviated, time: .standard))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func insertCapturedItem(timestamp: Date, imagePath: String) {
        modelContext.insert(Item(timestamp: timestamp, imagePath: imagePath))
        pruneStoredCaptures(keepingNewest: maxRetainedImages)
    }

    private func pruneStoredCaptures(keepingNewest limit: Int) {
        let retainedItemCount = max(limit, 0)
        let descriptor = FetchDescriptor<Item>(sortBy: [SortDescriptor(\Item.timestamp, order: .reverse)])

        guard let storedItems = try? modelContext.fetch(descriptor), storedItems.count > retainedItemCount else {
            return
        }

        for item in storedItems.dropFirst(retainedItemCount) {
            if let imagePath = item.imagePath {
                try? FileManager.default.removeItem(atPath: imagePath)
            }

            modelContext.delete(item)
        }
    }

}

private struct HomeNavigationCardView<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Label(title, systemImage: systemImage)
                    .font(.headline)

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct CameraControlView: View {
    @ObservedObject var cameraService: CameraCaptureService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                CameraStatusCardView(cameraService: cameraService)

                VStack(alignment: .leading, spacing: 12) {
                    Label("Capture behavior", systemImage: "timer")
                        .font(.headline)

                    Text("Use the button below to start or stop periodic front-camera captures. The camera keeps using the interval selected in Settings.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Camera")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button(action: toggleCamera) {
                Label(cameraService.buttonTitle, systemImage: cameraService.buttonIconName)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(cameraService.isRunning ? .red : .accentColor)
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom)
            .background(.bar)
        }
    }

    private func toggleCamera() {
        if cameraService.wantsToRun {
            cameraService.stop()
        } else {
            Task {
                await cameraService.start()
            }
        }
    }
}

private struct CameraStatusCardView: View {
    @ObservedObject var cameraService: CameraCaptureService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(cameraService.statusTitle)
                .font(.headline)

            Text(cameraService.statusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let lastCaptureDate = cameraService.lastCaptureDate {
                Text("Last capture: \(lastCaptureDate.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct CapturesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Item.timestamp, order: .reverse) private var items: [Item]
    @State private var showingDeleteImagesConfirmation = false

    var body: some View {
        List {
            ForEach(items) { item in
                NavigationLink {
                    ItemDetailView(item: item)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))

                        if item.imagePath != nil {
                            Label("Captured image", systemImage: "photo")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .onDelete(perform: deleteItems)
        }
        .navigationTitle("Captures")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showingDeleteImagesConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete all captures")
                .disabled(!hasSavedImages)
            }
        }
        .confirmationDialog(
            "Delete all saved images?",
            isPresented: $showingDeleteImagesConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All Images", role: .destructive, action: deleteAllImages)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every saved camera image from disk and deletes all entries, including those without images.")
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(
                    "No Captures Yet",
                    systemImage: "photo",
                    description: Text("Return to the Camera screen with the back button, then start capture to save photos here.")
                )
            }
        }
    }

    private var hasSavedImages: Bool {
        !items.isEmpty || FileManager.default.fileExists(atPath: capturesDirectoryURL.path)
    }

    private var capturesDirectoryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Captures", isDirectory: true)
    }

    private func deleteItems(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                let item = items[index]

                if let imagePath = item.imagePath {
                    try? FileManager.default.removeItem(atPath: imagePath)
                }

                modelContext.delete(item)
            }
        }
    }

    private func deleteAllImages() {
        withAnimation {
            for item in items {
                if let imagePath = item.imagePath,
                   URL(fileURLWithPath: imagePath).deletingLastPathComponent() != capturesDirectoryURL {
                    try? FileManager.default.removeItem(atPath: imagePath)
                }

                modelContext.delete(item)
            }

            if FileManager.default.fileExists(atPath: capturesDirectoryURL.path) {
                try? FileManager.default.removeItem(at: capturesDirectoryURL)
            }
        }
    }
}

private struct SettingsView: View {
    @Binding var captureIntervalSeconds: Int
    @Binding var maxRetainedImages: Int
    @Binding var startCameraOnLaunch: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Start camera when app opens", isOn: $startCameraOnLaunch)
                } header: {
                    Text("Launch")
                } footer: {
                    Text("When enabled, the camera automatically starts when the app launches and resumes again after returning to the foreground.")
                }

                Section {
                    Stepper(value: $captureIntervalSeconds, in: 1...3600) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Seconds between photos")

                            Text(intervalDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Capture Interval")
                } footer: {
                    Text("Choose how often the front camera saves a new photo while capture is running.")
                }

                Section {
                    Stepper(value: $maxRetainedImages, in: 0...1000) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Maximum saved photos")

                            Text(retentionDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Choose how many of the newest photos to keep on disk. Lowering this value immediately removes older saved photos and their entries.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var intervalDescription: String {
        captureIntervalSeconds == 1 ? "1 second" : "\(captureIntervalSeconds) seconds"
    }

    private var retentionDescription: String {
        switch maxRetainedImages {
        case 0:
            "Keep no saved photos"
        case 1:
            "Keep 1 saved photo"
        default:
            "Keep \(maxRetainedImages) saved photos"
        }
    }
}

private struct ItemDetailView: View {
    let item: Item

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                } else {
                    ContentUnavailableView(
                        "No Image",
                        systemImage: "photo",
                        description: Text("This entry does not have a saved camera capture.")
                    )
                }

                Text(item.timestamp, format: Date.FormatStyle(date: .complete, time: .standard))
                    .font(.headline)

                if let imagePath = item.imagePath {
                    Text(imagePath)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding()
        }
        .navigationTitle("Capture")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var image: UIImage? {
        guard let imagePath = item.imagePath else {
            return nil
        }

        return UIImage(contentsOfFile: imagePath)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
