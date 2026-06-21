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

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    CameraStatusCardView(cameraService: cameraService)

                    if cameraService.isRunning {
                        CameraPreviewCardView(
                            session: cameraService.previewSession,
                            previewHeight: max(proxy.size.height / 3, 180)
                        )
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .trackUserActivity(onUserActivity)
        .navigationTitle("Camera")
        .navigationBarTitleDisplayMode(.inline)
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

private struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewContainerView {
        let view = CameraPreviewContainerView()
        view.previewLayer.videoGravity = .resizeAspect
        view.previewLayer.session = session
        configureConnection(for: view.previewLayer.connection)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewContainerView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }

        configureConnection(for: uiView.previewLayer.connection)
    }

    static func dismantleUIView(_ uiView: CameraPreviewContainerView, coordinator: ()) {
        uiView.previewLayer.session = nil
    }

    private func configureConnection(for connection: AVCaptureConnection?) {
        guard let connection else {
            return
        }

        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }

        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }
}

private final class CameraPreviewContainerView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
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
