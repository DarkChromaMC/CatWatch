import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var monitor: MonitorController
    @Environment(\.dismiss) private var dismiss

    @State private var testResult: String?
    @State private var testing = false
    @State private var trainingFrames = 0
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("User key", text: $settings.pushoverUserKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Application API token", text: $settings.pushoverAppToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(testing ? "Sending…" : "Send test notification") {
                        testing = true
                        Task {
                            let error = await monitor.sendTestAlert()
                            testResult = error.map { "Failed: \($0)" } ?? "Sent. Check your devices."
                            testing = false
                        }
                    }
                    .disabled(testing)
                    if let testResult { Text(testResult).font(.footnote) }
                } header: {
                    Text("Pushover")
                } footer: {
                    Text("Your user key is on the pushover.net dashboard. Create an application there (e.g. \"CatWatch\") to get an API token.")
                }

                Section("Alerts") {
                    Picker("Priority", selection: $settings.priority) {
                        ForEach(PushoverPriority.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Picker("Sound", selection: $settings.sound) {
                        ForEach(Self.sounds, id: \.self) { Text($0.isEmpty ? "Default" : $0.capitalized).tag($0) }
                    }
                    Stepper("Cooldown: \(Self.duration(settings.cooldown))", value: $settings.cooldown, in: 15...1800, step: 15)
                    Toggle("Phone health alerts", isOn: $settings.healthAlerts)
                }

                Section {
                    LabeledContent("Min confidence", value: "\(Int(settings.minConfidence * 100))%")
                    Slider(value: $settings.minConfidence, in: 0.2...0.95, step: 0.05)
                    Stepper("Sightings before alert: \(settings.requiredHits)", value: $settings.requiredHits, in: 1...6)
                    Stepper("Checks per second: \(settings.detectionRate.formatted())", value: $settings.detectionRate, in: 1...8, step: 1)
                    Toggle("Ignore hens", isOn: $settings.ignoreHens)
                    Toggle("Ultra-wide lens", isOn: $settings.useUltraWide)
                        .onChange(of: settings.useUltraWide) { _, _ in Task { await monitor.restart() } }
                } header: {
                    Text("Detection")
                } footer: {
                    Text("Lower confidence catches more but may false-alarm. 1 sighting alerts fastest (best for not missing the cat); 2+ filters one-off glitches. Ignore hens double-checks each sighting with a model trained on your garden; turn it off if it ever misses your cat. Ultra-wide sees more of the yard but makes the cat smaller.")
                }

                Section {
                    Toggle("Web view", isOn: $settings.webViewEnabled)
                    Picker("Picture rotation", selection: $settings.pictureRotation) {
                        Text("Automatic").tag(-1)
                        Text("None").tag(0)
                        Text("90° right").tag(1)
                        Text("180°").tag(2)
                        Text("90° left").tag(3)
                    }
                    if settings.webViewEnabled {
                        LabeledContent("PIN", value: settings.webPin)
                        if let problem = monitor.webError {
                            Text("Not reachable yet: \(problem). Check iPhone Settings › Privacy & Security › Local Network › CatWatch.")
                                .font(.footnote).foregroundStyle(.red)
                        }
                        if let address = LiveServer.wifiAddress() {
                            let link = "http://\(address):\(LiveServer.port)/?pin=\(settings.webPin)"
                            Text(link).font(.footnote.monospaced()).textSelection(.enabled)
                        } else {
                            Text("Connect this phone to Wi-Fi to get the link.").font(.footnote)
                        }
                        Button("New PIN") { settings.webPin = String(format: "%04d", Int.random(in: 0...9999)) }
                    }
                } header: {
                    Text("Web view")
                } footer: {
                    Text("Open the link in a browser on any device on the same Wi-Fi to see the live camera, the zone, zoom areas and recent alerts. If iOS asks to allow local network access, tap Allow.")
                }

                Section {
                    Toggle("Record training frames", isOn: $settings.recordTraining)
                    LabeledContent("Saved frames", value: "\(trainingFrames) of \(TrainingRecorder.maxFrames)")
                    Button("Delete saved frames", role: .destructive) { confirmDelete = true }
                        .disabled(trainingFrames == 0)
                        .confirmationDialog("Delete all \(trainingFrames) saved frames?", isPresented: $confirmDelete,
                                            titleVisibility: .visible) {
                            Button("Delete", role: .destructive) {
                                monitor.deleteTrainingFrames()
                                trainingFrames = 0
                            }
                        }
                } header: {
                    Text("Training")
                } footer: {
                    Text("While watching, saves a picture whenever something moves in the zone (at most every 2 s) and one every 10 minutes. Find them in Files › On My iPhone › CatWatch › TrainingFrames and AirDrop the folder to your Mac.")
                }

                Section {
                    Stepper(settings.dimAfter == 0 ? "Blank screen: never" : "Blank screen after \(Self.duration(settings.dimAfter))",
                            value: $settings.dimAfter, in: 0...600, step: 30)
                } header: {
                    Text("Screen")
                } footer: {
                    Text("Keep the phone plugged in. Use Guided Access (Settings › Accessibility) so the app can't be closed by accident.")
                }
            }
            .navigationTitle("Settings")
            .onAppear { trainingFrames = TrainingRecorder.frameCount() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    /// Pushover's built-in sounds: https://pushover.net/api#sounds
    static let sounds = ["", "pushover", "bike", "bugle", "cashregister", "classical", "cosmic", "falling",
                         "gamelan", "incoming", "intermission", "magic", "mechanical", "pianobar", "siren",
                         "spacealarm", "tugboat", "alien", "climb", "persistent", "echo", "updown", "vibrate", "none"]

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60)m \(s % 60)s"
    }
}
