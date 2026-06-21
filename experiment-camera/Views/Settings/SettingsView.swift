import SwiftUI

struct SettingsView: View {
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
