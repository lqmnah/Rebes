//
//  KipasTemperatureView.swift
//  Rebes
//
//  Live fan + temperature monitoring with per-fan Auto/Manual control.
//  Writes go through HelperClient (XPC daemon or admin prompt); failures
//  are surfaced and the mode picker re-syncs from hardware.
//

import SwiftUI
import Combine
import RebesCore

struct FanInfo: Identifiable {
    let id: Int
    var currentRPM: Double
    var minRPM: Double
    var maxRPM: Double
    var targetRPM: Double
    var mode: Int
}

class KipasTemperatureState: ObservableObject {
    @Published var fans: [FanInfo] = []
    @Published var temps: [(name: String, value: Double)] = []
    @Published var hasFans = true
    @Published var isLoading = true
}

struct KipasTemperatureView: View {
    @StateObject private var state = KipasTemperatureState()
    let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(
                    title: "Fan & Temperature",
                    subtitle: "Monitor & control fans — RPM clamped to hardware range",
                    accent: Theme.accentFans,
                    icon: "fanblades",
                    // Header pulses while any fan is held in forced (manual) mode.
                    isBusy: state.fans.contains { $0.mode == 1 }
                )

                if state.isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    if !state.hasFans {
                        Text("This device has no controllable fans.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach($state.fans) { $fan in
                            FanControlView(fan: $fan, onNeedRefresh: refresh)
                                .cascadeIn(fan.id)
                        }
                    }

                    // Automatic Fan Curve (moved here from Settings).
                    FanCurveCard()
                        .cascadeIn(state.fans.count)

                    LQCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Temperature", systemImage: "thermometer.medium")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                            ForEach(state.temps, id: \.name) { temp in
                                HStack {
                                    Text(friendlyName(for: temp.name))
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    // 1 Hz sensor rows: plain monospaced digits (see fan rpm note).
                                    Text(String(format: "%.1f°C", temp.value))
                                        .monospacedDigit()
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .foregroundStyle(temp.value > 85 ? Theme.accentUninstall : .primary)
                                }
                            }
                        }
                    }
                    .hoverLift(accent: Theme.accentFans, scale: 1.01, pointer: false)
                    .cascadeIn(state.fans.count + 1)
                }
            }
            .padding(24)
        }
        .background(Theme.bg)
        .onAppear(perform: refresh)
        // Fans come from SystemMonitor's permanent 2.5s sampler — one SMC
        // reader machine-wide, so this view, the dashboard and the menu bar
        // never disagree. The local timer only polls the extra temp keys.
        .onReceive(SystemMonitor.shared.$fans) { readings in
            state.hasFans = !readings.isEmpty
            state.fans = readings.map {
                FanInfo(id: $0.id, currentRPM: $0.actual, minRPM: $0.min,
                        maxRPM: $0.max, targetRPM: $0.target, mode: $0.mode)
            }
            state.isLoading = false
        }
        .onReceive(timer) { _ in refreshTemps() }
    }

    /// Temps-only poll for the 3s local timer (fans are SystemMonitor-sourced).
    func refreshTemps() {
        DispatchQueue.global(qos: .utility).async {
            let smc = SMC.shared
            let candidateTemps = [
                "Tp01", "Tp02", "Tp05", "Tp09", "Te05", "Te06",
                "Tg05", "Tg0D", "TB0T", "TB1T", "Ts00", "Ts01", "TC10"
            ]
            var newTemps: [(String, Double)] = []
            for key in candidateTemps {
                if let value = smc.getValue(key), value > 0, value < 130 {
                    newTemps.append((key, value))
                }
            }
            DispatchQueue.main.async { state.temps = newTemps }
        }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let smc = SMC.shared
            let fNum = Int(smc.getValue("FNum") ?? 0)

            var newFans: [FanInfo] = []
            for i in 0..<fNum {
                newFans.append(FanInfo(
                    id: i,
                    currentRPM: smc.getValueAllowingZero("F\(i)Ac") ?? 0,
                    minRPM: smc.getValueAllowingZero("F\(i)Mn") ?? 0,
                    maxRPM: smc.getValue("F\(i)Mx") ?? 0,
                    targetRPM: smc.getValueAllowingZero("F\(i)Tg") ?? 0,
                    mode: Int(smc.getValueAllowingZero(smc.fanModeKey(i)) ?? 0)
                ))
            }

            let candidateTemps = [
                "Tp01", "Tp02", "Tp05", "Tp09", "Te05", "Te06",
                "Tg05", "Tg0D", "TB0T", "TB1T", "Ts00", "Ts01", "TC10"
            ]
            var newTemps: [(String, Double)] = []
            for key in candidateTemps {
                if let value = smc.getValue(key), value > 0, value < 130 {
                    newTemps.append((key, value))
                }
            }

            DispatchQueue.main.async {
                state.hasFans = fNum > 0
                state.fans = newFans
                state.temps = newTemps
                state.isLoading = false
            }
        }
    }

    func friendlyName(for key: String) -> String {
        if key.hasPrefix("Tp") { return "CPU P-Core (\(key))" }
        if key.hasPrefix("Te") { return "CPU E-Core (\(key))" }
        if key.hasPrefix("Tg") { return "GPU (\(key))" }
        if key.hasPrefix("TB") { return "Battery (\(key))" }
        if key.hasPrefix("Ts") { return "SSD (\(key))" }
        if key.hasPrefix("TC") { return "CPU (\(key))" }
        return key
    }
}

