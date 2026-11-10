//
//  BluetoothManager.swift
//  TagAlert
//
//  Core Bluetooth manager: live Find My advertisement scanning, threat scoring,
//  and a CSV test log so every reported number can be traced to raw evidence.
//
//  v2 changes vs. Dec 2025 version:
//   - demoMode defaults to OFF and is a visible, persisted toggle (Settings > Test Mode)
//   - CBCentralManager is always created (old code crashed on Stop in demo mode)
//   - Only advertisements with the Apple Find My payload header (4C 00 12 19) or the
//     FD44 service count as candidates. Old code matched ANY Apple device.
//   - Adaptive interval is re-evaluated after every scan cycle
//   - Notifications fire once per tag per threat level, honor the Settings toggles,
//     and display while the app is in the foreground
//   - CSV log in Documents (event, tag, RSSI, hex header, threat, battery, mode)
//
//  Threat thresholds are UNCHANGED from the original so the test measures what was built.
//

import Foundation
import CoreBluetooth
import Combine
import UserNotifications
import UIKit
import CoreMotion
import AVFoundation

// MARK: - Supporting Types
enum ThreatLevel: String, Comparable {
    case none = "None"
    case low = "Low"
    case medium = "Medium"
    case high = "High"

    static func < (lhs: ThreatLevel, rhs: ThreatLevel) -> Bool {
        let order: [ThreatLevel] = [.none, .low, .medium, .high]
        guard let l = order.firstIndex(of: lhs), let r = order.firstIndex(of: rhs) else { return false }
        return l < r
    }
}

struct DetectedAirTag: Identifiable {
    let id: String
    let identifier: String
    let rssi: Int
    let lastSeen: Date
    let firstSeen: Date
    let detectionCount: Int
    let threatLevel: ThreatLevel
    let persistenceLevel: String
    var movedWithYou: Bool = false
    var moveNote: String = ""
}

// MARK: - Version (from Xcode: Target > General > Identity)
enum AppInfo {
    // Update with every delivered change: version number, then build letter (5a ... 5z, then 6a, 6b, ...)
    static let version = "6"
    static let build = "b"
    static var label: String { "Version \(version) build \(build)" }
}

// MARK: - Motion (step counter and activity type, no location)
/// Counts walking distance and time in a vehicle since scanning started, using Core Motion.
/// No GPS and no location permission. Needs the Motion & Fitness permission.
final class MotionTracker {
    private let pedometer = CMPedometer()
    private let activity = CMMotionActivityManager()
    private(set) var walkMeters: Double = 0
    private var autoAccum: Double = 0
    private var vehicleSince: Date?
    private(set) var running = false

    var canGate: Bool {
        CMPedometer.isDistanceAvailable() && CMPedometer.authorizationStatus() == .authorized
    }

    /// Asking for pedometer data is what makes iOS show the Motion & Fitness prompt.
    func requestPermission(_ done: @escaping () -> Void) {
        guard CMPedometer.isDistanceAvailable() else { done(); return }
        pedometer.queryPedometerData(from: Date().addingTimeInterval(-60), to: Date()) { _, _ in
            DispatchQueue.main.async { done() }
        }
    }

    var automotiveSeconds: Double {
        autoAccum + (vehicleSince.map { Date().timeIntervalSince($0) } ?? 0)
    }

    func start() {
        guard !running, CMPedometer.isDistanceAvailable() else { return }
        running = true
        walkMeters = 0; autoAccum = 0; vehicleSince = nil
        pedometer.startUpdates(from: Date()) { [weak self] data, _ in
            guard let d = data?.distance?.doubleValue else { return }
            DispatchQueue.main.async { self?.walkMeters = d }
        }
        if CMMotionActivityManager.isActivityAvailable() {
            activity.startActivityUpdates(to: .main) { [weak self] a in
                guard let self = self, let a = a else { return }
                let inCar = a.automotive && a.confidence != .low
                let now = Date()
                if inCar, self.vehicleSince == nil {
                    self.vehicleSince = now
                } else if !inCar, let s = self.vehicleSince {
                    self.autoAccum += now.timeIntervalSince(s)
                    self.vehicleSince = nil
                }
            }
        }
    }

    func stop() {
        pedometer.stopUpdates()
        activity.stopActivityUpdates()
        if let s = vehicleSince { autoAccum += Date().timeIntervalSince(s); vehicleSince = nil }
        running = false
    }
}

struct AirTagCacheEntry {
    let identifier: String
    let firstSeen: Date
    var lastSeen: Date
    var rssi: Int
    var detectionCount: Int
}

// MARK: - BluetoothManager
final class BluetoothManager: NSObject, ObservableObject {

    // MARK: Published state
    @Published var isScanning = false
    @Published var detectedAirTags: [DetectedAirTag] = []
    @Published var threatLevel: ThreatLevel = .none
    @Published var scanInterval: TimeInterval = 15.0
    @Published var adaptiveScanning: Bool = true
    @Published var batteryLevel: Float = 1.0
    @Published var scanCount: Int = 0
    @Published var currentInterval: TimeInterval = 15.0
    @Published var logRowCount: Int = 0
    @Published var statusNote: String = ""
    @Published var demoMode: Bool = false {
        didSet { userDefaults.set(demoMode, forKey: "demoMode") }
    }

    // MARK: Private state
    private var centralManager: CBCentralManager!
    private var scanTimer: Timer?
    private var cycleID = 0
    private var airTagCache: [String: AirTagCacheEntry] = [:]
    private var otherAppleSeen = Set<String>()
    // GATT probe state (see "Scan cycle" comment)
    private let airTagServiceUUID = CBUUID(string: "7DFC9000-7D1C-4951-86AA-8D9728F8D66C")
    private var candidatePeripherals: [String: CBPeripheral] = [:]

