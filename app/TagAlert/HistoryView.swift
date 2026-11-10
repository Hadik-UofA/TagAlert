//
//  HistoryView.swift
//  TagAlert
//
//  Session summary. v2: every number is computed from live state. The old fake
//  24-hour timeline, hard-coded distribution and "486 scans / 3.2% battery" are gone.
//

import SwiftUI

struct HistoryView: View {
    @ObservedObject var bluetoothManager: BluetoothManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    SessionStatsView(bluetoothManager: bluetoothManager)
                    ThreatDistributionView(bluetoothManager: bluetoothManager)
                    CurrentDetectionsListView(bluetoothManager: bluetoothManager)
                }
                .padding(.vertical)
            }
            .navigationTitle("Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Session stats
struct SessionStatsView: View {
    @ObservedObject var bluetoothManager: BluetoothManager

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                StatCard(title: "Scan cycles", value: "\(bluetoothManager.scanCount)",
                         icon: "antenna.radiowaves.left.and.right", color: .blue)
                StatCard(title: "Trackers now", value: "\(bluetoothManager.detectedAirTags.count)",
                         icon: "exclamationmark.triangle", color: .orange)
            }
            HStack(spacing: 12) {
                StatCard(title: "Scan interval", value: "\(Int(bluetoothManager.currentInterval))s",
                         icon: "clock", color: .green)
                StatCard(title: "Log rows", value: "\(bluetoothManager.logRowCount)",
                         icon: "doc.text", color: .purple)
            }
        }
        .padding(.horizontal)
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon).foregroundColor(color)
                Spacer()
            }
            Text(value).font(.title2).fontWeight(.bold)
            Text(title).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - Threat distribution (computed)
struct ThreatDistributionView: View {
    @ObservedObject var bluetoothManager: BluetoothManager

    private func count(_ level: ThreatLevel) -> Int {
        bluetoothManager.detectedAirTags.filter { $0.threatLevel == level }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Current Threat Levels").font(.headline).padding(.horizontal)

            VStack(spacing: 12) {
                let total = max(bluetoothManager.detectedAirTags.count, 1)
                ThreatBar(label: "High", count: count(.high), color: .red, total: total)
                ThreatBar(label: "Medium", count: count(.medium), color: .orange, total: total)
                ThreatBar(label: "Low", count: count(.low), color: .yellow, total: total)
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }
}

struct ThreatBar: View {
    let label: String
    let count: Int
    let color: Color
    let total: Int

    var body: some View {
        HStack(spacing: 12) {
            Text(label).font(.subheadline).lineLimit(1).minimumScaleFactor(0.8).frame(width: 84, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.gray.opacity(0.2)).frame(height: 24).cornerRadius(4)
                    Rectangle().fill(color)
                        .frame(width: geometry.size.width * CGFloat(count) / CGFloat(max(total, 1)), height: 24)
                        .cornerRadius(4)
                }
            }
            .frame(height: 24)

            Text("\(count)").font(.subheadline).fontWeight(.semibold).frame(width: 30, alignment: .trailing)
        }
    }
}

// MARK: - Current detections
struct CurrentDetectionsListView: View {
    @ObservedObject var bluetoothManager: BluetoothManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Detections This Session").font(.headline).padding(.horizontal)

            if bluetoothManager.detectedAirTags.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray").font(.system(size: 40)).foregroundColor(.secondary)
                    Text("Nothing detected").font(.subheadline).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal)
            } else {
                VStack(spacing: 8) {
                    ForEach(bluetoothManager.detectedAirTags.prefix(10)) { tag in
                        HistoricalAirTagRow(airTag: tag)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

struct HistoricalAirTagRow: View {
    let airTag: DetectedAirTag

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(airTag.identifier).font(.headline)
                HStack(spacing: 12) {
                    Text(formatDuration(from: airTag.firstSeen, to: airTag.lastSeen))
                        .font(.caption).foregroundColor(.secondary)
                    Text("•").foregroundColor(.secondary)
                    Text("\(airTag.detectionCount) advertisements")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            Circle().fill(color(airTag.threatLevel)).frame(width: 12, height: 12)
        }
        .padding()
        .background(Color(UIColor.tertiarySystemBackground))
        .cornerRadius(8)
    }

    private func color(_ level: ThreatLevel) -> Color {
        switch level {
        case .none: return .green
        case .low: return .yellow
        case .medium: return .orange
        case .high: return .red
        }
    }

    private func formatDuration(from start: Date, to end: Date) -> String {
        let minutes = Int(end.timeIntervalSince(start) / 60)
        if minutes < 1 { return "< 1 min" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

struct HistoryView_Previews: PreviewProvider {
    static var previews: some View { HistoryView(bluetoothManager: BluetoothManager()) }
}
