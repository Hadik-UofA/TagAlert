//
//  ContentView.swift
//  TagAlert
//
//  Main interface. v2: no hard-coded metrics, demo data is labeled, actions that did
//  nothing were removed, "Play Sound" is renamed to what it does (alert on THIS phone).
//

import SwiftUI
import AVFoundation

extension Color {
    static let brandBG = Color(red: 4/255, green: 9/255, blue: 78/255)          // #04094E
    static let brandCard = Color(red: 18/255, green: 28/255, blue: 104/255)     // #121C68
    static let brandCardRaised = Color(red: 28/255, green: 40/255, blue: 124/255)
}

struct MotionBanner: View {
    @ObservedObject var bluetoothManager: BluetoothManager
    private let amber = Color(red: 240/255, green: 175/255, blue: 70/255)   // #F0AF46

    var body: some View {
        let status = bluetoothManager.motionStatus
        VStack(alignment: .leading, spacing: 8) {
            Label("Movement check is off", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundColor(amber)
            Text(status == "unavailable"
                 ? "This iPhone has no step counter. TagAlert still finds tags but cannot tell whether one is following you."
                 : "TagAlert still finds tags but cannot tell whether one is following you. Apple does not let apps turn this on for you, so please turn on Fitness Tracking yourself. It uses the step counter only, never your location.")
                .font(.subheadline)
                .foregroundColor(.white)
            if status == "restricted" {
                Text("Settings > Privacy & Security > Motion & Fitness > Fitness Tracking")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(amber)
            }
            if status == "denied" {
                Button {
                    bluetoothManager.openMotionSettings()
                } label: {
                    Text("Open TagAlert Settings")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(amber)
                        .foregroundColor(Color.brandBG)
                        .cornerRadius(8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(amber.opacity(0.15))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(amber, lineWidth: 2))
        .cornerRadius(12)
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var bluetoothManager = BluetoothManager()
    @State private var showSettings = false
    @State private var showHistory = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.brandBG.ignoresSafeArea()
                if bluetoothManager.isScanning {
                    RadarRipple()
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                ScrollView {
                    VStack(spacing: 12) {
                        if bluetoothManager.demoMode {
                            DemoBanner()
                        }

                        if ["denied", "restricted", "unavailable"].contains(bluetoothManager.motionStatus) {
                            MotionBanner(bluetoothManager: bluetoothManager)
                        }

                        // Shown only while scanning; when paused, the pulsing Start button says it all
                        if bluetoothManager.isScanning {
                            StatusCardView(bluetoothManager: bluetoothManager)
                        }

                        if bluetoothManager.detectedAirTags.contains(where: { $0.threatLevel == .high || $0.threatLevel == .medium }) {
                            EndTrackingButton(bluetoothManager: bluetoothManager)
                        }

                        DetectionStatsView(bluetoothManager: bluetoothManager)
                        DetectedAirTagsListView(bluetoothManager: bluetoothManager)
                    }
                    .padding()
                }
            }
            .safeAreaInset(edge: .bottom) {
                ScanControlButton(bluetoothManager: bluetoothManager)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { BrandTitle() }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showSettings.toggle() }) { Image(systemName: "gear") }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { showHistory.toggle() }) {
                        Label("Session", systemImage: "chart.bar.xaxis").labelStyle(.titleAndIcon).font(.subheadline)
                    }
                }
            }
            .toolbarBackground(Color.brandBG, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .sheet(isPresented: $showSettings) { SettingsView(bluetoothManager: bluetoothManager) }
            .sheet(isPresented: $showHistory) { HistoryView(bluetoothManager: bluetoothManager) }
        }
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { phase in
            if phase == .active { bluetoothManager.requestMotionPermission() }
        }
        .overlay {
            if bluetoothManager.askToEnableMotion {
                MotionPrompt(bluetoothManager: bluetoothManager)
            } else if bluetoothManager.findPromptTagID != nil {
                FindTagPrompt(bluetoothManager: bluetoothManager)
            }
        }
    }
}

