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

    var body: some View {
        NavigationStack(path: $navigationPath) {
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
                        Button {
                            showDestination(.web)
                        } label: {
                            Image(systemName: "house")
                        }
                        .accessibilityLabel("Open web view")

                        Button {
                            showDestination(.camera)
                        } label: {
                            Image(systemName: "camera")
                        }
                        .accessibilityLabel("Open camera controls")

                        Button {
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
                        WebBrowserView(browserSession: browserSession, openRootHome: navigateHome)
                    case .camera:
                        CameraControlView(cameraService: cameraService, openWebView: openWebView)
                    case .captures:
                        CapturesView(openWebView: openWebView)
                    }
                }
        }
        .onAppear {
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
                startupURLString: $startupURLString
            )
        }
    }

    private var homeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: openWebView) {
                    Image(systemName: "house")
                }
                .accessibilityLabel("Open web view")
            }
        }
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
    let openWebView: () -> Void
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
                        ItemDetailView(item: item, openWebView: openWebView)
                    } label: {
                        CaptureRowContentView(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .onDelete(perform: deleteItems)
        }
        .navigationTitle(navigationTitle)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                if !items.isEmpty {
                    Button(isSelectingItems ? "Done" : "Select") {
                        toggleSelectionMode()
                    }

                    if isSelectingItems {
                        Button(selectionActionTitle) {
                            toggleSelectAllItems()
                        }
                    }
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                HStack {
                    Button(action: openWebView) {
                        Image(systemName: "house")
                    }
                    .accessibilityLabel("Open web view")

                    Button {
                        shareSelectedOrLatestImage()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel(shareButtonAccessibilityLabel)
                    .disabled(shareableImageURLs.isEmpty)

                    Button(role: .destructive) {
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

private struct WebBrowserView: View {
    @ObservedObject var browserSession: BrowserSession
    let openRootHome: () -> Void

    var body: some View {
        WebViewContainer(webView: browserSession.webView, onRefresh: browserSession.reloadCurrentPage)
            .navigationTitle("Dashboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        browserSession.reloadCurrentPage()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Reload page")

                    Button(action: openRootHome) {
                        Image(systemName: "rectangle.grid.2x2")
                    }
                    .accessibilityLabel("Open home")
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .onAppear {
                browserSession.loadInitialPageIfNeeded()
            }
    }
}

private struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    let onRefresh: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(webView: webView, onRefresh: onRefresh)
    }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.configureIfNeeded()
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.attach(to: uiView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private weak var webView: WKWebView?
        private let onRefresh: () -> Void
        private let refreshControl = UIRefreshControl()
        private var isConfigured = false

        init(webView: WKWebView, onRefresh: @escaping () -> Void) {
            self.webView = webView
            self.onRefresh = onRefresh
            super.init()
            refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
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

            if webView.scrollView.refreshControl !== refreshControl {
                webView.scrollView.refreshControl = refreshControl
            }
        }

        @objc private func handleRefresh() {
            guard webView != nil else {
                refreshControl.endRefreshing()
                return
            }

            onRefresh()
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
                    Label("Image unavailable", systemImage: "photo.slash")
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

                    Image(systemName: imagePath == nil ? "photo.slash" : "photo")
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: openWebView) {
                    Image(systemName: "house")
                }
                .accessibilityLabel("Open web view")
            }
        }
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
        webView.allowsBackForwardNavigationGestures = true

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

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
