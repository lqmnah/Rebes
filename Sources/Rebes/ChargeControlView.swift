//
//  ChargeControlView.swift
//  Rebes
//
//  AlDente-parity battery charge care. On modern Apple Silicon firmware the
//  charge limit is a firmware-managed band (SMC bfF0/bfD0/bfE0) that the
//  root daemon writes once and reconciles — the firmware itself enforces it,
//  including during sleep. The daemon probes capabilities (gate-mode
//  fallbacks, adapter-disable for discharge, MagSafe LED) and reports rich
//  status; this view is a thin, polling front-end over it.
//
//  ChargeControlSection is an embeddable section (no scroll view, no header):
//  since v1.0.1 it lives at the top of the Battery tab — the old standalone
//  "Charge Control" sidebar destination is gone.
//

import SwiftUI
import IOKit.pwr_mgt
import RebesCore

/// Holds the "stay awake until the limit is reached" sleep assertion —
/// app-side, no root needed. Mirrors CaffeinateManager's IOPMAssertion use.
@MainActor
final class ChargeSleepGuard: ObservableObject {
    static let shared = ChargeSleepGuard()
    @Published private(set) var isActive = false
    private var assertionID: IOPMAssertionID = 0

    private init() {}

    /// Idempotently hold/release the assertion.
    func update(shouldHold: Bool) {
        if shouldHold, !isActive {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Rebes! — Awake until charge limit" as CFString,
                &id
            )
            if result == kIOReturnSuccess {
                assertionID = id
                isActive = true
            }
        } else if !shouldHold, isActive {
            if assertionID != 0 {
                IOPMAssertionRelease(assertionID)
                assertionID = 0
            }
            isActive = false
        }
    }
}

final class ChargeControlState: ObservableObject {
    @Published var config = ChargeConfig()
    @Published var status: ChargeStatus?
    @Published var daemonInstalled = false
    @Published var staleHelper = false
    @Published var busy = false
    @Published var message: String?
    @Published var messageIsError = true
    /// Slider value while the user is dragging (committed on release).
    @Published var pendingLimit: Double?
    /// Set once the daemon's authoritative config has been adopted.
    var syncedWithDaemon = false
    /// Set once the persisted app-side config has been loaded (in onAppear —
    /// never do I/O in a state-object initializer).
    var loaded = false
    /// Status poll timer — owned here (no @State: plain property wrapper only).
    var pollTimer: Timer?
}

struct ChargeControlSection: View {
    @StateObject private var state = ChargeControlState()
    @ObservedObject private var monitor = SystemMonitor.shared

