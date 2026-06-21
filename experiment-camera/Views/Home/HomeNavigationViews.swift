import SwiftUI
@preconcurrency import AVFoundation

struct HomeNavigationCardView<Content: View>: View {
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

struct CameraControlView: View {
    @ObservedObject var cameraService: CameraCaptureService
    let openWebView: () -> Void
    let onUserActivity: () -> Void
    @State private var showsLivePreview = false

    var body: some View {
        GeometryReader { proxy in
            let contentLayout = contentLayout(in: proxy)

            ScrollView {
                contentLayout {
                    CameraStatusCardView(cameraService: cameraService)
                        .frame(width: statusCardWidth(in: proxy), alignment: .leading)

                    if cameraService.isRunning {
                        previewContent(height: previewHeight(in: proxy))
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .trackUserActivity(onUserActivity)
        .navigationTitle("Camera")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            updatePreviewVisibility(animated: false)
        }
        .onDisappear {
            showsLivePreview = false
        }
        .onChange(of: cameraService.isRunning) { _, _ in
            updatePreviewVisibility(animated: true)
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: toggleCamera) {
                Label(cameraService.buttonTitle, systemImage: cameraService.buttonIconName)
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(cameraService.isRunning ? .red : .accentColor)
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom)
            .background(.bar)
        }
    }

    private func isLandscapeLayout(in proxy: GeometryProxy) -> Bool {
        proxy.size.width > proxy.size.height
    }

    private func statusCardWidth(in proxy: GeometryProxy) -> CGFloat? {
        guard cameraService.isRunning, isLandscapeLayout(in: proxy) else {
            return nil
        }

        return min(max(proxy.size.width * 0.3, 220), 320)
    }

    private func previewHeight(in proxy: GeometryProxy) -> CGFloat {
        if cameraService.isRunning, isLandscapeLayout(in: proxy) {
            // Keep preview compact on short landscape screens.
            return max(min(proxy.size.height * 0.45, 190), 150)
        }

        return max(proxy.size.height / 3, 180)
    }

    private func contentLayout(in proxy: GeometryProxy) -> AnyLayout {
        if cameraService.isRunning, isLandscapeLayout(in: proxy) {
            return AnyLayout(HStackLayout(alignment: .top, spacing: 20))
        }

        return AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
    }

    @ViewBuilder
    private func previewContent(height: CGFloat) -> some View {
        if showsLivePreview {
            CameraPreviewCardView(
                session: cameraService.previewSession,
                previewHeight: height
            )
        } else {
            CameraPreviewPlaceholderCardView(previewHeight: height)
        }
    }

    private func updatePreviewVisibility(animated: Bool) {
        guard cameraService.isRunning else {
            showsLivePreview = false
            return
        }

        if !animated {
            DispatchQueue.main.async {
                showsLivePreview = cameraService.isRunning
            }

            return
        }

        showsLivePreview = false
        DispatchQueue.main.async {
            showsLivePreview = cameraService.isRunning
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

private struct CameraPreviewCardView: View {
    let session: AVCaptureSession
    let previewHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Live Preview", systemImage: "video")
                .font(.headline)

            CameraPreviewView(session: session)
                .frame(maxWidth: .infinity)
                .frame(height: previewHeight)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.quaternary)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct CameraPreviewPlaceholderCardView: View {
    let previewHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Live Preview", systemImage: "video")
                .font(.headline)

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.quaternary.opacity(0.2))

                ProgressView()
                    .controlSize(.regular)
            }
            .frame(maxWidth: .infinity)
            .frame(height: previewHeight)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.quaternary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

@MainActor
private struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewContainerView {
        let view = CameraPreviewContainerView()
        view.previewLayer.videoGravity = .resizeAspect
        view.previewLayer.session = session
        view.onLayoutChanged = { previewView in
            configureConnection(for: previewView)
        }
        configureConnection(for: view)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewContainerView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }

        configureConnection(for: uiView)
    }

    static func dismantleUIView(_ uiView: CameraPreviewContainerView, coordinator: ()) {
        uiView.onLayoutChanged = nil
        uiView.previewLayer.session = nil
    }

    private func configureConnection(for view: CameraPreviewContainerView) {
        guard let connection = view.previewLayer.connection else {
            return
        }

        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }

        let orientation = resolvedOrientation(for: view)
        guard view.appliedOrientation != orientation else {
            return
        }

        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(orientation.videoRotationAngle) {
                connection.videoRotationAngle = orientation.videoRotationAngle
            }
        } else if connection.isVideoOrientationSupported {
            orientation.applyLegacyVideoOrientation(to: connection)
        }

        view.appliedOrientation = orientation
    }

    private func resolvedOrientation(for view: CameraPreviewContainerView) -> DeviceCameraOrientation {
        if let orientation = DeviceCameraOrientation(deviceOrientation: UIDevice.current.orientation) {
            return orientation
        }

        return view.appliedOrientation
    }
}

private final class CameraPreviewContainerView: UIView {
    var appliedOrientation: DeviceCameraOrientation = .portrait
    var onLayoutChanged: ((CameraPreviewContainerView) -> Void)?

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayoutChanged?(self)
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
