//
//  ContentView.swift
//  experiment-camera
//
//  Created by Nenad BOGOJEVIC on 19/06/2026.
//

import SwiftUI
import SwiftData
import Combine
import UIKit

private enum AppDestination: Hashable {
    case web
    case camera
    case captures
}

struct ContentView: View {
    @AppStorage("captureIntervalSeconds") private var captureIntervalSeconds = 10
    @AppStorage(CaptureRetentionPolicy.storageKey) private var maxRetainedImages = CaptureRetentionPolicy.defaultMaxRetainedImages
    @AppStorage(CaptureRetentionPolicy.modeStorageKey) private var captureRetentionModeRawValue = CaptureRetentionPolicy.defaultMode.rawValue
    @AppStorage(CaptureRetentionPolicy.maxStorageMBStorageKey) private var maxRetainedImageStorageMB = CaptureRetentionPolicy.defaultMaxRetainedImageStorageMB
    @AppStorage("startCameraOnLaunch") private var startCameraOnLaunch = false
    @AppStorage(BrowserSession.startupURLStorageKey) private var startupURLString = BrowserSession.defaultStartupURLString
    @AppStorage(HTTPServerAuthentication.usernameStorageKey) private var httpServerUsername = HTTPServerAuthentication.defaultUsername
    @AppStorage(HTTPServerAuthentication.passwordStorageKey) private var httpServerPassword = HTTPServerAuthentication.defaultPassword
    @AppStorage(RTSPStreamResolutionScale.storageKey) private var rtspStreamResolutionScaleRawValue = RTSPStreamResolutionScale.defaultScale.rawValue

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var cameraService = CameraCaptureService()
    @StateObject private var browserSession = BrowserSession()
    @State private var showingSettings = false
    @State private var didConfigureInitialState = false
    @State private var navigationPath: [AppDestination] = []
    @State private var pruneTask: Task<Void, Never>?
    @State private var pendingCapturePruneCount = 0
    @State private var lastCapturePruneDate = Date.distantPast
    private let capturePruneDebounceDelay: Duration = .seconds(5)
    private let capturePruneMaximumDelay: TimeInterval = 60
    private let capturePruneCountThreshold = 10

    @AppStorage("screenSaverSeconds") private var screenSaverSeconds = 45
    @AppStorage("screenDimDelaySeconds") private var screenDimDelaySeconds = 30
    @AppStorage("screenDimBrightnessPercent") private var screenDimBrightnessPercent = 30
    @State private var isScreenSaverActive = false
    @State private var isScreenDimmed = false
    @State private var lastUserActivity = Date()
    @State private var screenSaverActivatedAt: Date?
    @State private var currentTime = Date()
    private let inactivityTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let screenSaverDriftAmplitude: CGFloat = 40
    private let screenSaverDriftCycleDuration: TimeInterval = 60 * 60

