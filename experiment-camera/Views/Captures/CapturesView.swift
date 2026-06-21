import SwiftUI
import SwiftData
import ImageIO
import UIKit

struct CapturesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Item.timestamp, order: .reverse) private var items: [Item]
    let openWebView: () -> Void
    let onUserActivity: () -> Void
    @State private var showingDeleteImagesConfirmation = false
    @State private var isSelectingItems = false
    @State private var selectedItemIDs = Set<PersistentIdentifier>()
    @State private var selectedItem: Item?
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
                    Button {
                        onUserActivity()
                        selectedItem = item
                    } label: {
                        CaptureRowContentView(item: item)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("CaptureRow")
                }
            }
            .onDelete(perform: deleteItems)
        }
        .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in
            onUserActivity()
        })
        .navigationTitle(navigationTitle)
        .navigationDestination(item: $selectedItem) { item in
            ItemDetailView(
                item: item,
                openWebView: openWebView,
                onUserActivity: onUserActivity
            )
        }
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
        items.compactMap(\.resolvedImageURL).first
    }

    private var selectedShareableImageURLs: [URL] {
        items
            .filter { selectedItemIDs.contains($0.persistentModelID) }
            .compactMap(\.resolvedImageURL)
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

                if selectedItem?.persistentModelID == item.persistentModelID {
                    selectedItem = nil
                }

                if let imageURL = item.resolvedImageURL {
                    try? FileManager.default.removeItem(at: imageURL)
                }

                modelContext.delete(item)
            }

            try? modelContext.save()
        }
    }

    private func deleteAllImages() {
        withAnimation {
            selectedItemIDs.removeAll()
            selectedItem = nil
            isSelectingItems = false

            for item in items {
                if let imageURL = item.resolvedImageURL,
                   imageURL.deletingLastPathComponent() != capturesDirectoryURL {
                    try? FileManager.default.removeItem(at: imageURL)
                }

                modelContext.delete(item)
            }

            if FileManager.default.fileExists(atPath: capturesDirectoryURL.path) {
                try? FileManager.default.removeItem(at: capturesDirectoryURL)
            }

            try? modelContext.save()
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

            CaptureThumbnailView(imagePath: item.resolvedImageURL?.path)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))

                if item.resolvedImageURL != nil {
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
        .contentShape(Rectangle())
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

                Text("Size: \(imageSizeDescription)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text(item.resolvedImageURL?.lastPathComponent ?? "Unavailable")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding()
        }
        .trackUserActivity(onUserActivity)
        .navigationTitle("Capture")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var image: UIImage? {
        guard let imageURL = item.resolvedImageURL else {
            return nil
        }

        return UIImage(contentsOfFile: imageURL.path)
    }

    private var imageSizeDescription: String {
        guard let imageURL = item.resolvedImageURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: imageURL.path),
              let fileSize = attributes[.size] as? NSNumber else {
            return "Unavailable"
        }

        let bytes = fileSize.int64Value

        if bytes > 1_048_576 {
            return String(format: "%.2f MB", Double(bytes) / 1_048_576)
        }

        if bytes > 1_024 {
            return String(format: "%.2f kB", Double(bytes) / 1_024)
        }

        return "\(bytes) bytes"
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