// MARK: - Radar ripple (background while scanning, like the AirDrop search animation)
/// Soft teal rings expand from the top center and fade, echoing the logo. Purely decorative;
/// static (one faint set of rings) when iOS Reduce Motion is on.
struct RadarRipple: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let teal = Color(red: 115/255, green: 198/255, blue: 222/255)
    private let rings = 4
    private let period = 3.6   // seconds for one ring to travel out

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.30)
            let maxR = max(geo.size.width, geo.size.height) * 0.75
            if reduceMotion {
                ZStack {
                    ForEach(0..<rings, id: \.self) { i in
                        let p = Double(i + 1) / Double(rings + 1)
                        Circle().stroke(teal.opacity(0.06), lineWidth: 2)
                            .frame(width: maxR * 2 * p, height: maxR * 2 * p)
                            .position(center)
                    }
                }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in   // 30 fps keeps battery cost low
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    ZStack {
                        ForEach(0..<rings, id: \.self) { i in
                            let p = ((t / period) + Double(i) / Double(rings)).truncatingRemainder(dividingBy: 1)
                            Circle()
                                .stroke(teal.opacity(0.22 * (1 - p)), lineWidth: 2)
                                .frame(width: maxR * 2 * p, height: maxR * 2 * p)
                                .position(center)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Find this tag prompt (once per tag, when it first reaches High)
struct FindTagPrompt: View {
    @ObservedObject var bluetoothManager: BluetoothManager
    private let amber = Color(red: 240/255, green: 175/255, blue: 70/255)
    private let blue = Color(red: 115/255, green: 198/255, blue: 222/255)

    var body: some View {
        let id = bluetoothManager.findPromptTagID ?? ""
        let short = String(id.prefix(8))
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Label("Find This Tag?", systemImage: "speaker.wave.3.fill")
                    .font(.title3.bold())
                    .foregroundColor(.red)
                Text("AirTag-\(short) has been moving with you for over 2 minutes.")
                    .foregroundColor(.white)
                Text("Make it beep for about 15 seconds so you can find it.")
                    .foregroundColor(.white)
                (Text("Only beep when it is safe. ").bold()
                 + Text("If the person who may have planted it is nearby, the sound will tell them it was found."))
                    .font(.system(size: 14))
                    .foregroundColor(amber)
                Button {
                    bluetoothManager.findPromptTagID = nil
                    bluetoothManager.playSound(onTag: id)
                } label: {
                    Text("Beep Now")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                Button {
                    bluetoothManager.findPromptTagID = nil
                } label: {
                    Text("Not Now")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundColor(blue)
                }
            }
            .font(.system(size: 16))
            .padding(20)
            .background(Color.brandCard)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.red, lineWidth: 2))
            .cornerRadius(16)
            .padding(.horizontal, 20)
        }
    }
}

// MARK: - Fitness Tracking prompt (custom so it can use brand colors)
struct MotionPrompt: View {
    @ObservedObject var bluetoothManager: BluetoothManager
    private let amber = Color(red: 240/255, green: 175/255, blue: 70/255)    // #F0AF46
    private let blue = Color(red: 115/255, green: 198/255, blue: 222/255)    // #73C6DE

    private func on(_ s: String) -> Text { Text(s).foregroundColor(amber).bold() }