    var body: some View {
        ZStack {
            NavigationStack(path: $navigationPath) {
                homeView
                    .navigationTitle("Home")
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                registerUserActivity()
                                showingSettings = true
                            } label: {
                                Label("Settings", systemImage: "gearshape")
                            }
                        }

                        ToolbarItemGroup(placement: .topBarTrailing) {
                            Button {
                                registerUserActivity()
                                showDestination(.web)
                            } label: {
                                Image(systemName: "house")
                            }
                            .accessibilityLabel("Open web view")

                            Button {
                                registerUserActivity()
                                showDestination(.camera)
                            } label: {
                                Image(systemName: "camera")
                            }
                            .accessibilityLabel("Open camera controls")

                            Button {
                                registerUserActivity()
                                showDestination(.captures)
                            } label: {
                                Image(systemName: "photo")
                            }
                            .accessibilityLabel("Open captures")
                        }
                    }
                    .navigationDestination(for: AppDestination.self) { destination in
                        switch destination {
                        case .web:
                            WebBrowserView(
                                browserSession: browserSession,
                                openRootHome: navigateHome,
                                onUserActivity: registerUserActivity
                            )
                        case .camera:
                            CameraControlView(
                                cameraService: cameraService,
                                openWebView: openWebView,
                                onUserActivity: registerUserActivity
                            )
                        case .captures:
                            CapturesView(
                                openWebView: openWebView,
                                onUserActivity: registerUserActivity
                            )
                        }
                    }
            }

            if isScreenSaverActive {
                screenSaverView
            }
        }
        .onReceive(inactivityTimer) { _ in
            currentTime = Date()
            updateScreenSaverState()
        }
        .onAppear {
            currentTime = Date()
            lastUserActivity = Date()
            isScreenSaverActive = false
            isScreenDimmed = false
            screenSaverActivatedAt = nil
            updateIdleTimerState()
            cameraService.setCaptureHandler { timestamp, imagePath in
                withAnimation {
                    insertCapturedItem(timestamp: timestamp, imagePath: imagePath)
                }
            }

            if !didConfigureInitialState {
                didConfigureInitialState = true

                browserSession.loadInitialPageIfNeeded()
                cameraService.setCaptureInterval(seconds: captureIntervalSeconds)
                cameraService.setRTSPStreamResolutionScale(rtspStreamResolutionScale)
                pruneStoredCaptures()

                if startCameraOnLaunch {
                    Task {
                        await cameraService.start()
                    }
                }
            }
        }
        .onChange(of: cameraService.isRunning) { _, _ in
            updateIdleTimerState()
        }
        .onChange(of: captureIntervalSeconds) { _, newValue in
            cameraService.setCaptureInterval(seconds: newValue)
        }
        .onChange(of: rtspStreamResolutionScaleRawValue) { _, _ in
            cameraService.setRTSPStreamResolutionScale(rtspStreamResolutionScale)
        }
        .onChange(of: startupURLString) { _, _ in
            browserSession.loadInitialPageIfNeeded()
        }
        .onChange(of: maxRetainedImages) { _, _ in
            pruneStoredCaptures()
        }
        .onChange(of: captureRetentionModeRawValue) { _, _ in
            pruneStoredCaptures()
        }
        .onChange(of: maxRetainedImageStorageMB) { _, _ in
            pruneStoredCaptures()
        }
        .onDisappear {
            updateIdleTimerState(isIdleTimerDisabled: false)
            cameraService.clearCaptureHandler()
            pruneTask?.cancel()
            pruneTask = nil
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                registerUserActivity()
                Task {
                    await cameraService.resumeIfNeeded()
                }
                updateIdleTimerState()
            case .inactive:
                updateIdleTimerState()
            case .background:
                browserSession.persistCurrentURLIfNeeded()
                updateIdleTimerState(isIdleTimerDisabled: false)
                cameraService.pause()
            @unknown default:
                browserSession.persistCurrentURLIfNeeded()
                updateIdleTimerState(isIdleTimerDisabled: false)
                cameraService.pause()
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(
                captureIntervalSeconds: $captureIntervalSeconds,
                maxRetainedImages: $maxRetainedImages,
                captureRetentionModeRawValue: $captureRetentionModeRawValue,
                maxRetainedImageStorageMB: $maxRetainedImageStorageMB,
                startCameraOnLaunch: $startCameraOnLaunch,
                startupURLString: $startupURLString,
                httpServerUsername: $httpServerUsername,
                httpServerPassword: $httpServerPassword,
                rtspStreamResolutionScaleRawValue: $rtspStreamResolutionScaleRawValue,
                screenSaverSeconds: $screenSaverSeconds,
                screenDimDelaySeconds: $screenDimDelaySeconds,
                screenDimBrightnessPercent: $screenDimBrightnessPercent,
                onUserActivity: registerUserActivity
            )
        }
        .statusBarHidden(isScreenSaverActive)
    }

    private var homeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                NavigationLink(value: AppDestination.web) {
                    HomeNavigationCardView(title: "Dashboard", systemImage: "house") {
                        Text("Open the dashboard screen.")
                            .font(.body)
                            .foregroundStyle(.secondary)

                        Text("The URL is \(startupURLString.isEmpty ? "empty" : "set to \(startupURLString)").")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                NavigationLink(value: AppDestination.camera) {
                    HomeNavigationCardView(title: "Camera controls", systemImage: "camera") {
                        Text("Open the camera screen to control capture.")
                            .font(.body)
                            .foregroundStyle(.secondary)

                        Text(startCameraOnLaunch ? "Camera starts automatically at app launch." : "Camera remains off when the app launches.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                NavigationLink(value: AppDestination.captures) {
                    HomeNavigationCardView(title: "Saved captures", systemImage: "photo.on.rectangle") {
                        Text("Open your saved captures to manage individual photos.")
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
        .trackUserActivity(registerUserActivity)
    }

    private var rtspStreamResolutionScale: RTSPStreamResolutionScale {
        RTSPStreamResolutionScale(rawValue: rtspStreamResolutionScaleRawValue) ?? RTSPStreamResolutionScale.defaultScale
    }

    private func insertCapturedItem(timestamp: Date, imagePath: String) {
        modelContext.insert(Item(timestamp: timestamp, imagePath: imagePath))
        try? modelContext.save()
        pruneStoredCapturesAfterCapture()
    }

    private func pruneStoredCapturesAfterCapture() {
        pendingCapturePruneCount += 1

        let elapsedSinceLastPrune = Date().timeIntervalSince(lastCapturePruneDate)
        if pendingCapturePruneCount >= capturePruneCountThreshold || elapsedSinceLastPrune >= capturePruneMaximumDelay {
            pruneStoredCaptures()
        } else {
            pruneStoredCaptures(after: capturePruneDebounceDelay)
        }
    }

    private func pruneStoredCaptures(after delay: Duration = .zero) {
        pruneTask?.cancel()

        let capturesDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Captures", isDirectory: true)
        let retainedImageCount = maxRetainedImages

        pruneTask = Task(priority: .utility) {
            try? await Task.sleep(for: delay)

            guard !Task.isCancelled else {
                return
            }

            _ = try? CaptureRetentionPolicy.pruneCapturedImages(in: capturesDirectory, keepingNewest: retainedImageCount)
            let existingImageTimestamps = Self.capturedImageTimestamps(in: capturesDirectory)

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                guard !Task.isCancelled else {
                    return
                }

                applyStoredCapturePruning(existingImageTimestamps: existingImageTimestamps, capturesDirectory: capturesDirectory)
                pendingCapturePruneCount = 0
                lastCapturePruneDate = Date()
            }
        }
    }

    private func applyStoredCapturePruning(existingImageTimestamps: [String: Date], capturesDirectory: URL) {
        let descriptor = FetchDescriptor<Item>(sortBy: [SortDescriptor(\Item.timestamp, order: .reverse)])

        guard let storedItems = try? modelContext.fetch(descriptor) else {
            return
        }

        let existingImagePaths = Set(existingImageTimestamps.keys)
        var representedImagePaths = Set<String>()
        var didChangeModel = false

        for item in storedItems {
            let hadStoredPath = item.imagePath != nil
            let resolvedPath = resolvedImagePath(
                from: item.imagePath,
                existingImagePaths: existingImagePaths,
                capturesDirectory: capturesDirectory
            )

            if item.imagePath != resolvedPath {
                item.imagePath = resolvedPath
                didChangeModel = true
            }

            if hadStoredPath, resolvedPath == nil {
                modelContext.delete(item)
                didChangeModel = true
                continue
            }

            if let resolvedPath {
                representedImagePaths.insert(resolvedPath)
            }
        }

        for (imagePath, timestamp) in existingImageTimestamps where !representedImagePaths.contains(imagePath) {
            modelContext.insert(Item(timestamp: timestamp, imagePath: imagePath))
            representedImagePaths.insert(imagePath)
            didChangeModel = true
        }

        if didChangeModel {
            try? modelContext.save()
        }
    }

    private static func capturedImageTimestamps(in capturesDirectory: URL) -> [String: Date] {
        let resourceKeys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .creationDateKey,
            .isRegularFileKey
        ]

        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: capturesDirectory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        return urls.reduce(into: [:]) { imageTimestamps, fileURL in
            guard ["jpg", "jpeg"].contains(fileURL.pathExtension.lowercased()),
                  let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys),
                  resourceValues.isRegularFile == true else {
                return
            }

            imageTimestamps[fileURL.path] = resourceValues.contentModificationDate ?? resourceValues.creationDate ?? .distantPast
        }
    }

    private func resolvedImagePath(
        from storedPath: String?,
        existingImagePaths: Set<String>,
        capturesDirectory: URL
    ) -> String? {
        guard let storedPath, !storedPath.isEmpty else {
            return nil
        }

        if let fileURL = URL(string: storedPath), fileURL.isFileURL {
            if existingImagePaths.contains(fileURL.path) {
                return fileURL.path
            }

            let fallbackPath = capturesDirectory.appendingPathComponent(fileURL.lastPathComponent).path
            if existingImagePaths.contains(fallbackPath) {
                return fallbackPath
            }

            return nil
        }

        let pathURL = URL(fileURLWithPath: storedPath)
        if existingImagePaths.contains(pathURL.path) {
            return pathURL.path
        }

        let fallbackPath = capturesDirectory.appendingPathComponent(pathURL.lastPathComponent).path
        if existingImagePaths.contains(fallbackPath) {
            return fallbackPath
        }

        return nil
    }

    private func showDestination(_ destination: AppDestination) {
        navigationPath = [destination]
    }

    private func navigateHome() {
        navigationPath.removeAll()
    }

    private func openWebView() {
        navigationPath = [.web]
    }

    private var screenSaverView: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Text(currentTime, format: .dateTime.hour().minute())
                    .font(.system(size: 160, weight: .bold, design: .rounded))
                    .foregroundStyle(clockColor)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                    .frame(maxWidth: .infinity)

                Text(formattedCurrentDate)
                    .font(.system(size: 30, weight: .medium, design: .rounded))
                    .foregroundStyle(clockColor)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal)
            .offset(y: screenSaverClockVerticalOffset)

            if isScreenDimmed {
                Color.black
                    .opacity(screenDimOverlayOpacity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            registerUserActivity()
        }
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in
            registerUserActivity()
        })
    }

    private var clockColor: Color {
        isNightClockMode ? nightRedColor : .white
    }

    private var isNightClockMode: Bool {
        let hour = Calendar.current.component(.hour, from: currentTime)
        return hour >= 23 || hour < 5
    }

    private var nightRedColor: Color {
        Color(red: 0.5, green: 0.1, blue: 0.1)
    }

    private var formattedCurrentDate: String {
        currentTime.formatted(date: .complete, time: .omitted)
    }

    private var screenSaverClockVerticalOffset: CGFloat {
        guard isScreenSaverActive,
              let activatedAt = screenSaverActivatedAt,
              screenSaverDriftCycleDuration > 0 else {
            return 0
        }

        let elapsed = max(0, currentTime.timeIntervalSince(activatedAt))
        let cyclePosition = elapsed.truncatingRemainder(dividingBy: screenSaverDriftCycleDuration)
        let quarterCycle = screenSaverDriftCycleDuration / 4
        let amplitude = screenSaverDriftAmplitude

        // Linear path over one cycle: center -> top -> center -> bottom -> center.
        switch cyclePosition {
        case ..<quarterCycle:
            return -amplitude * CGFloat(cyclePosition / quarterCycle)
        case ..<(2 * quarterCycle):
            let progress = (cyclePosition - quarterCycle) / quarterCycle
            return -amplitude + (amplitude * CGFloat(progress))
        case ..<(3 * quarterCycle):
            let progress = (cyclePosition - (2 * quarterCycle)) / quarterCycle
            return amplitude * CGFloat(progress)
        default:
            let progress = (cyclePosition - (3 * quarterCycle)) / quarterCycle
            return amplitude - (amplitude * CGFloat(progress))
        }
    }

    private func registerUserActivity() {
        lastUserActivity = Date()
        isScreenSaverActive = false
        isScreenDimmed = false
        screenSaverActivatedAt = nil
    }

    private func updateScreenSaverState() {
        let now = Date()

        if isScreenSaverActive {
            updateScreenDimmingState(at: now)
            return
        }

        let idleTime = now.timeIntervalSince(lastUserActivity)
        if idleTime >= TimeInterval(max(1, screenSaverSeconds)) {
            isScreenSaverActive = true
            isScreenDimmed = false
            screenSaverActivatedAt = now
        }
    }

    private func updateScreenDimmingState(at now: Date) {
        guard let activatedAt = screenSaverActivatedAt else {
            isScreenDimmed = false
            return
        }

        let elapsed = now.timeIntervalSince(activatedAt)
        isScreenDimmed = elapsed >= TimeInterval(max(1, screenDimDelaySeconds))
    }

    private var screenDimOverlayOpacity: Double {
        let clampedBrightness = min(max(screenDimBrightnessPercent, 0), 100)
        return 1 - (Double(clampedBrightness) / 100.0)
    }

    private func updateIdleTimerState() {
        updateIdleTimerState(isIdleTimerDisabled: cameraService.isRunning && scenePhase != .background)
    }

    private func updateIdleTimerState(isIdleTimerDisabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = isIdleTimerDisabled
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
