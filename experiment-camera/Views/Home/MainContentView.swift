//
//  ContentView.swift
//  experiment-camera
//
//  Created by Nenad BOGOJEVIC on 19/06/2026.
//

// NBO: Run app in background so that camera capture continues to work even when the app is not in the foreground. This may require additional permissions and handling of background tasks.
// NBO: Increase size of start/stop camera button.
// NBO: Check why old images dissappear after restart of app from debugger. Settings however remain.
// NBO: Implement different logic for preserving images.
// NBO: Implement microphone capture and audio recording.

import SwiftUI
import SwiftData
import Combine

private enum AppDestination: Hashable {
    case web
    case camera
    case captures
}

struct ContentView: View {
    @AppStorage("captureIntervalSeconds") private var captureIntervalSeconds = 10
    @AppStorage(CaptureRetentionPolicy.storageKey) private var maxRetainedImages = CaptureRetentionPolicy.defaultMaxRetainedImages
    @AppStorage("startCameraOnLaunch") private var startCameraOnLaunch = false
    @AppStorage(BrowserSession.startupURLStorageKey) private var startupURLString = BrowserSession.defaultStartupURLString

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var cameraService = CameraCaptureService()
    @StateObject private var browserSession = BrowserSession()
    @State private var showingSettings = false
    @State private var didConfigureInitialState = false
    @State private var navigationPath: [AppDestination] = []

    @AppStorage("screenSaverSeconds") private var screenSaverSeconds = 45
    @AppStorage("screenDimDelaySeconds") private var screenDimDelaySeconds = 30
    @AppStorage("screenDimBrightnessPercent") private var screenDimBrightnessPercent = 30
    @State private var isScreenSaverActive = false
    @State private var isScreenDimmed = false
    @State private var lastUserActivity = Date()
    @State private var screenSaverActivatedAt: Date?
    @State private var currentTime = Date()
    private let inactivityTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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

            if !didConfigureInitialState {
                didConfigureInitialState = true

                browserSession.loadInitialPageIfNeeded()
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
        .onChange(of: startupURLString) { _, _ in
            browserSession.loadInitialPageIfNeeded()
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
                registerUserActivity()
                Task {
                    await cameraService.resumeIfNeeded()
                }
            case .inactive, .background:
                browserSession.persistCurrentURLIfNeeded()
                cameraService.pause()
            @unknown default:
                browserSession.persistCurrentURLIfNeeded()
                cameraService.pause()
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(
                captureIntervalSeconds: $captureIntervalSeconds,
                maxRetainedImages: $maxRetainedImages,
                startCameraOnLaunch: $startCameraOnLaunch,
                startupURLString: $startupURLString,
                screenSaverSeconds: $screenSaverSeconds,
                screenDimDelaySeconds: $screenDimDelaySeconds,
                screenDimBrightnessPercent: $screenDimBrightnessPercent,
                onUserActivity: registerUserActivity
            )
        }
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
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