class FanControlState: ObservableObject {
    @Published var sliderValue: Double = 0
    @Published var isManualStaged = false
    @Published var isApplying = false
    @Published var errorMessage: String?
}

struct FanControlView: View {
    @Binding var fan: FanInfo
    var onNeedRefresh: () -> Void
    @StateObject private var state = FanControlState()

    private var helperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/RebesHelper").path
    }

    var body: some View {
        LQCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    // No continuous rotation: a forever-repeating symbolEffect
                    // over glass burns CPU and reads as jank. "Manual hold" is
                    // cued by tint + the MANUAL badge instead.
                    Image(systemName: "fanblades")
                        .foregroundStyle(fan.mode == 1 ? Theme.accentUninstall : Theme.accentFans)
                    Text("Fan \(fan.id + 1)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    if fan.mode == 1 {
                        Text("MANUAL")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.accentUninstall.opacity(0.25)))
                            .foregroundStyle(Theme.accentUninstall)
                    }
                    Spacer()
                    // 1 Hz telemetry: plain monospaced digits — rolling-digit
                    // springs re-firing every tick is churn, not delight.
                    Text("\(Int(fan.currentRPM)) rpm")
                        .monospacedDigit()
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.accentFans)
                }

                HStack {
                    Text("Min \(Int(fan.minRPM)) · Max \(Int(fan.maxRPM)) · Target \(Int(fan.targetRPM))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                Picker("", selection: Binding(
                    get: { state.isManualStaged || fan.mode == 1 },
                    set: { manual in
                        state.errorMessage = nil
                        if manual {
                            state.isManualStaged = true
                            state.sliderValue = max(fan.minRPM, min(max(fan.targetRPM, fan.minRPM), fan.maxRPM))
                        } else {
                            state.isManualStaged = false
                            runHelper(.fanAuto(fan.id))
                        }
                    }
                )) {
                    Text("Auto").tag(false)
                    Text("Manual").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(state.isApplying)

                if (state.isManualStaged || fan.mode == 1) && fan.maxRPM > fan.minRPM {
                    VStack(alignment: .leading, spacing: 8) {
                        // Plain continuous slider — no `step:` (that draws tick
                        // marks under the track). Snap to 10 rpm on apply.
                        Slider(value: $state.sliderValue, in: fan.minRPM...fan.maxRPM)
                            .tint(Theme.accentFans)
                            .controlSize(.small)
                        HStack {
                            Text("\(Int(fan.minRPM))")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                            Spacer()
                            Text("\(Int(state.sliderValue.rounded())) rpm")
                                .monospacedDigit()
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.accentFans)
                            Spacer()
                            Text("\(Int(fan.maxRPM))")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        .monospacedDigit()
                        Button {
                            let rpm = (state.sliderValue / 10).rounded() * 10
                            runHelper(.fanSet(fan.id, Float(rpm)))
                        } label: {
                            Text("Apply").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AccentButtonStyle(accent: Theme.accentFans))
                        .disabled(state.isApplying)
                    }
                    .padding(.top, 2)
                }

                if state.isApplying {
                    ProgressView().controlSize(.small)
                }
                if let err = state.errorMessage {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accentUninstall)
                }
            }
        }
        .hoverLift(accent: Theme.accentFans, scale: 1.01, pointer: false)
        .onAppear {
            state.sliderValue = max(fan.minRPM, min(max(fan.targetRPM, fan.minRPM), fan.maxRPM))
        }
    }

    private func runHelper(_ action: HelperClient.Action) {
        state.isApplying = true
        let helper = helperPath
        DispatchQueue.global(qos: .userInitiated).async {
            let result = HelperClient.shared.perform(action, fallbackHelperBinary: helper)
            DispatchQueue.main.async {
                state.isApplying = false
                if !result.ok {
                    state.errorMessage = "Failed: \(result.message)"
                    // Re-sync the picker with the real hardware state.
                    state.isManualStaged = false
                } else if case .fanSet = action {
                    state.isManualStaged = false   // hardware mode is now 1; picker follows fan.mode
                }
                onNeedRefresh()
            }
        }
    }
}