    private var helperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/RebesHelper").path
    }

    private var mode: ChargeControlMode { state.status?.mode ?? .unsupported }
    private var haveStatus: Bool { state.status != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            statusCard

            if !state.daemonInstalled {
                needsFullAccessCard
            } else if state.staleHelper {
                staleHelperCard
            } else if mode == .unsupported, haveStatus {
                unsupportedCard
            } else {
                limitCard
                heatCard
                actionsCard
                if state.status?.ledSupported == true { ledCard }
                behaviorCard
            }

            if let m = state.message {
                Label(m, systemImage: state.messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(state.messageIsError ? Theme.accentUninstall : Theme.accentBattery)
            }
        }
        .onAppear {
            monitor.start()
            if !state.loaded {
                state.loaded = true
                state.config = AppSettings.shared.chargeConfig
            }
            refresh()
            // Guard against double onAppear stacking a second 5s XPC poller.
            if state.pollTimer == nil {
                state.pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                    Task { @MainActor in refresh() }
                }
            }
        }
        .onDisappear {
            monitor.stop()
            state.pollTimer?.invalidate()
            state.pollTimer = nil
            // The sleep assertion is NOT released here: SystemMonitor's
            // permanent tick owns it, so "stay awake until limit" keeps
            // working (and is still released correctly) after a tab switch.
        }
    }

    // MARK: - cards

    private var statusCard: some View {
        LQCard(padding: 16) {
            HStack(spacing: 20) {
                StatRing(progress: Double(state.status?.batteryPercent ?? monitor.battery?.currentChargePercent ?? 0) / 100,
                         accent: Theme.accentBattery,
                         lineWidth: 9,
                         label: "\(state.status?.batteryPercent ?? monitor.battery?.currentChargePercent ?? 0)%",
                         sublabel: chargeStateLabel)
                    .frame(width: 96, height: 96)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        modeBadge
                        if state.config.enabled, let st = state.status, st.mode == .firmware, st.bandActive,
                           let u = st.bandUpper, let l = st.bandLower {
                            Text("Band \(u)% / \(l)%")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Theme.surface))
                                .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
                        }
                    }
                    if let st = state.status {
                        // Phase line refreshes with the status poll — fixed-
                        // width monospaced digits so the text never jumps.
                        Text(st.phase.label)
                            .monospacedDigit()
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        if st.mode == .firmware {
                            Label("Limit is enforced by the firmware — it keeps working during sleep and after reboots.",
                                  systemImage: "checkmark.seal")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        if st.heatPaused {
                            Label("Charging paused — battery is above the heat threshold.",
                                  systemImage: "thermometer.high")
                                .font(.system(size: 11)).foregroundStyle(Theme.accentFiles)
                        }
                        if st.failsafe {
                            Label(st.lastError ?? "Sensor readings unavailable — safe state restored, retrying.",
                                  systemImage: "exclamationmark.octagon.fill")
                                .font(.system(size: 11)).foregroundStyle(Theme.accentUninstall)
                        } else if let err = st.lastError {
                            Label(err, systemImage: "exclamationmark.triangle")
                                .font(.system(size: 11)).foregroundStyle(Theme.accentFiles)
                        }
                    } else {
                        Text("Waiting for the Full Access helper…")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer()

                if let b = monitor.battery {
                    VStack(alignment: .leading, spacing: 6) {
                        metric(String(format: "%.1f°C", b.temperatureC), "battery temp")
                        metric(String(format: "%.1f W", abs(b.watts)), b.watts >= 0 ? "charging power" : "draw")
                        metric("\(String(format: "%.1f", b.healthPercent))% · \(b.cycleCount) cycles", "health")
                    }
                }
            }
        }
    }

    private var modeBadge: some View {
        Text(haveStatus ? mode.label : "Helper offline")
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Theme.accentBattery.opacity(haveStatus && mode != .unsupported ? 0.2 : 0.08)))
            .foregroundStyle(haveStatus && mode != .unsupported ? Theme.accentBattery : .secondary)
    }

    private var chargeStateLabel: String {
        guard let st = state.status else {
            return (monitor.battery?.isCharging ?? false) ? "charging" : "battery"
        }
        if st.isCharging { return "charging" }
        if st.externalConnected { return "on AC" }
        return "on battery"
    }

    private var limitCard: some View {
        LQCard {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { state.config.enabled },
                    set: { on in state.config.enabled = on; applyConfig() }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Charge limit").font(.system(size: 14, weight: .semibold))
                        Text("Stop charging at the limit instead of 100%. Staying below full charge is the single best habit for long-term battery health.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch).tint(Theme.accentBattery)
                .disabled(state.busy)

                HStack(spacing: 12) {
                    Slider(
                        value: Binding(
                            get: { state.pendingLimit ?? Double(state.config.limitPercent) },
                            set: { state.pendingLimit = $0 }
                        ),
                        in: 20...100, step: 1,
                        onEditingChanged: { editing in
                            if !editing, let v = state.pendingLimit {
                                state.pendingLimit = nil
                                state.config.limitPercent = Int(v)
                                applyConfig()
                            }
                        }
                    )
                    .tint(Theme.accentBattery)
                    .disabled(!state.config.enabled || state.busy)

                    Text("\(Int(state.pendingLimit ?? Double(state.config.limitPercent)))%")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(state.config.enabled ? Theme.accentBattery : .secondary)
                        .frame(width: 52, alignment: .trailing)
                }

                Stepper(value: Binding(
                    get: { state.config.sailingDelta },
                    set: { state.config.sailingDelta = $0; applyConfig() }
                ), in: 2...10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sailing interval").font(.system(size: 13, weight: .medium))
                            Text("Charging resumes once the battery drops \(state.config.sailingDelta)% below the limit — avoids micro-cycling at the threshold.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(state.config.sailingDelta)%")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                }
                .disabled(!state.config.enabled || state.busy)

                if state.busy { ProgressView().controlSize(.small) }
            }
        }
    }

    private var heatCard: some View {
        LQCard {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(
                    get: { state.config.heatProtect.enabled },
                    set: { state.config.heatProtect.enabled = $0; applyConfig() }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Heat protection").font(.system(size: 14, weight: .semibold))
                        Text("Pause charging while the battery is hot; resume automatically once it cools 2°C below the threshold (5-minute hysteresis).")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch).tint(Theme.accentFans)
                .disabled(!state.config.enabled || state.busy)

                if state.config.heatProtect.enabled {
                    HStack(spacing: 12) {
                        Slider(
                            value: Binding(
                                get: { state.config.heatProtect.thresholdC },
                                set: { state.config.heatProtect.thresholdC = $0 }
                            ),
                            in: 30...40, step: 1,
                            onEditingChanged: { editing in if !editing { applyConfig() } }
                        )
                        .tint(Theme.accentFans)
                        .disabled(!state.config.enabled || state.busy)
                        Text(String(format: "%.0f°C", state.config.heatProtect.thresholdC))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
    }

    private var actionsCard: some View {
        // One-shots need AC power (Top Up charges; Discharge/Calibration turn
        // the adapter input off) — disable with an explanation instead of
        // letting the daemon refuse after the click.
        let onAC = state.status?.externalConnected == true
        return LQCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("One-shot actions").font(.system(size: 14, weight: .semibold))

                HStack(spacing: 10) {
                    Button("Top Up to 100%") { runAction("Topping up to 100%…") { HelperClient.shared.startTopUp() } }
                        .buttonStyle(AccentButtonStyle(accent: Theme.accentBattery, prominent: false))
                        .disabled(state.busy || !onAC)

                    if state.status?.dischargeSupported == true {
                        Button("Discharge to Limit") {
                            let target = state.config.limitPercent
                            runAction("Discharging to \(target)%…") { HelperClient.shared.startDischarge(to: target) }
                        }
                        .buttonStyle(AccentButtonStyle(accent: Theme.accentFiles, prominent: false))
                        .disabled(state.busy || !onAC)

                        Button("Calibrate Battery") { runAction("Calibration started") { HelperClient.shared.startCalibration() } }
                            .buttonStyle(AccentButtonStyle(accent: Theme.accentStartup, prominent: false))
                            .disabled(state.busy || !onAC)
                    }

                    if state.status?.phase.isOneShot == true {
                        Button("Cancel") { runAction("Cancelled — back to normal limit") { HelperClient.shared.cancelChargePhase() } }
                            .buttonStyle(AccentButtonStyle(accent: Theme.accentUninstall, prominent: false))
                            .disabled(state.busy)
                    }
                }

                if !onAC {
                    Label("Plug in the charger to use one-shot actions.", systemImage: "powerplug")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accentFiles)
                }

                Text("Top Up charges to full once, then restores the limit — handy before travel. Unplugging cancels it.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)

                if case .calibration(let step) = state.status?.phase ?? .idle {
                    calibrationProgress(step)
                }

                if state.status?.dischargeSupported == true {
                    Text("Discharge turns the adapter input off and runs the Mac from battery until it reaches the target. Sleep is prevented while discharging. May be unreliable in clamshell mode or with some Thunderbolt docks.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)

                    Toggle(isOn: Binding(
                        get: { state.config.autoDischarge },
                        set: { state.config.autoDischarge = $0; applyConfig() }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Automatic discharge").font(.system(size: 13, weight: .medium))
                            Text("When the battery sits more than 3% above the limit, discharge back down to it automatically.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch).tint(Theme.accentFiles)
                    .disabled(!state.config.enabled || state.busy)
                }
            }
        }
    }

    private func calibrationProgress(_ current: CalibrationStep) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Calibration — step \(current.stepNumber) of \(CalibrationStep.stepCount)")
                .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 6) {
                ForEach(Array(CalibrationStep.allCases.enumerated()), id: \.offset) { i, step in
                    Capsule()
                        .fill(i < current.stepNumber ? Theme.accentStartup : Color.primary.opacity(0.12))
                        .frame(height: 5)
                        .help(step.label)
                }
            }
            Text(current.label)
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var ledCard: some View {
        LQCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("MagSafe LED").font(.system(size: 14, weight: .semibold))
                Picker("", selection: Binding(
                    get: { state.config.ledMode },
                    set: { state.config.ledMode = $0; applyConfig() }
                )) {
                    ForEach(ChargeLEDMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!state.config.enabled || state.busy)
                Text("Green at limit lights the LED green once the battery is held at the limit; Orange shows charging or discharging activity.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var behaviorCard: some View {
        LQCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Behavior").font(.system(size: 14, weight: .semibold))

                Toggle(isOn: Binding(
                    get: { state.config.persistOnExit },
                    set: { state.config.persistOnExit = $0; applyConfig() }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep limit when the helper stops").font(.system(size: 13, weight: .medium))
                        Text("The firmware keeps enforcing the limit across daemon restarts, reboots and sleep. Turn off to release the limit whenever the helper exits.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch).tint(Theme.accentBattery)
                .disabled(state.busy)

                Toggle(isOn: Binding(
                    get: { state.config.disableSleepUntilLimit },
                    set: { state.config.disableSleepUntilLimit = $0; applyConfig() }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Stay awake until the limit is reached").font(.system(size: 13, weight: .medium))
                        Text("Prevents idle sleep while plugged in and below the limit, so the battery reaches it before the Mac naps.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch).tint(Theme.accentBattery)
                .disabled(!state.config.enabled || state.busy)
            }
        }
    }

    private var needsFullAccessCard: some View {
        LQCard {
            VStack(alignment: .leading, spacing: 6) {
                Label("Full Access required", systemImage: "exclamationmark.shield")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accentFiles)
                Text("Charge control runs inside the privileged helper so the limit keeps working with the app closed. Enable Full Access in Settings to get started.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var staleHelperCard: some View {
        LQCard {
            VStack(alignment: .leading, spacing: 6) {
                Label("Full Access helper needs an update", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accentFiles)
                Text("The installed helper predates charge control. Remove Full Access and enable it again in Settings to update the helper.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var unsupportedCard: some View {
        LQCard {
            VStack(alignment: .leading, spacing: 6) {
                Label("Not supported on this firmware", systemImage: "info.circle")
                    .font(.system(size: 13, weight: .semibold))
                Text("This Mac's firmware doesn't expose any charge-control key (bfF0/bfD0/bfE0, CHTE or CH0B/CH0C). Use System Settings → Battery → Charging instead.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    /// Status-card metric column. 1 Hz telemetry (temp/watts) — plain
    /// monospaced digits, no AnimatedNumber, so widths stay put every tick.
    private func metric(_ v: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(v).monospacedDigit().font(.system(size: 13, weight: .bold, design: .rounded))
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    // MARK: - plumbing

    /// Poll the daemon (XPC on a background queue, UI on main).
    private func refresh() {
        let installed = HelperClient.shared.isDaemonInstalled()
        state.daemonInstalled = installed
        guard installed else {
            state.status = nil
            state.staleHelper = false
            ChargeSleepGuard.shared.update(shouldHold: false)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            HelperClient.shared.chargeStatus { st in
                DispatchQueue.main.async {
                    state.status = st
                    state.staleHelper = (st == nil)
                    // Adopt the daemon's authoritative config once, so the UI
                    // reflects what actually survives reboots. Never adopt over
                    // a pending user edit: an in-flight apply (busy) or a
                    // mid-drag slider (pendingLimit) is the authoritative
                    // intent, and applyConfig latches syncedWithDaemon itself.
                    if !state.syncedWithDaemon, !state.busy, state.pendingLimit == nil,
                       let cfg = st?.config {
                        state.syncedWithDaemon = true
                        state.config = cfg
                        AppSettings.shared.chargeConfig = cfg
                    }
                    updateSleepGuard()
                }
            }
        }
    }

    private func updateSleepGuard() {
        let st = state.status
        let hold = state.config.enabled
            && state.config.disableSleepUntilLimit
            && (st?.externalConnected ?? false)
            && (st?.batteryPercent ?? 100) < state.config.limitPercent
        ChargeSleepGuard.shared.update(shouldHold: hold)
    }

    /// Persist app-side and push the full config to the daemon.
    private func applyConfig() {
        let cfg = state.config.sanitized()
        state.config = cfg
        // The user's edit is now the authoritative config — latch the sync
        // flag BEFORE the push so an in-flight status reply (carrying the
        // daemon's pre-push config) can't adopt over it and silently revert
        // the change the user just made.
        state.syncedWithDaemon = true
        AppSettings.shared.chargeConfig = cfg
        state.busy = true
        state.message = nil
        let helper = helperPath
        DispatchQueue.global(qos: .userInitiated).async {
            let r = HelperClient.shared.setChargeConfig(cfg, fallbackHelperBinary: helper)
            DispatchQueue.main.async {
                state.busy = false
                if !r.ok { state.message = r.message; state.messageIsError = true }
                updateSleepGuard()
                refresh()
            }
        }
    }

    /// Run a blocking one-shot RPC off the main thread.
    private func runAction(_ successNote: String,
                           _ action: @escaping @Sendable () -> (ok: Bool, message: String)) {
        state.busy = true
        state.message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let r = action()
            DispatchQueue.main.async {
                state.busy = false
                // Success gets feedback too — a button that "does nothing"
                // visible reads as broken even when the daemon accepted it.
                state.message = r.ok ? successNote : r.message
                state.messageIsError = !r.ok
                refresh()
            }
        }
    }
}
