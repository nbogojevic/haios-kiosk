import SwiftUI

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
