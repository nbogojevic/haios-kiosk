//
//  ContentView.swift
//  experiment-camera
//
//  Created by Nenad BOGOJEVIC on 19/06/2026.
//

import SwiftUI
import SwiftData
import Combine
import ImageIO
import UIKit
import WebKit

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
                        Text("Open the camera screen to start or stop capture, review status, and monitor the latest capture time.")
                            .font(.body)
                            .foregroundStyle(.secondary)

                        Text(startCameraOnLaunch ? "The camera is set to start automatically when the app launches." : "The camera is currently set to remain off when the app launches.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                NavigationLink(value: AppDestination.captures) {
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
    let openWebView: () -> Void
    let onUserActivity: () -> Void

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
        .trackUserActivity(onUserActivity)
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
        onUserActivity()

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
    let openWebView: () -> Void
    let onUserActivity: () -> Void
    @State private var showingDeleteImagesConfirmation = false
    @State private var isSelectingItems = false
    @State private var selectedItemIDs = Set<PersistentIdentifier>()
    @State private var shareSheetPayload: ShareSheetPayload?

    var body: some View {
        List {
            ForEach(items) { item in
                if isSelectingItems {
                    Button {
                        toggleSelection(for: item)
                    } label: {
                        CaptureRowContentView(
                            item: item,
                            isSelecting: true,
                            isSelected: selectedItemIDs.contains(item.persistentModelID)
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink {
                        ItemDetailView(
                            item: item,
                            openWebView: openWebView,
                            onUserActivity: onUserActivity
                        )
                    } label: {
                        CaptureRowContentView(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .onDelete(perform: deleteItems)
        }
        .trackUserActivity(onUserActivity)
        .navigationTitle(navigationTitle)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                if !items.isEmpty {
                    Button(isSelectingItems ? "Done" : "Select") {
                        onUserActivity()
                        toggleSelectionMode()
                    }

                    if isSelectingItems {
                        Button(selectionActionTitle) {
                            onUserActivity()
                            toggleSelectAllItems()
                        }
                    }
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                HStack {
                    Button {
                        onUserActivity()
                        shareSelectedOrLatestImage()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel(shareButtonAccessibilityLabel)
                    .disabled(shareableImageURLs.isEmpty)

                    Button(role: .destructive) {
                        onUserActivity()
                        showingDeleteImagesConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Delete all captures")
                    .disabled(!hasSavedImages)
                }
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
        .sheet(item: $shareSheetPayload) { payload in
            ActivityViewController(
                activityItems: payload.imageURLs,
                onShareCompleted: { @MainActor @Sendable in
                    payload.onShareCompleted()
                }
            )
        }
    }

    private var hasSavedImages: Bool {
        !items.isEmpty || FileManager.default.fileExists(atPath: capturesDirectoryURL.path)
    }

    private var navigationTitle: String {
        if isSelectingItems {
            let count = selectedItemIDs.count
            return count == 1 ? "1 Selected" : "\(count) Selected"
        }

        return "Captures"
    }

    private var selectionActionTitle: String {
        selectedItemIDs.count == items.count ? "Clear" : "Select All"
    }

    private var latestAvailableImageURL: URL? {
        items.compactMap(\.imageURL).first
    }

    private var selectedShareableImageURLs: [URL] {
        items
            .filter { selectedItemIDs.contains($0.persistentModelID) }
            .compactMap(\.imageURL)
    }

    private var shareableImageURLs: [URL] {
        if selectedItemIDs.isEmpty {
            return latestAvailableImageURL.map { [$0] } ?? []
        }

        return selectedShareableImageURLs
    }

    private var shareButtonAccessibilityLabel: String {
        if selectedItemIDs.isEmpty {
            return "Share latest captured image"
        }

        let count = selectedShareableImageURLs.count
        return count == 1 ? "Share selected image" : "Share \(count) selected images"
    }

    private var capturesDirectoryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Captures", isDirectory: true)
    }

    private func toggleSelectionMode() {
        if isSelectingItems {
            selectedItemIDs.removeAll()
        }

        isSelectingItems.toggle()
    }

    private func toggleSelectAllItems() {
        if selectedItemIDs.count == items.count {
            selectedItemIDs.removeAll()
        } else {
            selectedItemIDs = Set(items.map(\.persistentModelID))
        }
    }

    private func toggleSelection(for item: Item) {
        if selectedItemIDs.contains(item.persistentModelID) {
            selectedItemIDs.remove(item.persistentModelID)
        } else {
            selectedItemIDs.insert(item.persistentModelID)
        }
    }

    private func shareSelectedOrLatestImage() {
        let imageURLs = shareableImageURLs
        guard !imageURLs.isEmpty else {
            return
        }

        shareSheetPayload = ShareSheetPayload(imageURLs: imageURLs) { @MainActor @Sendable in
            selectedItemIDs.removeAll()
            isSelectingItems = false
        }
    }

    private func deleteItems(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                let item = items[index]

                selectedItemIDs.remove(item.persistentModelID)

                if let imagePath = item.imagePath {
                    try? FileManager.default.removeItem(atPath: imagePath)
                }

                modelContext.delete(item)
            }
        }
    }

    private func deleteAllImages() {
        withAnimation {
            selectedItemIDs.removeAll()
            isSelectingItems = false

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
    @Binding var startupURLString: String
    @Binding var screenSaverSeconds: Int
    @Binding var screenDimDelaySeconds: Int
    @Binding var screenDimBrightnessPercent: Int
    let onUserActivity: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com", text: $startupURLString)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                } header: {
                    Text("Web Home")
                } footer: {
                    Text("Choose the page to load when the Home screen opens for the first time. After that, the app restores the last page you visited, even after you leave the app.")
                }

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

                Section {
                    Stepper(value: $screenSaverSeconds, in: 1...3600) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Show screen saver after")

                            Text(screenSaverDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Stepper(value: $screenDimDelaySeconds, in: 1...3600) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Dim after screen saver starts")

                            Text(screenDimDelayDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Stepper(value: $screenDimBrightnessPercent, in: 0...100) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Dimmed brightness")

                            Text(screenDimBrightnessDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Screen Saver")
                } footer: {
                    Text("The screen saver shows only the current time and date. After it appears, the app dims further using the brightness level you choose here.")
                }
            }
            .trackUserActivity(onUserActivity)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        onUserActivity()
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

    private var screenSaverDescription: String {
        screenSaverSeconds == 1 ? "After 1 second of inactivity" : "After \(screenSaverSeconds) seconds of inactivity"
    }

    private var screenDimDelayDescription: String {
        screenDimDelaySeconds == 1 ? "Dim 1 second later" : "Dim \(screenDimDelaySeconds) seconds later"
    }

    private var screenDimBrightnessDescription: String {
        if screenDimBrightnessPercent == 0 {
            return "Completely dark"
        }

        if screenDimBrightnessPercent == 100 {
            return "No extra dimming"
        }

        return "Keep \(screenDimBrightnessPercent)% brightness"
    }
}

private struct WebBrowserView: View {
    @ObservedObject var browserSession: BrowserSession
    let openRootHome: () -> Void
    let onUserActivity: () -> Void
    @State private var isNavigationBarVisible = true
    @State private var hideNavigationBarTask: Task<Void, Never>?

    private let navigationBarAutoHideDelay: Duration = .seconds(3)

    var body: some View {
        WebViewContainer(
            webView: browserSession.webView,
            onRefresh: browserSession.reloadCurrentPage,
            onRevealNavigationBar: revealNavigationBarTemporarily,
            onNavigateHome: openRootHome,
            onUserActivity: onUserActivity
        )
            .navigationTitle("Dashboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(isNavigationBarVisible ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        onUserActivity()
                        browserSession.reloadCurrentPage()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Reload page")
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .onAppear {
                browserSession.loadInitialPageIfNeeded()
                isNavigationBarVisible = true
                scheduleNavigationBarAutoHide()
            }
            .onDisappear {
                hideNavigationBarTask?.cancel()
            }
    }

    private func revealNavigationBarTemporarily() {
        withAnimation {
            isNavigationBarVisible = true
        }

        scheduleNavigationBarAutoHide()
    }

    private func scheduleNavigationBarAutoHide() {
        hideNavigationBarTask?.cancel()
        hideNavigationBarTask = Task {
            try? await Task.sleep(for: navigationBarAutoHideDelay)

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                withAnimation {
                    isNavigationBarVisible = false
                }
            }
        }
    }
}

private struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    let onRefresh: () -> Void
    let onRevealNavigationBar: () -> Void
    let onNavigateHome: () -> Void
    let onUserActivity: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            webView: webView,
            onRefresh: onRefresh,
            onRevealNavigationBar: onRevealNavigationBar,
            onNavigateHome: onNavigateHome,
            onUserActivity: onUserActivity
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.configureIfNeeded()
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.attach(to: uiView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        private weak var webView: WKWebView?
        private let onRefresh: () -> Void
        private let onRevealNavigationBar: () -> Void
        private let onNavigateHome: () -> Void
        private let onUserActivity: () -> Void
        private let refreshControl = UIRefreshControl()
        private let tapGestureRecognizer = UITapGestureRecognizer()
        private let panGestureRecognizer = UIPanGestureRecognizer()
        private let tripleTapGestureRecognizer = UITapGestureRecognizer()
        private let twoFingerSwipeRightGestureRecognizer = UISwipeGestureRecognizer()
        private var isConfigured = false
        private var hasTriggeredNavigationBarRevealForCurrentDrag = false
        private let navigationBarRevealThreshold: CGFloat = 24

        init(
            webView: WKWebView,
            onRefresh: @escaping () -> Void,
            onRevealNavigationBar: @escaping () -> Void,
            onNavigateHome: @escaping () -> Void,
            onUserActivity: @escaping () -> Void
        ) {
            self.webView = webView
            self.onRefresh = onRefresh
            self.onRevealNavigationBar = onRevealNavigationBar
            self.onNavigateHome = onNavigateHome
            self.onUserActivity = onUserActivity
            super.init()
            refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
            tapGestureRecognizer.cancelsTouchesInView = false
            tapGestureRecognizer.delegate = self
            tapGestureRecognizer.addTarget(self, action: #selector(handleTap))

            panGestureRecognizer.cancelsTouchesInView = false
            panGestureRecognizer.delegate = self
            panGestureRecognizer.addTarget(self, action: #selector(handlePan))

            tripleTapGestureRecognizer.numberOfTapsRequired = 3
            tripleTapGestureRecognizer.numberOfTouchesRequired = 1
            tripleTapGestureRecognizer.cancelsTouchesInView = false
            tripleTapGestureRecognizer.delegate = self
            tripleTapGestureRecognizer.addTarget(self, action: #selector(handleTripleTap))

            twoFingerSwipeRightGestureRecognizer.direction = .right
            twoFingerSwipeRightGestureRecognizer.numberOfTouchesRequired = 2
            twoFingerSwipeRightGestureRecognizer.cancelsTouchesInView = false
            twoFingerSwipeRightGestureRecognizer.delegate = self
            twoFingerSwipeRightGestureRecognizer.addTarget(self, action: #selector(handleTwoFingerSwipeRight))
        }

        func configureIfNeeded() {
            guard !isConfigured, let webView else {
                return
            }

            attach(to: webView)
            isConfigured = true
        }

        func attach(to webView: WKWebView) {
            self.webView = webView
            webView.navigationDelegate = self
            webView.scrollView.delegate = self

            if webView.scrollView.refreshControl !== refreshControl {
                webView.scrollView.refreshControl = refreshControl
            }

            if tapGestureRecognizer.view !== webView {
                webView.addGestureRecognizer(tapGestureRecognizer)
            }

            if panGestureRecognizer.view !== webView {
                webView.addGestureRecognizer(panGestureRecognizer)
            }

            if tripleTapGestureRecognizer.view !== webView {
                webView.addGestureRecognizer(tripleTapGestureRecognizer)
            }

            if twoFingerSwipeRightGestureRecognizer.view !== webView {
                webView.addGestureRecognizer(twoFingerSwipeRightGestureRecognizer)
            }
        }

        @objc private func handleRefresh() {
            guard webView != nil else {
                refreshControl.endRefreshing()
                return
            }

            onUserActivity()
            onRefresh()
        }

        @objc private func handleTap() {
            onUserActivity()
        }

        @objc private func handlePan(_ gestureRecognizer: UIPanGestureRecognizer) {
            switch gestureRecognizer.state {
            case .began, .changed:
                onUserActivity()
            default:
                break
            }
        }

        @objc private func handleTripleTap() {
            onUserActivity()
            onRevealNavigationBar()
        }

        @objc private func handleTwoFingerSwipeRight() {
            onUserActivity()
            onNavigateHome()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            refreshControl.endRefreshing()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            refreshControl.endRefreshing()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            refreshControl.endRefreshing()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if scrollView.isDragging || scrollView.isTracking || scrollView.isDecelerating {
                onUserActivity()
            }

            let isPullingDown = scrollView.panGestureRecognizer.translation(in: scrollView).y > 0
            let isAtTop = scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top
            let hasExceededRevealThreshold = scrollView.contentOffset.y < -(scrollView.adjustedContentInset.top + navigationBarRevealThreshold)

            guard isPullingDown, isAtTop, hasExceededRevealThreshold else {
                if !isPullingDown {
                    hasTriggeredNavigationBarRevealForCurrentDrag = false
                }

                return
            }

            guard !hasTriggeredNavigationBarRevealForCurrentDrag else {
                return
            }

            hasTriggeredNavigationBarRevealForCurrentDrag = true
            onRevealNavigationBar()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            hasTriggeredNavigationBarRevealForCurrentDrag = false
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            hasTriggeredNavigationBarRevealForCurrentDrag = false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer === tapGestureRecognizer
                || gestureRecognizer === panGestureRecognizer
                || gestureRecognizer === tripleTapGestureRecognizer
                || gestureRecognizer === twoFingerSwipeRightGestureRecognizer
        }
    }
}

private struct CaptureRowContentView: View {
    let item: Item
    var isSelecting = false
    var isSelected = false

    var body: some View {
        HStack(spacing: 12) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }

            CaptureThumbnailView(imagePath: item.imagePath)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))

                if item.imageURL != nil {
                    Label("Captured image", systemImage: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Image unavailable", systemImage: "photo.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
    }
}

private struct CaptureThumbnailView: View {
    @Environment(\.displayScale) private var displayScale

    let imagePath: String?
    var size: CGFloat = 56

    @State private var thumbnail: UIImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.thinMaterial)

                    Image(systemName: imagePath == nil ? "photo.badge.exclamationmark" : "photo")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary)
        }
        .task(id: imagePath) {
            thumbnail = await loadThumbnail()
        }
    }

    private func loadThumbnail() async -> UIImage? {
        guard let imagePath else {
            return nil
        }

        let maxPixelSize = max(size * displayScale, 1)
        return await Task.detached(priority: .utility) {
            Self.thumbnailImage(at: imagePath, maxPixelSize: maxPixelSize)
        }.value
    }

    nonisolated private static func thumbnailImage(at imagePath: String, maxPixelSize: CGFloat) -> UIImage? {
        let imageURL = URL(fileURLWithPath: imagePath)
        guard FileManager.default.fileExists(atPath: imageURL.path),
              let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize.rounded(.up))
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}

private struct ItemDetailView: View {
    let item: Item
    let openWebView: () -> Void
    let onUserActivity: () -> Void

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
        .trackUserActivity(onUserActivity)
        .navigationTitle("Capture")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var image: UIImage? {
        guard let imageURL = item.imageURL else {
            return nil
        }

        return UIImage(contentsOfFile: imageURL.path)
    }
}

private struct ShareSheetPayload: Identifiable {
    let id = UUID()
    let imageURLs: [URL]
    let onShareCompleted: @MainActor @Sendable () -> Void
}

private struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]
    let onShareCompleted: @MainActor @Sendable () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let viewController = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        viewController.completionWithItemsHandler = { _, completed, _, _ in
            guard completed else {
                return
            }

            Task { @MainActor in
                onShareCompleted()
            }
        }

        return viewController
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct BrowserURLPersistenceStore: @unchecked Sendable {
    let userDefaults: UserDefaults

    func persist(url: URL?) {
        guard let url,
              let absoluteString = persistentURLString(from: url) else {
            return
        }

        userDefaults.set(absoluteString, forKey: BrowserSession.lastVisitedURLStorageKey)
    }

    private func persistentURLString(from url: URL) -> String? {
        let absoluteString = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        return absoluteString.isEmpty ? nil : absoluteString
    }
}

@MainActor
private final class BrowserSession: ObservableObject {
    static let startupURLStorageKey = "webHomeStartupURL"
    static let lastVisitedURLStorageKey = "webHomeLastVisitedURL"
    static let defaultStartupURLString = "http://home-assistant.local:8123"

    let objectWillChange = ObservableObjectPublisher()
    let webView: WKWebView

    private let userDefaults: UserDefaults
    private let persistenceStore: BrowserURLPersistenceStore
    private var urlObservation: NSKeyValueObservation?
    private var hasLoadedInitialPage = false

    init(userDefaults: UserDefaults = .standard) {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        self.userDefaults = userDefaults
        self.persistenceStore = BrowserURLPersistenceStore(userDefaults: userDefaults)
        self.webView = WKWebView(frame: .zero, configuration: configuration)

        let persistenceStore = self.persistenceStore
        urlObservation = webView.observe(\.url, options: [.new]) { webView, _ in
            persistenceStore.persist(url: webView.url)
        }
    }

    func loadInitialPageIfNeeded() {
        guard !hasLoadedInitialPage else {
            return
        }

        hasLoadedInitialPage = true
        loadRestoredPage()
    }

    func persistCurrentURLIfNeeded() {
        persistenceStore.persist(url: webView.url)
    }

    func reloadCurrentPage() {
        if webView.url != nil {
            webView.reload()
        } else {
            loadRestoredPage()
        }
    }

    private func loadRestoredPage() {
        guard let url = restoredURL() else {
            return
        }

        webView.load(URLRequest(url: url))
    }

    private func restoredURL() -> URL? {
        Self.normalizedURL(from: userDefaults.string(forKey: Self.lastVisitedURLStorageKey))
            ?? Self.normalizedURL(from: userDefaults.string(forKey: Self.startupURLStorageKey))
            ?? URL(string: Self.defaultStartupURLString)
    }

    private static func normalizedURL(from rawValue: String?) -> URL? {
        guard let rawValue else {
            return nil
        }

        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return nil
        }

        if let url = URL(string: trimmedValue), url.scheme != nil {
            return url
        }

        return URL(string: "https://\(trimmedValue)")
    }
}

private extension Item {
    var imageURL: URL? {
        guard let imagePath, !imagePath.isEmpty else {
            return nil
        }

        let imageURL = URL(fileURLWithPath: imagePath)
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            return nil
        }

        return imageURL
    }
}

private struct UserActivityTrackingModifier: ViewModifier {
    let onUserActivity: () -> Void

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(TapGesture().onEnded {
                onUserActivity()
            })
            .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in
                onUserActivity()
            })
    }
}

private extension View {
    func trackUserActivity(_ onUserActivity: @escaping () -> Void) -> some View {
        modifier(UserActivityTrackingModifier(onUserActivity: onUserActivity))
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