    // Movement check: does the tag travel with the user? (step counter and activity type)
    private let motion = MotionTracker()
    private struct MoveState {
        var startWalk: Double; var startAuto: Double; var lastSeen: Date
        var lastWalk: Double = 0, lastAuto: Double = 0   // step-counter values at the last sighting
        var cycles = 0        // scan cycles since the window started
        var seenCycles = 0    // of those, cycles in which the device was seen
    }
    private var seenThisCycle: Set<String> = []
    private let movePresence = 0.6          // must be seen in at least 60% of scan cycles while moving (pocket tag in B2: 11 of 14 = 79%)
    private let moveMinCycles = 4           // and over at least 4 cycles
    private let moveStillSeconds = 25.0     // and seen within the last 25 s (about 2 scan cycles)
    private var moveState: [String: MoveState] = [:]
    private var lastMoved: [String: Bool] = [:]
    private let moveWalkMeters = 50.0       // walking distance with the tag present (was 100 m; cut after B2 once the presence rule guarded against passed tags)
    private let moveVehicleSeconds = 60.0   // or time in a vehicle with the tag present
    private let moveGapSeconds = 45.0       // tag unseen this long starts a new window (was 120 s; a loop walk passed the same parked tag twice within 120 s)
    // Alert sound for notifications. Files must be in the app bundle (.wav, under 30 s).
    static let alertSounds: [(file: String, name: String)] = [
        ("TagAlert_Pulse.wav", "Radar Pulse (default)"),
        ("TagAlert_Alarm.wav", "Alarm"),
        ("TagAlert_Siren.wav", "Siren"),
        ("TagAlert_Chime.wav", "Chime"),
        ("default", "iPhone Default")
    ]
    // Default is Radar Pulse (matches the logo). Older builds saved Alarm as the default; reset once.
    @Published var alertSound: String = {
        let d = UserDefaults.standard
        if !d.bool(forKey: "pulseDefaultMigrated") {
            d.set(true, forKey: "pulseDefaultMigrated")
            d.set("TagAlert_Pulse.wav", forKey: "alertSound")
        }
        return d.string(forKey: "alertSound") ?? "TagAlert_Pulse.wav"
    }() {
        didSet { UserDefaults.standard.set(alertSound, forKey: "alertSound") }
    }
    private var previewPlayer: AVAudioPlayer?