    private func step(_ n: Int, _ text: Text) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.subheadline.bold())
                .foregroundColor(Color.brandBG)
                .frame(width: 24, height: 24)
                .background(Circle().fill(blue))
            text.font(.system(size: 14)).foregroundColor(.white)
            Spacer(minLength: 0)
        }
    }

    var body: some View {
        let denied = bluetoothManager.motionStatus == "denied"
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Turn On Fitness Tracking?", systemImage: "exclamationmark.triangle.fill")
                        .font(.title3.bold())
                        .foregroundColor(amber)

                    (Text("TagAlert cannot tell whether a tag is following you until ")
                     + Text(denied ? "Motion & Fitness" : "Fitness Tracking").bold()
                     + Text(" is turned ") + on("ON") + Text("."))
                        .foregroundColor(.white)

                    Text("TagAlert uses the step counter only, never your location.")
                        .foregroundColor(blue)

                    Divider().background(Color.white.opacity(0.3))

                    (Text("Apple does not let apps turn this ") + on("ON") + Text(" for you."))
                        .foregroundColor(.white)

                    (Text("To turn ") + Text(denied ? "Motion & Fitness" : "Fitness Tracking").bold()
                     + Text(" ") + on("ON") + Text(", go to:"))
                        .foregroundColor(.white)

                    if denied {
                        step(1, Text("Tap ").foregroundColor(.white) + Text("Open TagAlert Settings").bold() + Text(" below"))
                        step(2, Text("Toggle ") + Text("Motion & Fitness").bold() + Text(" to ") + on("ON"))
                    } else {
                        step(1, Text("Open ") + Text("Settings").bold())
                        step(2, Text("Tap ") + Text("Privacy & Security").bold() + Text(" > ") + Text("Motion & Fitness").bold())
                        step(3, Text("Toggle ") + Text("Fitness Tracking").bold() + Text(" to ") + on("ON"))
                    }

                    if denied {
                        Button {
                            bluetoothManager.askToEnableMotion = false
                            bluetoothManager.openMotionSettings()
                        } label: {
                            Text("Open TagAlert Settings")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(amber)
                                .foregroundColor(Color.brandBG)
                                .cornerRadius(10)
                        }
                    }
                    Button {
                        bluetoothManager.askToEnableMotion = false
                    } label: {
                        Text(denied ? "Not Now" : "OK")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(denied ? Color.clear : amber)
                            .foregroundColor(denied ? blue : Color.brandBG)
                            .cornerRadius(10)
                    }
                }
                .font(.system(size: 16))
                .padding(20)
                .background(Color.brandCard)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(amber, lineWidth: 2))
                .cornerRadius(16)
                .padding(.horizontal, 20)
                .padding(.vertical, 40)
            }
        }
    }
}

// MARK: - Demo banner
struct DemoBanner: View {
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("DEMO DATA: simulated devices, no Bluetooth scanning")
                .font(.caption)
                .fontWeight(.bold)
            Spacer()
        }
        .padding(10)
        .background(Color.yellow.opacity(0.85))
        .foregroundColor(.black)
        .cornerRadius(8)
    }
}

// MARK: - Status Card
struct StatusCardView: View {
    @ObservedObject var bluetoothManager: BluetoothManager

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: statusIcon)
                    .font(.system(size: 26))
                    .foregroundColor(statusColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle).font(.subheadline).fontWeight(.semibold).foregroundColor(.primary)
                    Text(statusMessage).font(.caption).foregroundColor(.secondary).lineLimit(2)
                }
                Spacer()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(Color.brandCard)
            .cornerRadius(12)
            .shadow(radius: 2)
        }
    }

    private var statusIcon: String {
        if !bluetoothManager.isScanning { return "pause.circle.fill" }
        switch bluetoothManager.threatLevel {
        case .none: return "checkmark.shield.fill"
        case .low: return "exclamationmark.shield.fill"
        case .medium: return "exclamationmark.triangle.fill"
        case .high: return "xmark.shield.fill"
        }
    }

    private var statusColor: Color {
        if !bluetoothManager.isScanning { return .gray }
        switch bluetoothManager.threatLevel {
        case .none: return .green
        case .low: return .yellow
        case .medium: return .orange
        case .high: return .red
        }
    }

    private var statusTitle: String {
        if !bluetoothManager.isScanning { return "Scanning Paused" }
        switch bluetoothManager.threatLevel {
        case .none: return "All Clear"
        case .low: return "Low Threat"
        case .medium: return "Medium Threat"
        case .high: return "High Threat"
        }
    }

    private var statusMessage: String {
        if !bluetoothManager.statusNote.isEmpty { return bluetoothManager.statusNote }
        if !bluetoothManager.isScanning { return "Tap Start below" }
        let count = bluetoothManager.detectedAirTags.count
        if count == 0 { return "No Find My trackers detected" }
        if count == 1 { return "1 Find My tracker detected" }
        return "\(count) Find My trackers detected"
    }
}

