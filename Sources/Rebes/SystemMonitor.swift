//
//  SystemMonitor.swift
//  Rebes
//
//  Single shared sampler feeding the dashboard and the menu bar panel:
//  system meters (CPU/RAM/disk/network), SMC temps + fans, battery.
//

import SwiftUI
import Combine
import IOKit.pwr_mgt
import RebesCore

struct FanReading: Identifiable {
    let id: Int
    var actual: Double
    var min: Double
    var max: Double
    var target: Double
    var mode: Int
}

struct MetricPoint: Identifiable {
    let id = UUID()
    let t: Date
    let value: Double
}

@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    @Published var snapshot = SystemSnapshot()
    @Published var cpuTemp: Double?
    @Published var fans: [FanReading] = []
    @Published var battery: BatteryInfo?

    // SMC power telemetry (unprivileged sensor reads). nil = key absent on
    // this machine → the UI row hides; a present key reading 0 W stays 0.
    @Published var systemPowerWatts: Double?    // PSTR — system total power
    @Published var dcInPowerWatts: Double?      // PDTR — DC input power
    @Published var batteryPowerWatts: Double?   // PPBR — battery power

    // Rolling history for charts (~10 min at 2.5s = 240 points).
    private let historyCap = 240
    @Published var chargeHistory: [MetricPoint] = []
    @Published var batteryTempHistory: [MetricPoint] = []
    @Published var cpuTempHistory: [MetricPoint] = []
    @Published var powerHistory: [MetricPoint] = []
    @Published var cpuHistory: [MetricPoint] = []
    /// Persistent battery-health trend (30-min snapshots, ~90 days) — the one
    /// chart that must NOT reset on relaunch.
    @Published var batteryHealthHistory: [MetricPoint] = []

    private var timer: Timer?
    private var subscribers = 0

    private init() {}

    private func push(_ arr: inout [MetricPoint], _ v: Double, at t: Date) {
        arr.append(MetricPoint(t: t, value: v))
        if arr.count > historyCap { arr.removeFirst(arr.count - historyCap) }
    }

    /// Overall Mac health, CleanMyMac-style. Weighs free disk, memory pressure,
    /// battery health, and CPU temperature into a 0–100 score.
    func health() -> (label: String, color: Color, score: Int) {
        var scores: [Double] = []
        // Disk: 100 at ≥30% free, 0 at 0% free
        let freePct = 100 - snapshot.diskUsedPercent
        scores.append(min(100, freePct / 30 * 100))
        // Memory: 100 at ≤50% used, 0 at 95%+
        scores.append(min(100, max(0, (95 - snapshot.memUsedPercent) / 45 * 100)))
        // Battery health (if present)
        if let b = battery, b.healthPercent > 0 {
            scores.append(min(100, b.healthPercent / 80 * 100))
        }
        // Thermal: 100 at ≤60°C, 0 at ≥95°C
        if let t = cpuTemp {
            scores.append(min(100, max(0, (95 - t) / 35 * 100)))
        }
        let score = Int(scores.isEmpty ? 100 : scores.reduce(0, +) / Double(scores.count))
        if score >= 80 { return ("Excellent", Theme.accentBattery, score) }
        if score >= 60 { return ("Good", Theme.teal, score) }
        if score >= 40 { return ("Fair", Theme.accentFiles, score) }
        return ("Needs Care", Theme.accentUninstall, score)
    }

    /// The menu bar controller subscribes once at launch and never stops, so
    /// sampling effectively runs for the process lifetime (the menu-bar label
    /// needs it). View-level start/stop ref-counting is harmless bookkeeping —
    /// it never actually pauses the timer.
    func start() {
        subscribers += 1
        guard timer == nil else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { _ in
            Task { @MainActor in SystemMonitor.shared.tick() }
        }
    }

    func stop() {
        subscribers = max(0, subscribers - 1)
        if subscribers == 0 {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        Task.detached(priority: .utility) {
            let snap = SystemStats.shared.sample()
            let smc = SMC.shared
            let temp = smc.getValue("Tp01") ?? smc.getValue("Tp05") ?? smc.getValue("TC10")
            let fNum = Int(smc.getValue("FNum") ?? 0)
            var fans: [FanReading] = []
            for i in 0..<fNum {
                fans.append(FanReading(
                    id: i,
                    actual: smc.getValueAllowingZero("F\(i)Ac") ?? 0,
                    min: smc.getValueAllowingZero("F\(i)Mn") ?? 0,
                    max: smc.getValue("F\(i)Mx") ?? 0,
                    target: smc.getValueAllowingZero("F\(i)Tg") ?? 0,
                    mode: Int(smc.getValueAllowingZero(smc.fanModeKey(i)) ?? 0)
                ))
            }
            var battery = BatteryReader.read()
            // AppleSmartBattery has no usable Temperature key on Apple Silicon —
            // take battery temperature from SMC TB0T so every consumer (charts,
            // Charge Control) shows a real value instead of a stale 0°C.
            if let btemp = smc.getValue("TB0T"), btemp > 0, btemp < 100 {
                battery?.temperatureC = btemp
            }
            // Persistent health history: the store dedupes to one snapshot per
            // 30 min, so calling it every tick is free.
            if let b = battery, b.fullChargeCapacityMah > 0 {
                BatteryHistoryStore.shared.record(
                    fcc: b.fullChargeCapacityMah, health: b.healthPercent,
                    cycles: b.cycleCount, tempC: b.temperatureC)
            }
            let healthTrend = BatteryHistoryStore.shared.all.map { MetricPoint(t: $0.t, value: $0.health) }
            // Power telemetry: allow zero (PDTR is legitimately 0 W on battery);
            // an absent key fails the read and stays nil so its UI row hides.
            let systemPower = smc.getValueAllowingZero("PSTR")
            let dcInPower = smc.getValueAllowingZero("PDTR")
            let batteryPower = smc.getValueAllowingZero("PPBR")

            let now = Date()
            await MainActor.run {
                let monitor = SystemMonitor.shared
                monitor.snapshot = snap
                monitor.cpuTemp = temp
                monitor.fans = fans
                monitor.battery = battery
                monitor.systemPowerWatts = systemPower
                monitor.dcInPowerWatts = dcInPower
                monitor.batteryPowerWatts = batteryPower

                monitor.push(&monitor.cpuHistory, snap.cpuUsagePercent, at: now)
                if let temp { monitor.push(&monitor.cpuTempHistory, temp, at: now) }
                if let b = battery {
                    monitor.push(&monitor.chargeHistory, Double(b.currentChargePercent), at: now)
                    if b.temperatureC > 0 { monitor.push(&monitor.batteryTempHistory, b.temperatureC, at: now) }
                    monitor.push(&monitor.powerHistory, b.watts, at: now)
                }
                monitor.batteryHealthHistory = healthTrend

                // "Stay awake until the charge limit" is a FEATURE, not a view
                // concern — evaluate it from this permanent sampler so the
                // sleep assertion is held/released correctly even after the
                // user leaves the Battery tab (previously it leaked forever).
                let cfg = AppSettings.shared.chargeConfig
                let holdAwake = cfg.enabled && cfg.disableSleepUntilLimit
                    && (battery?.isPluggedIn ?? false)
                    && (battery?.currentChargePercent ?? 100) < cfg.limitPercent
                ChargeSleepGuard.shared.update(shouldHold: holdAwake)
            }
        }
    }
}

/// Keep-awake (caffeinate) via IOKit power assertion — no root needed.
@MainActor
final class CaffeinateManager: ObservableObject {
    static let shared = CaffeinateManager()
    @Published private(set) var isActive = false
    private var assertionID: IOPMAssertionID = 0

    private init() {}

    func toggle() {
        isActive ? stop() : start()
    }

    private func start() {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Rebes! — Staying Awake" as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            assertionID = id
            isActive = true
        }
    }

    private func stop() {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        isActive = false
    }
}