    /// Plays the chosen alert sound now, even with the ring switch on silent.
    func previewAlertSound() {
        guard alertSound != "default" else {
            AudioServicesPlaySystemSound(1007)   // close to the iOS default notification tone
            return
        }
        let parts = alertSound.split(separator: ".")
        guard parts.count == 2,
              let url = Bundle.main.url(forResource: String(parts[0]), withExtension: String(parts[1])) else {
            statusNote = "Sound file \(alertSound) is not in the app. Add it in Xcode (Target Membership)."
            return
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        previewPlayer = try? AVAudioPlayer(contentsOf: url)
        previewPlayer?.play()
    }

    /// Sends a real notification in 3 seconds so the sound can be heard as users will hear it.
    func sendTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Test alert"
        content.body = "This is how a TagAlert warning will sound."
        content.sound = notificationSound()
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger))
        log("TEST_NOTIFY", note: "sound=\(alertSound)")
    }

    private func notificationSound() -> UNNotificationSound {
        alertSound == "default" ? .default : UNNotificationSound(named: UNNotificationSoundName(alertSound))
    }

    /// "ok", "undetermined", "denied", "restricted" or "unavailable"
    @Published var motionStatus: String = "undetermined"
    /// Set once when a tag first reaches High, so the UI can offer "Find this tag?" (beep)
    @Published var findPromptTagID: String? = nil
    /// Off by default: a beep can alert a nearby person who planted the tag that it was found
    @Published var autoBeepAtHigh: Bool = UserDefaults.standard.bool(forKey: "autoBeepAtHigh") {
        didSet { UserDefaults.standard.set(autoBeepAtHigh, forKey: "autoBeepAtHigh") }
    }
    private var highHandled: Set<String> = []
    /// Probing starts about 1 s into the first scan (enough to rank candidates by signal)
    /// instead of waiting for the 5 s scan window to end, and confirmed tags show immediately.
    private var sessionStartedAt = Date.distantPast
    @Published var requireMovement: Bool = UserDefaults.standard.object(forKey: "requireMovement") as? Bool ?? true {
        didSet { UserDefaults.standard.set(requireMovement, forKey: "requireMovement") }
    }

    // Sound command (own implementation of the documented AirTag GATT sound characteristic)
    private let soundCharacteristicUUID = CBUUID(string: "7DFC9001-7D1C-4951-86AA-8D9728F8D66C")
    private let soundStartCommand = Data([0xAF])
    private var confirmedPeripherals: [String: CBPeripheral] = [:]   // kept across cycles
    private var soundID: String?
    private var soundTimeout: DispatchWorkItem?
    @Published var soundStatus: String? = nil          // shown in the UI
    @Published var soundingTagID: String? = nil
    private var candidateRSSI: [String: Int] = [:]
    /// When each bare candidate was first and last seen. A tag's time and movement count from its
    /// first sighting, not from the moment its probe finished (the probe can wait in a queue).
    private var candidateSeen: [String: (first: Date, last: Date)] = [:]
    private var probeResult: [String: Bool] = [:]      // true = offers the AirTag service
    private var probeAttempts: [String: Int] = [:]
    /// Devices whose probes timed out are retried later instead of being written off for the
    /// whole session (a weak AirTag, 8825D224, was missed this way in walk B4)
    private var retryAfter: [String: Date] = [:]
    /// Quick retries first, then back off: 10 s, 20 s, 40 s, then every 60 s.
    /// A weak tag gets several tries within 4 scans; a device that never answers costs little.
    private var retryRound: [String: Int] = [:]
    private func retryDelay(_ pid: String) -> TimeInterval {
        let r = retryRound[pid, default: 0]
        return min(60, 10 * pow(2, Double(r)))
    }
    /// When each device joined the queue; one waiting too long goes next even if its signal is weak
    private var queuedAt: [String: Date] = [:]
    private let maxQueueWait: TimeInterval = 45
    private var probeQueue: [String] = []
    private var probingID: String?
    private var probeTimeout: DispatchWorkItem?
    private let probeTimeoutSeconds: TimeInterval = 6   // was 8; confirmed probes took about 1 to 4 s
    private let weakProbeTimeoutSeconds: TimeInterval = 10  // weak signal (-85 dBm or below) gets longer to connect
    private let maxProbeAttempts = 2
    private var allSeen = Set<String>()                       // every distinct peripheral this cycle
    private var companySeen: [String: Set<String>] = [:]      // company ID hex -> peripherals this cycle
    private var lastLoggedThreat: [String: ThreatLevel] = [:]
    private var notifiedLevel: [String: ThreatLevel] = [:]
    private var loggedDetected = Set<String>()
    private let userDefaults = UserDefaults.standard

    private let scanWindow: TimeInterval = 5.0
    private let findMyServiceUUID = CBUUID(string: "FD44")

    // CSV log
    private let logQueue = DispatchQueue(label: "tagalert.log")
    private(set) var logFileURL: URL
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: Motion permission
    /// Set when Motion & Fitness is off, so the UI can ask the user to turn it on.
    @Published var askToEnableMotion = false
    private var askedThisLaunch = false

    func refreshMotionStatus() {
        let before = motionStatus
        if !CMPedometer.isDistanceAvailable() {
            motionStatus = "unavailable"
        } else {
            switch CMPedometer.authorizationStatus() {
            case .authorized: motionStatus = "ok"
            case .notDetermined: motionStatus = "undetermined"
            case .restricted: motionStatus = "restricted"   // Fitness Tracking is off for the whole phone
            default: motionStatus = "denied"
            }
        }
        if before != motionStatus { log("MOTION", note: "permission=\(motionStatus)") }
        // Just turned on while scanning: restart the step counter so movement starts counting now
        if before != "ok", motionStatus == "ok", isScanning {
            motion.stop(); motion.start()
            moveState.removeAll(); lastMoved.removeAll()
        }
    }

    /// Called at launch and whenever the app comes back to the foreground.
    func requestMotionPermission() {
        motion.requestPermission { [weak self] in
            guard let self = self else { return }
            self.refreshMotionStatus()
            if (self.motionStatus == "restricted" || self.motionStatus == "denied") && !self.askedThisLaunch {
                self.askedThisLaunch = true
                self.askToEnableMotion = true
            }
        }
    }

    func openMotionSettings() {
        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
    }

    // MARK: Init
    override init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd_HHmmss"
        logFileURL = docs.appendingPathComponent("tagalert_log_\(stamp.string(from: Date())).csv")
        super.init()

        demoMode = userDefaults.bool(forKey: "demoMode")
        loadSettings()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        UNUserNotificationCenter.current().delegate = self
        requestNotificationPermission()
        refreshMotionStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.requestMotionPermission() }
        setupBatteryMonitoring()

        writeLogHeader()
    }

    // MARK: Public API
    func startScanning() {
        guard !isScanning else { return }
        isScanning = true
        statusNote = ""
        fingerprinted.removeAll()
        resetProbeState()
        moveState.removeAll()
        lastMoved.removeAll()
        seenThisCycle.removeAll()
        highHandled.removeAll()
        refreshMotionStatus()
        motion.start()
        sessionStartedAt = Date()
        log("SESSION_START", note: (demoMode ? "demo data" : "live scan") + " app=\(AppInfo.version) build=\(AppInfo.build)")
        log("MOTION", note: "available=\(CMPedometer.isDistanceAvailable()) can_gate=\(motion.canGate) require_movement=\(requireMovement)")

        if demoMode {
            generateDemoAirTags()
            setupDemoTimer()
            return
        }

        guard centralManager.state == .poweredOn else {
            isScanning = false
            statusNote = "Bluetooth is not powered on or not authorized"
            log("ERROR", note: "bluetooth state \(centralManager.state.rawValue)")
            return
        }
        runScanCycle()
    }

    func stopScanning() {
        guard isScanning else { return }
        isScanning = false
        cycleID += 1
        if centralManager.isScanning { centralManager.stopScan() }
        scanTimer?.invalidate()
        scanTimer = nil
        resetProbeState()
        motion.stop()
        log("SESSION_STOP")
    }

    func clearDetectedAirTags() {
        log("CLEAR", note: "tags_cleared=\(detectedAirTags.count) scanning=\(isScanning)")
        detectedAirTags.removeAll()
        airTagCache.removeAll()
        moveState.removeAll()
        lastMoved.removeAll()
        seenThisCycle.removeAll()
        lastLoggedThreat.removeAll()
        notifiedLevel.removeAll()
        highHandled.removeAll()
        findPromptTagID = nil
        loggedDetected.removeAll()
        updateThreatLevel()
    }

    /// Writes a labeled marker row, e.g. "INTRO d=10m t=3"
    func mark(_ label: String) {
        log("MARK", note: label)
    }

    func saveSettings() {
        userDefaults.set(scanInterval, forKey: "scanInterval")
        userDefaults.set(adaptiveScanning, forKey: "adaptiveScanning")
    }

    // MARK: Scan cycle (live)
    // iOS does not expose Apple's Find My advertisement payload to apps. An AirTag shows up as a "bare"
    // peripheral: connectable, no name, no manufacturer data, no service UUIDs, no service data.
    // So the scan collects bare candidates and the prober (below) connects to each one and asks
    // whether it offers the AirTag GATT service. That GATT check is the detection.
    private var fingerprinted = Set<String>()

    private func runScanCycle() {
        guard isScanning, !demoMode else { return }
        cycleID += 1
        let thisCycle = cycleID
        otherAppleSeen.removeAll()
        allSeen.removeAll()
        companySeen.removeAll()
        log("SCAN_START")

        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + scanWindow) { [weak self] in
            guard let self = self, self.isScanning, self.cycleID == thisCycle else { return }
            self.centralManager.stopScan()
            self.finishCycle()
        }
    }

    private func finishCycle() {
        scanCount += 1
        // Presence tally: a tag that travels with the user is seen in nearly every cycle
        for id in moveState.keys {
            moveState[id]!.cycles += 1
            if seenThisCycle.contains(id) { moveState[id]!.seenCycles += 1 }
        }
        seenThisCycle.removeAll()
        processCachedAirTags()
        let companies = companySeen
            .map { "\($0.key):\($0.value.count)" }
            .sorted()
            .joined(separator: "|")
        let confirmed = probeResult.values.filter { $0 }.count
        log("SCAN_END", count: detectedAirTags.count,
            note: "all_peripherals=\(allSeen.count) bare_candidates=\(candidateRSSI.count) probe_queue=\(probeQueue.count) probed=\(probeResult.count) airtags_confirmed=\(confirmed) company_ids=\(companies)")
        log("MOTION", note: "walk_m=\(Int(motion.walkMeters)) vehicle_s=\(Int(motion.automotiveSeconds))")
        startNextProbe()
        scheduleNextCycle()
    }

    private func scheduleNextCycle() {
        let interval = adaptiveScanning ? calculateAdaptiveInterval() : scanInterval
        currentInterval = interval
        let gap = max(1.0, interval - scanWindow)
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: gap, repeats: false) { [weak self] _ in
            self?.runScanCycle()
        }
    }

    private func calculateAdaptiveInterval() -> TimeInterval {
        var interval = scanInterval
        if batteryLevel < 0.2 {
            interval *= 2.0
        } else if batteryLevel < 0.5 {
            interval *= 1.5
        }
        if !detectedAirTags.isEmpty {
            interval = max(10.0, interval * 0.5)   // faster updates once a tag is found
        }
        return interval
    }

    // MARK: Scoring (thresholds unchanged from original)
    private func processCachedAirTags() {
        var updated: [DetectedAirTag] = []
        let now = Date()

        for (identifier, entry) in airTagCache {
            guard now.timeIntervalSince(entry.lastSeen) < 300 else { continue }

            let persistence = calculatePersistence(for: entry)
            var threat = calculateThreatLevel(for: entry, persistence: persistence)
            let short = String(identifier.prefix(8))

            // Movement check: without evidence the tag travels with the user, cap at Low
            let mv = movement(for: identifier)
            let gating = requireMovement && motion.canGate && !demoMode
            if gating && !mv.moved && threat > .low { threat = .low }
            // No movement evidence available (Fitness Tracking off, or the setting is off): High needs movement, so cap at Medium
            if !gating && !demoMode && threat == .high { threat = .medium }
            let moveNote: String
            if demoMode { moveNote = "" }
            else if !motion.canGate { moveNote = "Movement unavailable (allow Motion & Fitness)" }
            else if mv.moved { moveNote = mv.walkM >= Int(moveWalkMeters) ? "Moved with you: \(mv.walkM) m" : "Moved with you: \(mv.autoS) s in a vehicle" }
            else if Date().timeIntervalSince(entry.lastSeen) > moveStillSeconds { moveNote = "No longer nearby, not counted as moving with you" }
            else if mv.walkM >= Int(moveWalkMeters) { moveNote = "Seen only now and then (\(mv.presencePct)% of scans), not counted as moving with you" }
            else { moveNote = "Not moving with you yet (\(mv.walkM) m together)" }

            updated.append(DetectedAirTag(
                id: identifier,
                identifier: "AirTag-\(short)",
                rssi: entry.rssi,
                lastSeen: entry.lastSeen,
                firstSeen: entry.firstSeen,
                detectionCount: entry.detectionCount,
                threatLevel: threat,
                persistenceLevel: persistence,
                movedWithYou: mv.moved,
                moveNote: moveNote
            ))
            if lastMoved[identifier] != mv.moved {
                lastMoved[identifier] = mv.moved
                log("MOVE", tag: short, rssi: entry.rssi,
                    note: "moved=\(mv.moved) walk_m=\(mv.walkM) vehicle_s=\(mv.autoS) presence_pct=\(mv.presencePct) gating=\(gating)")
            }

            if !loggedDetected.contains(identifier) {
                loggedDetected.insert(identifier)
                log("DETECTED", tag: short, rssi: entry.rssi, threat: threat.rawValue,
                    persistence: persistence, count: entry.detectionCount)
            }
            if lastLoggedThreat[identifier] != threat {
                lastLoggedThreat[identifier] = threat
                log("THREAT_CHANGE", tag: short, rssi: entry.rssi, threat: threat.rawValue,
                    persistence: persistence, count: entry.detectionCount,
                    note: "age_s=\(Int(now.timeIntervalSince(entry.firstSeen))) walk_m=\(mv.walkM) vehicle_s=\(mv.autoS) presence_pct=\(mv.presencePct) moved=\(mv.moved)")
            }
            notifyIfNeeded(id: identifier, short: short, threat: threat)
            if threat == .high && !demoMode && !highHandled.contains(identifier) {
                highHandled.insert(identifier)
                if autoBeepAtHigh {
                    log("AUTO_BEEP", tag: short, rssi: entry.rssi)
                    playSound(onTag: identifier)
                } else if findPromptTagID == nil {
                    findPromptTagID = identifier
                    log("FIND_PROMPT", tag: short, rssi: entry.rssi)
                }
            }
        }

        // Drop long-stale cache entries so the dictionary cannot grow without bound
        airTagCache = airTagCache.filter { now.timeIntervalSince($0.value.lastSeen) < 600 }

        detectedAirTags = updated.sorted { $0.threatLevel > $1.threatLevel }
        updateThreatLevel()
    }

    /// Moved with the user = enough distance (or vehicle time) since the window started AND
    /// the device was present in most scan cycles over that distance (not just at both ends).
    private func movement(for id: String) -> (moved: Bool, walkM: Int, autoS: Int, presencePct: Int) {
        guard let m = moveState[id] else { return (false, 0, 0, 0) }
        // Distance only counts up to the last time the device was seen (B3: a passed tag kept
        // "earning" meters after it was gone), and the device must still be with the user now.
        let w = max(0, m.lastWalk - m.startWalk)
        let a = max(0, m.lastAuto - m.startAuto)
        let presence = m.cycles > 0 ? Double(m.seenCycles) / Double(m.cycles) : 0
        let farEnough = w >= moveWalkMeters || a >= moveVehicleSeconds
        let present = m.cycles >= moveMinCycles && presence >= movePresence
        let stillHere = Date().timeIntervalSince(m.lastSeen) <= moveStillSeconds
        return (farEnough && present && stillHere, Int(w), Int(a), Int(presence * 100))
    }

    private func calculatePersistence(for entry: AirTagCacheEntry) -> String {
        let duration = Date().timeIntervalSince(entry.firstSeen)
        if duration < 60 { return "Transient" }
        if duration < 120 { return "Tracking" }   // High after 2 minutes (5 min until 5t, 2.5 min until 6b); movement is also required
        return "Persistent"
    }

    /// Threat rules (build 5n). Signal strength is not used: on-device tests showed tags within
    /// inches of the phone reading anywhere from -51 to -98 dBm, so it is no guide to distance.
    ///   Low:    seen under 1 minute
    ///   Medium: seen 1 to 2 minutes
    ///   High:   seen 2 minutes or more (was 5, then 2.5; changed after walk tests)
    /// The movement check (in processCachedAirTags) then holds a tag at Low until it has
    /// moved with the user. Without movement data, High is capped at Medium.
    private func calculateThreatLevel(for entry: AirTagCacheEntry, persistence: String) -> ThreatLevel {
        switch persistence {
        case "Persistent": return .high
        case "Tracking": return .medium
        default: return .low
        }
    }

    private func updateThreatLevel() {
        if detectedAirTags.isEmpty {
            threatLevel = .none
        } else if detectedAirTags.contains(where: { $0.threatLevel == .high }) {
            threatLevel = .high
        } else if detectedAirTags.contains(where: { $0.threatLevel == .medium }) {
            threatLevel = .medium
        } else {
            threatLevel = .low
        }
    }

    // MARK: Notifications
    private func notifyEnabled(for level: ThreatLevel) -> Bool {
        switch level {
        case .none: return false
        case .low:    return userDefaults.object(forKey: "notifyLowThreat") as? Bool ?? false
        case .medium: return userDefaults.object(forKey: "notifyMediumThreat") as? Bool ?? true
        case .high:   return userDefaults.object(forKey: "notifyHighThreat") as? Bool ?? true
        }
    }

    private func notifyIfNeeded(id: String, short: String, threat: ThreatLevel) {
        let previous = notifiedLevel[id] ?? .none
        guard threat > previous, notifyEnabled(for: threat) else { return }
        notifiedLevel[id] = threat
        sendNotification(
            title: "\(threat.rawValue) threat: tracker nearby",
            body: "AirTag-\(short) is within range of this phone. Open TagAlert for signal and time details."
        )
        log("NOTIFY", tag: short, threat: threat.rawValue)
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error = error { print("Notification permission error: \(error)") }
        }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = notificationSound()
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: Battery + settings
    private func setupBatteryMonitoring() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        batteryLevel = currentBattery()
        NotificationCenter.default.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.batteryLevel = self?.currentBattery() ?? 1.0
        }
    }

    private func currentBattery() -> Float {
        let level = UIDevice.current.batteryLevel
        return level < 0 ? 1.0 : level   // -1 on simulator
    }

    private func loadSettings() {
        // Default 15 s (was 30 s). Saved values from older builds of 30 s or more are reset once.
        let saved = userDefaults.double(forKey: "scanInterval")
        if userDefaults.bool(forKey: "interval15Migrated") {
            scanInterval = saved == 0 ? 15.0 : saved
        } else {
            scanInterval = 15.0
            userDefaults.set(true, forKey: "interval15Migrated")
        }
        currentInterval = scanInterval
        adaptiveScanning = userDefaults.object(forKey: "adaptiveScanning") as? Bool ?? true
    }

    // MARK: CSV log
    private func writeLogHeader() {
        let header = "iso_time,event,tag_id,rssi,mfr_hex_first4,threat,persistence,detection_count,scan_interval_s,battery_pct,mode,note\n"
        logQueue.async { [logFileURL] in
            try? header.write(to: logFileURL, atomically: true, encoding: .utf8)
        }
    }

    private func log(_ event: String, tag: String = "", rssi: Int? = nil, hex: String = "",
                     threat: String = "", persistence: String = "", count: Int? = nil, note: String = "") {
        let battery = Int((currentBattery() * 100).rounded())
        let cols: [String] = [
            isoFormatter.string(from: Date()), event, tag,
            rssi.map(String.init) ?? "", hex, threat, persistence,
            count.map(String.init) ?? "", String(Int(currentInterval)), String(battery),
            demoMode ? "DEMO" : "LIVE",
            note.replacingOccurrences(of: ",", with: ";")
        ]
        let row = cols.joined(separator: ",") + "\n"
        logQueue.async { [logFileURL] in
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                handle.seekToEndOfFile()
                if let data = row.data(using: .utf8) { handle.write(data) }
                try? handle.close()
            }
        }
        DispatchQueue.main.async { self.logRowCount += 1 }
    }

    // MARK: Demo data (simulated, clearly labeled in UI and log)
    private func generateDemoAirTags() {
        airTagCache.removeAll()
        let now = Date()
        airTagCache["DEMO-HIGH-A1B2C3D4"] = AirTagCacheEntry(identifier: "DEMO-HIGH-A1B2C3D4",
            firstSeen: now.addingTimeInterval(-600), lastSeen: now, rssi: -55, detectionCount: 20)
        airTagCache["DEMO-MED-E5F6G7H8"] = AirTagCacheEntry(identifier: "DEMO-MED-E5F6G7H8",
            firstSeen: now.addingTimeInterval(-180), lastSeen: now, rssi: -68, detectionCount: 8)
        airTagCache["DEMO-LOW-I9J0K1L2"] = AirTagCacheEntry(identifier: "DEMO-LOW-I9J0K1L2",
            firstSeen: now.addingTimeInterval(-30), lastSeen: now, rssi: -75, detectionCount: 2)
        processCachedAirTags()
    }

    private func setupDemoTimer() {
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self, self.demoMode else { return }
            let now = Date()
            for (id, var entry) in self.airTagCache {
                entry.lastSeen = now
                entry.detectionCount += 1
                entry.rssi = max(-90, min(-40, entry.rssi + Int.random(in: -3...3)))
                self.airTagCache[id] = entry
            }
            self.scanCount += 1
            self.processCachedAirTags()
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            statusNote = ""
        case .poweredOff:
            statusNote = "Bluetooth is off"
            stopScanning()
        case .unauthorized:
            statusNote = "Bluetooth permission denied (Settings > TagAlert)"
        case .unsupported:
            statusNote = "Bluetooth LE not supported on this device"
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard isScanning, !demoMode else { return }
        // CoreBluetooth reports 127 when RSSI is unavailable
        guard RSSI.intValue != 127 else { return }

        // Diagnostics: what does iOS actually hand us? (counts every peripheral, any vendor)
        let pid = peripheral.identifier.uuidString
        allSeen.insert(pid)
        if let raw = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, raw.count >= 2 {
            let b = [UInt8](raw.prefix(2))
            let cid = String(format: "%02X%02X", b[1], b[0])   // little-endian company ID
            companySeen[cid, default: []].insert(pid)
        }

        // One fingerprint row per peripheral per session: exactly what iOS gave us for it
        if !fingerprinted.contains(pid) {
            fingerprinted.insert(pid)
            log("PERIPHERAL", tag: String(pid.prefix(8)), rssi: RSSI.intValue,
                note: fingerprint(of: peripheral, advertisementData))
        }

        // Bare connectable peripherals are the only way an AirTag appears to an iOS app
        if isBareCandidate(peripheral, advertisementData) {
            candidatePeripherals[pid] = peripheral
            candidateRSSI[pid] = RSSI.intValue
            let now = Date()
            if let s = candidateSeen[pid], now.timeIntervalSince(s.last) <= moveGapSeconds {
                candidateSeen[pid] = (s.first, now)
            } else {
                candidateSeen[pid] = (now, now)
            }
            touchMove(pid, now: now)
            if let isTag = probeResult[pid] {
                if isTag { recordFindMy(id: pid, rssi: RSSI.intValue, hex: "GATT7DFC") }
            } else if probingID != pid, !probeQueue.contains(pid),
                      (retryAfter[pid].map { now >= $0 } ?? true) {
                probeQueue.append(pid)
                queuedAt[pid] = now
                if probingID == nil, now.timeIntervalSince(sessionStartedAt) >= 1.0 { startNextProbe() }
            }
        }

        var isFindMy = false
        var hex = ""
        var isOtherApple = false

        if let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, data.count >= 4 {
            let b = [UInt8](data.prefix(4))
            hex = b.map { String(format: "%02X", $0) }.joined()
            if b[0] == 0x4C && b[1] == 0x00 {
                if b[2] == 0x12 && b[3] == 0x19 {
                    isFindMy = true          // Apple Find My (offline finding) payload header
                } else {
                    isOtherApple = true
                }
            }
        }
        if let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
           uuids.contains(findMyServiceUUID) {
            isFindMy = true
        }

        let id = peripheral.identifier.uuidString
        if isFindMy {
            recordFindMy(id: id, rssi: RSSI.intValue, hex: hex)
        } else if isOtherApple {
            otherAppleSeen.insert(id)
        }
    }

    private func isBareCandidate(_ peripheral: CBPeripheral, _ ad: [String: Any]) -> Bool {
        let connectable = (ad[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? false
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        return connectable
            && name == nil
            && ad[CBAdvertisementDataManufacturerDataKey] == nil
            && ad[CBAdvertisementDataServiceUUIDsKey] == nil
            && ad[CBAdvertisementDataServiceDataKey] == nil
    }

    private func resetProbeState() {
        probeTimeout?.cancel()
        probeTimeout = nil
        for (_, p) in candidatePeripherals where p.state != .disconnected {
            centralManager.cancelPeripheralConnection(p)
        }
        candidatePeripherals.removeAll()
        candidateRSSI.removeAll()
        candidateSeen.removeAll()
        probeResult.removeAll()
        probeAttempts.removeAll()
        retryAfter.removeAll()
        retryRound.removeAll()
        queuedAt.removeAll()
        probeQueue.removeAll()
        probingID = nil
    }

    /// Connects to one bare candidate at a time and checks for the AirTag service.
    private func startNextProbe() {
        guard isScanning, !demoMode, probingID == nil, soundID == nil,
              centralManager.state == .poweredOn else { return }
        while !probeQueue.isEmpty {
            // Strongest signal first: a tag on the user's body is close, so it is probed before
            // weak, distant devices (the walk test lost 90 s behind a queue of distant devices)
            // ...but a device that has waited 45 s or more goes next, so weak tags are not starved
            let now = Date()
            let oldest = probeQueue.indices.min(by: { (queuedAt[probeQueue[$0]] ?? now) < (queuedAt[probeQueue[$1]] ?? now) })!
            let idx: Int
            if now.timeIntervalSince(queuedAt[probeQueue[oldest]] ?? now) >= maxQueueWait {
                idx = oldest
            } else {
                idx = probeQueue.indices.max(by: { (candidateRSSI[probeQueue[$0]] ?? -127) < (candidateRSSI[probeQueue[$1]] ?? -127) })!
            }
            let next = probeQueue.remove(at: idx)
            queuedAt[next] = nil
            guard probeResult[next] == nil, let peripheral = candidatePeripherals[next] else { continue }
            probingID = next
            probeAttempts[next, default: 0] += 1
            peripheral.delegate = self
            log("PROBE_START", tag: String(next.prefix(8)), rssi: candidateRSSI[next],
                note: "attempt=\(probeAttempts[next] ?? 1) queue_left=\(probeQueue.count)")
            centralManager.connect(peripheral, options: nil)
            let work = DispatchWorkItem { [weak self] in
                self?.finishProbe(next, isTag: false, reason: "timeout")
            }
            probeTimeout = work
            let weak = (candidateRSSI[next] ?? -127) <= -85
            DispatchQueue.main.asyncAfter(deadline: .now() + (weak ? weakProbeTimeoutSeconds : probeTimeoutSeconds), execute: work)
            return
        }
    }

    private func finishProbe(_ pid: String, isTag: Bool, reason: String) {
        guard probingID == pid else { return }
        probeTimeout?.cancel()
        probeTimeout = nil
        if let p = candidatePeripherals[pid] {
            centralManager.cancelPeripheralConnection(p)
        }
        let transient = (reason == "timeout" || reason == "connect_failed")
        var retryNote = ""
        if !isTag && transient {
            if (probeAttempts[pid] ?? 0) < maxProbeAttempts {
                probeQueue.append(pid)            // retry soon, connection may have been busy
                queuedAt[pid] = Date()
            } else {
                // Not written off: try again in 60 s if the device is still around
                probeAttempts[pid] = 0
                let delay = retryDelay(pid)
                retryRound[pid, default: 0] += 1
                retryAfter[pid] = Date().addingTimeInterval(delay)
                retryNote = " retry_in_s=\(Int(delay))"
            }
        } else {
            probeResult[pid] = isTag
            retryAfter[pid] = nil
        }
        log("PROBE_RESULT", tag: String(pid.prefix(8)), rssi: candidateRSSI[pid],
            note: "airtag=\(isTag) reason=\(reason)" + retryNote)
        if isTag {
            if let p = candidatePeripherals[pid] { confirmedPeripherals[pid] = p }
            recordFindMy(id: pid, rssi: candidateRSSI[pid] ?? -100, hex: "GATT7DFC")
            processCachedAirTags()   // show the tag now, not at the end of the scan cycle
        }
        probingID = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.startNextProbe()
        }
    }

    private func fingerprint(of peripheral: CBPeripheral, _ ad: [String: Any]) -> String {
        let keys = ad.keys
            .map { $0.replacingOccurrences(of: "kCBAdvData", with: "") }
            .sorted()
            .joined(separator: "+")
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "-"
        let connectable = (ad[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
        var mfr = "-"
        if let data = ad[CBAdvertisementDataManufacturerDataKey] as? Data {
            let bytes = [UInt8](data.prefix(6))
            mfr = bytes.map { byte in String(format: "%02X", byte) }.joined()
        }
        var services = "-"
        if let uuids = ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            services = uuids.map { u in u.uuidString }.joined(separator: "+")
        }
        var serviceData = "-"
        if let sd = ad[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            serviceData = sd.keys.map { u in u.uuidString }.sorted().joined(separator: "+")
        }
        let conn = connectable.map { $0 ? "yes" : "no" } ?? "-"
        return "name=\(name)|conn=\(conn)|keys=\(keys)|mfr=\(mfr)|svc=\(services)|svcdata=\(serviceData)"
    }

    /// Starts or continues a device's movement window (reset if unseen longer than moveGapSeconds).
    private func touchMove(_ id: String, now: Date) {
        let walk = motion.walkMeters, auto = motion.automotiveSeconds
        seenThisCycle.insert(id)
        if var m = moveState[id] {
            if now.timeIntervalSince(m.lastSeen) > moveGapSeconds {
                m.startWalk = walk; m.startAuto = auto; m.cycles = 0; m.seenCycles = 0
            }
            m.lastSeen = now
            m.lastWalk = walk; m.lastAuto = auto
            moveState[id] = m
        } else {
            moveState[id] = MoveState(startWalk: walk, startAuto: auto, lastSeen: now, lastWalk: walk, lastAuto: auto)
        }
    }

    private func recordFindMy(id: String, rssi: Int, hex: String) {
        let now = Date()
        touchMove(id, now: now)
        if var entry = airTagCache[id] {
            entry.lastSeen = now
            entry.rssi = rssi
            entry.detectionCount += 1
            airTagCache[id] = entry
        } else {
            // Count time from the first sighting of this device, if it has been in range since then
            var first = now
            if let s = candidateSeen[id], now.timeIntervalSince(s.last) <= moveGapSeconds { first = s.first }
            airTagCache[id] = AirTagCacheEntry(identifier: id, firstSeen: first, lastSeen: now,
                                               rssi: rssi, detectionCount: 1)
            log("FIRST_SEEN", tag: String(id.prefix(8)), rssi: rssi,
                note: "seen_s_before_confirm=\(Int(now.timeIntervalSince(first)))")
        }
        log("ADV", tag: String(id.prefix(8)), rssi: rssi, hex: hex)
    }
}

// MARK: - Connection and GATT probe callbacks
extension BluetoothManager {
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let pid = peripheral.identifier.uuidString
        if soundID == pid {
            peripheral.delegate = self
            peripheral.discoverServices([airTagServiceUUID])
            return
        }
        guard probingID == pid else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.delegate = self
        peripheral.discoverServices([airTagServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if soundID == peripheral.identifier.uuidString {
            finishSound(success: false, message: "Could not connect. The tag may be out of range or near its owner.")
            return
        }
        finishProbe(peripheral.identifier.uuidString, isTag: false, reason: "connect_failed")
    }
}

extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let pid = peripheral.identifier.uuidString
        if soundID == pid {
            if error == nil, let svc = peripheral.services?.first(where: { $0.uuid == airTagServiceUUID }) {
                peripheral.discoverCharacteristics([soundCharacteristicUUID], for: svc)
            } else {
                finishSound(success: false, message: "The tag did not offer its sound service.")
            }
            return
        }
        if let error = error {
            finishProbe(pid, isTag: false, reason: "service_error_\((error as NSError).code)")
            return
        }
        let found = peripheral.services?.contains(where: { $0.uuid == airTagServiceUUID }) ?? false
        finishProbe(pid, isTag: found, reason: found ? "service_7DFC9000" : "no_airtag_service")
    }
}