// MARK: - Stats (all live values)
struct DetectionStatsView: View {
    @ObservedObject var bluetoothManager: BluetoothManager

    var body: some View {
        HStack(spacing: 16) {
            StatBox(title: "Detected", value: "\(bluetoothManager.detectedAirTags.count)",
                    icon: "wave.3.right", color: .blue)
            StatBox(title: "Scans", value: "\(bluetoothManager.scanCount)",
                    icon: "dot.radiowaves.left.and.right", color: .green)
        }
    }
}

struct StatBox: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 22)).foregroundColor(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.title3).fontWeight(.bold)
                Text(title).font(.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(Color.brandCard)
        .cornerRadius(12)
        .shadow(radius: 2)
    }
}

// MARK: - Detected list
struct DetectedAirTagsListView: View {
    @ObservedObject var bluetoothManager: BluetoothManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Detected Devices").font(.headline).padding(.horizontal, 4)

            if bluetoothManager.detectedAirTags.isEmpty {
                EmptyStateView()
            } else {
                VStack(spacing: 8) {
                    ForEach(bluetoothManager.detectedAirTags) { airTag in
                        AirTagRowView(airTag: airTag, bluetoothManager: bluetoothManager)
                    }
                }
            }
        }
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 50)).foregroundColor(.secondary)
            Text("No Trackers Detected").font(.headline).foregroundColor(.secondary)
            Text("Start scanning to monitor your surroundings")
                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

struct AirTagRowView: View {
    let airTag: DetectedAirTag
    @ObservedObject var bluetoothManager: BluetoothManager
    @State private var showingActions = false
    @State private var showingGuide = false

    var body: some View {
        Button(action: { showingActions = true }) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(airTag.identifier).font(.headline).foregroundColor(.primary)

                    HStack(spacing: 12) {
                        Label("\(airTag.rssi) dBm", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.caption)
                        Label(airTag.persistenceLevel, systemImage: "clock.fill")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)

                    if !airTag.moveNote.isEmpty {
                        Text(airTag.moveNote)
                            .font(.caption)
                            .foregroundColor(airTag.movedWithYou ? .orange : .secondary)
                    }

                    Text("Last seen: \(formatDate(airTag.lastSeen))")
                        .font(.caption2).foregroundColor(.secondary)

                    if bluetoothManager.soundingTagID == airTag.id, let status = bluetoothManager.soundStatus {
                        Text(status).font(.caption2).foregroundColor(.orange)
                    }
                }

                Spacer()

