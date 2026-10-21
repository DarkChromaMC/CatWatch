import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var monitor: MonitorController
    @Environment(\.dismiss) private var dismiss

    @State private var testResult: String?
    @State private var testing = false

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
                    Toggle("Ultra-wide lens", isOn: $settings.useUltraWide)
                        .onChange(of: settings.useUltraWide) { _, _ in Task { await monitor.restart() } }
                } header: {
                    Text("Detection")
                } footer: {
                    Text("Lower confidence catches more but may false-alarm. Requiring 2+ sightings filters one-off glitches. Ultra-wide sees more of the yard but makes the cat smaller.")
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