extension BluetoothManager {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard soundID == peripheral.identifier.uuidString else { return }
        guard error == nil, let ch = service.characteristics?.first(where: { $0.uuid == soundCharacteristicUUID }) else {
            finishSound(success: false, message: "Sound control not available on this tag.")
            return
        }
        peripheral.writeValue(soundStartCommand, for: ch, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard soundID == peripheral.identifier.uuidString else { return }
        if let error = error {
            finishSound(success: false, message: "Tag refused the sound command (code \((error as NSError).code)).")
        } else {
            finishSound(success: true, message: "Sound command sent. The tag should beep for about 15 seconds.")
        }
    }

    /// Asks a confirmed AirTag to beep. Works only while the tag is separated from its owner and in range.
    func playSound(onTag id: String) {
        guard !demoMode, soundID == nil, centralManager.state == .poweredOn,
              let peripheral = confirmedPeripherals[id] else {
            soundStatus = "No live connection to this tag yet. Keep scanning until it is confirmed."
            return
        }
        soundID = id
        soundingTagID = id
        soundStatus = "Connecting to the tag..."
        probeTimeout?.cancel()
        if let probing = probingID, let p = candidatePeripherals[probing] {
            centralManager.cancelPeripheralConnection(p)
            probingID = nil
        }
        peripheral.delegate = self
        log("SOUND_START", tag: String(id.prefix(8)), rssi: candidateRSSI[id], note: "cmd=AF")
        centralManager.connect(peripheral, options: nil)
        let work = DispatchWorkItem { [weak self] in
            self?.finishSound(success: false, message: "Timed out. The tag may be near its owner, out of range, or busy.")
        }
        soundTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }

    private func finishSound(success: Bool, message: String) {
        guard let id = soundID else { return }
        soundTimeout?.cancel()
        soundTimeout = nil
        if let p = confirmedPeripherals[id] { centralManager.cancelPeripheralConnection(p) }
        log("SOUND_RESULT", tag: String(id.prefix(8)), rssi: candidateRSSI[id], note: "ok=\(success) msg=\(message)")
        soundStatus = message
        soundID = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.soundingTagID = nil
            self?.soundStatus = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.startNextProbe() }
    }
}

// MARK: - Show notifications while the app is in the foreground
extension BluetoothManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
