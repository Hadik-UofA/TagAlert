//
//  SettingsView.swift
//  TagAlert
//
//  Settings, Test Mode (demo toggle, markers, log export), privacy text.
//  v2: removed the hard-coded "92% accuracy" and "40% efficiency" claims.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var bluetoothManager: BluetoothManager
    @Environment(\.dismiss) var dismiss
    @State private var markerText: String = ""
    @State private var clearedNote: String = ""
    @State private var markerNote: String = ""
    @State private var testNote: String = ""
    @FocusState private var markerFocused: Bool

    private func addMarker() {
        let label = markerText.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return }
        bluetoothManager.mark(label)
        let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        markerNote = "Marker \"\(label)\" added at \(t)"
        markerText = ""
        markerFocused = false
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Scanning")) {
                    Toggle("Adaptive Scanning", isOn: $bluetoothManager.adaptiveScanning)
                        .onChange(of: bluetoothManager.adaptiveScanning) { _ in
                            bluetoothManager.saveSettings()
                        }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Base Scan Interval: \(Int(bluetoothManager.scanInterval))s")
                            .font(.subheadline)
                        Slider(value: $bluetoothManager.scanInterval, in: 10...60, step: 5)
                            .onChange(of: bluetoothManager.scanInterval) { _ in
                                bluetoothManager.saveSettings()
                            }
                        Text("Each cycle scans for 5 seconds, then waits. Shorter is more responsive but uses more battery. With Adaptive Scanning on, the interval halves (down to 10 s) once a tag is found, and lengthens when the battery is low. Changes apply from the next cycle.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }

                Section(header: Text("Live Status")) {
                    HStack {
                        Text("Effective interval")
                        Spacer()
                        Text("\(Int(bluetoothManager.currentInterval))s").foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Battery")
                        Spacer()
                        Text("\(Int((bluetoothManager.batteryLevel * 100).rounded()))%").foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Scan cycles this launch")
                        Spacer()
                        Text("\(bluetoothManager.scanCount)").foregroundColor(.secondary)
                    }
                }

                Section(header: Text("Find the Tag"),
                        footer: Text("Off by default. When a tag first reaches High, TagAlert asks before beeping, because the sound can tell a nearby person who planted the tag that it was found. Turn on only if you know you are alone.")) {
                    Toggle("Beep automatically at High", isOn: $bluetoothManager.autoBeepAtHigh)
                }

                Section(header: Text("Movement"),
                        footer: Text("Uses the step counter and activity type, not location. Levels: Low under 1 minute, Medium 1 to 2 minutes, High 2 minutes or more. With this on, a tag stays Low until it travels with you (50 m walked or 60 s in a vehicle, and seen in most scans along the way). With it off, levels follow time only and High is capped at Medium.")) {
                    Toggle("Require movement for Medium and High", isOn: $bluetoothManager.requireMovement)
                }

                Section(header: Text("Notifications"),
                        footer: Text("Notification volume follows the ringer. If the ring switch is on silent or a Focus is on, iOS mutes the alert sound.")) {
                    NavigationLink("Notification Settings") { NotificationSettingsView() }
                    Picker("Alert sound", selection: $bluetoothManager.alertSound) {
                        ForEach(BluetoothManager.alertSounds, id: \.file) { s in
                            Text(s.name).tag(s.file)
                        }
                    }
                    .onChange(of: bluetoothManager.alertSound) { _ in bluetoothManager.previewAlertSound() }
                    Button {
                        bluetoothManager.previewAlertSound()
                    } label: {
                        Label("Play sound", systemImage: "speaker.wave.3.fill")
                    }
                    Button {
                        bluetoothManager.sendTestNotification()
                        testNote = "Test alert coming in 3 seconds"
                    } label: {
                        Label("Send test alert", systemImage: "bell.badge.fill")
                    }
                    if !testNote.isEmpty {
                        Label(testNote, systemImage: "checkmark.circle.fill").foregroundColor(.green)
                    }
                }

                Section(header: Text("Test Mode"),
                        footer: Text("Demo data is simulated. It is labeled on screen and tagged DEMO in the log. Never use demo data for measurements.")) {
                    Toggle("Use simulated demo data", isOn: $bluetoothManager.demoMode)
                        .onChange(of: bluetoothManager.demoMode) { _ in
                            bluetoothManager.stopScanning()
                            bluetoothManager.clearDetectedAirTags()
                        }

                    TextField("Marker label, e.g. INTRO d=10m t=1", text: $markerText)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .focused($markerFocused)
                        .submitLabel(.done)
                        .onSubmit { addMarker() }

                    Button("Add marker to log") { addMarker() }
                        .disabled(markerText.trimmingCharacters(in: .whitespaces).isEmpty)

                    if !markerNote.isEmpty {
                        Label(markerNote, systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }

                    HStack {
                        Text("Log rows")
                        Spacer()
                        Text("\(bluetoothManager.logRowCount)").foregroundColor(.secondary)
                    }

                    ShareLink(item: bluetoothManager.logFileURL) {
                        Label("Export CSV log", systemImage: "square.and.arrow.up")
                    }
                }

                Section(header: Text("Data"),
                        footer: Text("Stop scanning before clearing. While scanning, tags in range reappear within seconds.")) {
                    Button(action: {
                        let n = bluetoothManager.detectedAirTags.count
                        bluetoothManager.clearDetectedAirTags()
                        let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                        clearedNote = "Cleared \(n) tag\(n == 1 ? "" : "s") at \(t)"
                    }) {
                        HStack {
                            Image(systemName: "trash").foregroundColor(.red)
                            Text("Clear Detected List").foregroundColor(.red)
                        }
                    }
                    if !clearedNote.isEmpty {
                        Label(clearedNote, systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                    if bluetoothManager.isScanning {
                        Label("Scanning is on", systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                    }
                }

                Section(header: Text("About")) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("\(AppInfo.version) build \(AppInfo.build)").foregroundColor(.secondary)
                    }
                    NavigationLink("Privacy") { PrivacyPolicyView() }
                    NavigationLink("How It Works") { HowItWorksView() }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Notification Settings
struct NotificationSettingsView: View {
    @AppStorage("notifyLowThreat") private var notifyLowThreat = false
    @AppStorage("notifyMediumThreat") private var notifyMediumThreat = true
    @AppStorage("notifyHighThreat") private var notifyHighThreat = true

    var body: some View {
        Form {
            Section(header: Text("Alert me at")) {
                Toggle("Low Threat", isOn: $notifyLowThreat)
                Toggle("Medium Threat", isOn: $notifyMediumThreat)
                Toggle("High Threat", isOn: $notifyHighThreat)
            }
            Section(footer: Text("One notification per tracker per threat level. Alerts appear while the app is open; scanning does not run in the background.")) {
                EmptyView()
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Privacy
struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Privacy").font(.title).fontWeight(.bold)
                Divider()

                Text("What stays on your phone").font(.headline)
                Text("All detection happens locally. TagAlert has no account, no server and sends no data off the device.")

                Text("Test log").font(.headline).padding(.top, 8)
                Text("This test build writes a CSV log to the app's Documents folder. It contains shortened identifiers of nearby trackers, signal strength and timestamps. Identifiers are assigned by iOS and change between phones. The log leaves the phone only if you export it.")

                Text("Permissions").font(.headline).padding(.top, 8)
                Text("Bluetooth: required to scan. Notifications: optional.")
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - How It Works
struct HowItWorksView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("How TagAlert Works").font(.title).fontWeight(.bold)
                Divider()

                FeatureCard(icon: "antenna.radiowaves.left.and.right", title: "Scanning",
                            description: "Every cycle the app listens for 5 seconds for Apple Find My advertisements, then waits. The wait shortens when trackers are present and lengthens when the battery is low.")

                FeatureCard(icon: "clock", title: "Persistence",
                            description: "A tracker seen for under 1 minute is Transient, 1 to 2 minutes is Tracking, over 2 minutes is Persistent. Time is counted from when the tracker was first seen.")

                FeatureCard(icon: "chart.line.uptrend.xyaxis", title: "Threat levels",
                            description: "Low: newly seen. Medium: seen for over a minute, or strong signal with frequent detections. High: Persistent with signal stronger than -60 dBm.")

                FeatureCard(icon: "exclamationmark.triangle", title: "Limits",
                            description: "Foreground only. The app cannot tell a tracker that follows you from one that is stationary near you. Trackers that rotate their Bluetooth address appear as new devices.")
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct FeatureCard: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 30)).foregroundColor(.blue).frame(width: 50)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(description).font(.body).foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View { SettingsView(bluetoothManager: BluetoothManager()) }
}
