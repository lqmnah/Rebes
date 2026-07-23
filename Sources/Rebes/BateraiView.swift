//
//  BateraiView.swift
//  Rebes
//
//  The single battery destination (AlDente-style): charge control first —
//  status, limit, sailing, heat protection, one-shot actions, LED, behavior
//  (embedded ChargeControlSection) — then live power/health statistics as
//  stacked stat cards, then history charts. Writes go through HelperClient:
//  XPC daemon when installed (no prompt), otherwise a one-off admin prompt.
//

import SwiftUI
import Combine
import RebesCore

class BateraiState: ObservableObject {
    @Published var info: BatteryInfo?
    @Published var isLoading = true
}

struct BateraiView: View {
    @StateObject private var state = BateraiState()
    @ObservedObject private var monitor = SystemMonitor.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(
                    title: "Battery",
                    subtitle: "Charge limit, health & power — all in one place",
                    accent: Theme.accentBattery,
                    icon: "battery.100percent"
                )

                // Charge control lives here now (merged from the old
                // standalone Charge Control tab).
                ChargeControlSection()

                if state.isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if let info = state.info {
                    Text("Statistics")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.top, 4)

                    HStack(alignment: .top, spacing: 14) {
                        powerStack(info).cascadeIn(0)
                        batteryStack(info).cascadeIn(1)
                    }

                    // History charts (AlDente-style)
                    Text("History").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.top, 4)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                        MetricChart(title: "Battery Level", latest: "\(info.currentChargePercent)%",
                                    points: monitor.chargeHistory, accent: Theme.accentBattery,
                                    unitSuffix: "%", yRange: 0...100)
                        MetricChart(title: "Battery Temperature",
                                    latest: String(format: "%.1f°C", info.temperatureC),
                                    points: monitor.batteryTempHistory, accent: Theme.accentFans, unitSuffix: "°")
                        MetricChart(title: info.watts >= 0 ? "Charging Power" : "Power Draw",
                                    latest: String(format: "%.1f W", abs(info.watts)),
                                    points: monitor.powerHistory.map { MetricPoint(t: $0.t, value: abs($0.value)) },
                                    accent: Theme.accentStartup, unitSuffix: "W")
                        MetricChart(title: "CPU Temperature",
                                    latest: monitor.cpuTemp.map { String(format: "%.0f°C", $0) } ?? "—",
                                    points: monitor.cpuTempHistory, accent: Theme.accentFiles, unitSuffix: "°")
                    }
                    .cascadeIn(2)
                } else {
                    Text("Failed to read battery info.")
                        .foregroundStyle(Theme.accentUninstall)
                }
            }
            .padding(24)
        }
        .background(Theme.bg)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
        // Single source of truth: SystemMonitor's 2.5s sampler (which also
        // applies the TB0T temperature override). No second battery poller.
        .onReceive(monitor.$battery) { b in
            if let b { state.info = b }
            state.isLoading = false
        }
    }

    // MARK: - stacked stats (AlDente-style)

    /// Live electrical telemetry: battery current/voltage/power plus the
    /// SMC system-load sensor (row hides when the key is absent).
    /// 1 Hz rule: current/voltage/watts tick every poll — raw stays nil so
    /// StatValue renders plain monospaced digits, no rolling-digit springs.
    private func powerStack(_ info: BatteryInfo) -> some View {
        StackCard(title: "Power") {
            StatRow(icon: "bolt.circle", accent: Theme.accentBattery, label: "Current",
                    value: String(format: "%+.2f A", info.amperage))
            StatRow(icon: "bolt.horizontal", accent: Theme.accentFans, label: "Voltage",
                    value: String(format: "%.2f V", info.voltage))
            StatRow(icon: "bolt.fill", accent: Theme.accentStartup, label: "Power",
                    value: String(format: "%+.2f W", info.watts))
            if let sys = monitor.systemPowerWatts {
                StatRow(icon: "cpu", accent: Theme.accentFiles, label: "System Load",
                        value: String(format: "%.1f W", sys))
            }
            if info.isPluggedIn {
                StatRow(icon: "powerplug.fill", accent: Theme.accentStartup, label: "Adapter",
                        value: info.adapterWattage.map { "\($0) W" } ?? "—",
                        raw: info.adapterWattage.map(Double.init))
            } else {
                StatRow(icon: "powerplug", accent: .secondary, label: "Adapter",
                        value: "Not connected")
            }
            StatRow(icon: "clock", accent: Theme.accentMaintenance,
                    label: info.isCharging ? "Time to Full" : "Time to Empty",
                    value: info.timeRemainingMin > 0
                        ? "\(info.timeRemainingMin / 60)h \(info.timeRemainingMin % 60)m" : "—",
                    raw: info.timeRemainingMin > 0 ? Double(info.timeRemainingMin) : nil)
            StatRow(icon: "leaf", accent: Theme.accentBattery, label: "Low Power Mode",
                    value: info.lowPowerMode ? "On" : "Off")
        }
    }

    /// Battery hardware & health: capacities, condition, cycles, temperature.
    /// Charge mAh and temperature tick every poll (1 Hz rule → raw nil);
    /// health/cycles/capacities are slow, event-driven → digit roll stays.
    private func batteryStack(_ info: BatteryInfo) -> some View {
        StackCard(title: "Battery") {
            StatRow(icon: "battery.75percent", accent: Theme.accentBattery, label: "Charge",
                    value: "\(info.currentCapacityMah) mAh")
            StatRow(icon: "battery.100percent", accent: Theme.accentBattery, label: "Full Charge (measured)",
                    value: "\(info.maxCapacityMah) mAh", raw: Double(info.maxCapacityMah))
            if info.nominalCapacityMah > 0 {
                StatRow(icon: "battery.75percent", accent: .secondary, label: "Nominal (gauge est.)",
                        value: "\(info.nominalCapacityMah) mAh", raw: Double(info.nominalCapacityMah))
            }
            StatRow(icon: "battery.100percent.bolt", accent: Theme.accentFans, label: "Design Capacity",
                    value: "\(info.designCapacityMah) mAh", raw: Double(info.designCapacityMah))
            StatRow(icon: "heart.fill", accent: Theme.accentUninstall, label: "Health",
                    value: "\(info.healthPercent)%\(info.healthEstimated ? " (est.)" : "")",
                    raw: Double(info.healthPercent))
            StatRow(icon: "arrow.triangle.2.circlepath", accent: Theme.accentStartup, label: "Cycle Count",
                    value: "\(info.cycleCount)", raw: Double(info.cycleCount))
            StatRow(icon: "thermometer.medium", accent: Theme.accentFiles, label: "Temperature",
                    value: String(format: "%.1f°C", info.temperatureC))
            StatRow(icon: "checkmark.seal", accent: Theme.accentBattery, label: "Condition",
                    value: info.condition)
            if let serial = info.serialNumber, !serial.isEmpty {
                StatRow(icon: "number", accent: .secondary, label: "Serial",
                        value: serial)
            }
        }
    }

}