                VStack(spacing: 4) {
                    Circle().fill(threatColor(airTag.threatLevel)).frame(width: 12, height: 12)
                    Text(airTag.threatLevel.rawValue)
                        .font(.caption2).foregroundColor(threatColor(airTag.threatLevel))
                }
            }
            .padding()
            .background(Color.brandCardRaised)
            .cornerRadius(8)
            // Colored edge for Medium and High so the risky tag stands out in the list
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(airTag.threatLevel >= .medium ? threatColor(airTag.threatLevel) : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .alert("Tracker Actions", isPresented: $showingActions) {
            Button("Make This Tag Beep") { bluetoothManager.playSound(onTag: airTag.id) }
            Button("Safety and Reporting Guide") { showingGuide = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Make This Tag Beep asks the tracker to sound for about 15 seconds. It works only when the tag is separated from its owner and in range.")
        }
        .sheet(isPresented: $showingGuide) { SafetyGuideView() }
    }

    private func threatColor(_ level: ThreatLevel) -> Color {
        switch level {
        case .none: return .green
        case .low: return .yellow
        case .medium: return .orange
        case .high: return .red
        }
    }

    private func formatDate(_ date: Date) -> String {
        if date > Date().addingTimeInterval(-3) { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Brand title (uses the TagAlertLogo image if present, otherwise text)
struct BrandTitle: View {
    var body: some View {
        if UIImage(named: "TagAlertLogo") != nil {
            Image("TagAlertLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 30)
                .accessibilityLabel("TagAlert")
        } else {
            Text("TagAlert").font(.headline)
        }
    }
}

// MARK: - Scan control
struct ScanControlButton: View {
    @ObservedObject var bluetoothManager: BluetoothManager

    var body: some View {
        Button(action: {
            if bluetoothManager.isScanning {
                bluetoothManager.stopScanning()
            } else {
                bluetoothManager.startScanning()
            }
        }) {
            HStack {
                Image(systemName: bluetoothManager.isScanning ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
                Text(bluetoothManager.isScanning ? "Stop Scanning" : "Start Scanning")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            // Stop is teal so red stays reserved for High threat
            .background(bluetoothManager.isScanning ? Color(red: 115/255, green: 198/255, blue: 222/255) : Color.blue)
            .foregroundColor(bluetoothManager.isScanning ? Color.brandBG : .white)
            .cornerRadius(12)
            .shadow(radius: 4)
        }
    }
}

// MARK: - Tracking banner
struct EndTrackingButton: View {
    @ObservedObject var bluetoothManager: BluetoothManager
    @State private var showingConfirmation = false
    @State private var showingGuide = false
    private var isHigh: Bool { bluetoothManager.detectedAirTags.contains { $0.threatLevel == .high } }

    var body: some View {
        Button(action: { showingConfirmation = true }) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 24))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Possible Tracking").font(.headline).fontWeight(.bold)
                    Text("Tap for safety steps").font(.subheadline)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 16, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .padding()
            // Red only when a tag is High; amber for Medium
            .background(isHigh ? Color.red : Color(red: 240/255, green: 175/255, blue: 70/255))
            .foregroundColor(isHigh ? .white : Color.brandBG)
            .cornerRadius(12)
            .shadow(radius: 8)
        }
        .alert("Possible Tracking", isPresented: $showingConfirmation) {
            Button("Call 911", role: .destructive) {
                if let url = URL(string: "tel://911") { UIApplication.shared.open(url) }
            }
            Button("Safety and Reporting Guide") { showingGuide = true }
            Button("Clear Detected List") { bluetoothManager.clearDetectedAirTags() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("If you feel unsafe, move to a public place and call 911. Do not confront anyone.")
        }
        .sheet(isPresented: $showingGuide) { SafetyGuideView() }
    }
}

// MARK: - Safety guide (static guidance, no device control)
struct SafetyGuideView: View {
    @Environment(\.dismiss) var dismiss
    private let teal = Color(red: 115/255, green: 198/255, blue: 222/255)   // #73C6DE
    private let amber = Color(red: 240/255, green: 175/255, blue: 70/255)   // #F0AF46

    /// Section header in brand color (urgent section amber, the rest teal)
    private func header(_ t: String, urgent: Bool = false) -> some View {
        Text(t).font(.subheadline.weight(.semibold)).textCase(nil)
            .foregroundColor(urgent ? amber : teal)
    }

    var body: some View {
        NavigationView {
            List {
                Section(header: header("If you feel unsafe", urgent: true)) {
                    Text("Move to a public place and call 911. Do not confront anyone.")
                }
                Section(header: header("Document before you act")) {
                    Text("Screenshot this app showing the signal strength and time.")
                    Text("Photograph the tracker and where you found it before touching it.")
                    Text("Note dates, places and times you noticed it.")
                }
                Section(header: header("Finding it")) {
                    Text("Check bags, coat pockets, the car (wheel wells, under seats, bumpers) and personal items.")
                    Text("Signal strength rising as you move closer means you are approaching it.")
                }
                Section(header: header("Disabling an AirTag")) {
                    Text("Per Apple: press down on the battery cover and turn it counter-clockwise, then remove the battery. Photograph it first and keep it as evidence.")
                }
                Section(header: header("Reporting")) {
                    Text("Contact local law enforcement and give them your documentation.")
                    Text("National Domestic Violence Hotline (US): 1-800-799-7233")
                }
            }
            .navigationTitle("Safety Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Title in AirTag light blue
                ToolbarItem(placement: .principal) {
                    Text("Safety Guide").font(.headline).foregroundColor(teal)
                }
                ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View { ContentView() }
}
