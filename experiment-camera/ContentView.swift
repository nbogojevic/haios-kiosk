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
    @AppStorage("captureIntervalSeconds") private var captureIntervalSeconds = 1
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Item.timestamp, order: .reverse) private var items: [Item]
    @StateObject private var cameraService = CameraCaptureService()
    @State private var showingDeleteImagesConfirmation = false
    @State private var showingSettings = false

    var body: some View {
        NavigationSplitView {
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
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        showingDeleteImagesConfirmation = true
                    } label: {
                        Label("Delete Images", systemImage: "trash")
                    }
                    .disabled(!hasSavedImages)
                }
            }
        } detail: {
            Text("Select a capture")
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                cameraStatusView

                Button(action: toggleCamera) {
                    Label(cameraService.buttonTitle, systemImage: cameraService.buttonIconName)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(cameraService.isRunning ? .red : .accentColor)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom)
            .background(.bar)
        }
        .onAppear {
            cameraService.setCaptureInterval(seconds: captureIntervalSeconds)
            cameraService.setCaptureHandler { timestamp, imagePath in
                withAnimation {
                    modelContext.insert(Item(timestamp: timestamp, imagePath: imagePath))
                }
            }
        }
        .onChange(of: captureIntervalSeconds) { _, newValue in
            cameraService.setCaptureInterval(seconds: newValue)
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
            SettingsView(captureIntervalSeconds: $captureIntervalSeconds)
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
    }

    private var hasSavedImages: Bool {
        !items.isEmpty || FileManager.default.fileExists(atPath: capturesDirectoryURL.path)
    }

    private var capturesDirectoryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Captures", isDirectory: true)
    }

    @ViewBuilder
    private var cameraStatusView: some View {
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

private struct SettingsView: View {
    @Binding var captureIntervalSeconds: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
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
