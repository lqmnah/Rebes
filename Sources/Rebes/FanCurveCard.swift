//
//  FanCurveCard.swift
//  Rebes
//
//  Automatic temperature→RPM fan curve control. Lives in Fans & Temps.
//  Runs inside the root daemon (needs Full Access), so it keeps working with
//  the app closed.
//

import SwiftUI
import RebesCore

final class FanCurveState: ObservableObject {
    @Published var daemonAlive = false
    @Published var enabled = AppSettings.shared.fanCurveEnabled
    @Published var curve: [FanCurvePoint] = AppSettings.shared.fanCurve
    @Published var status = ""
    @Published var busy = false
}

struct FanCurveCard: View {
    @StateObject private var s = FanCurveState()

    var body: some View {
        LQCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Automatic Fan Curve", systemImage: "fan.oscillation")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                    Spacer()
                    Toggle("", isOn: Binding(get: { s.enabled }, set: { s.enabled = $0; apply() }))
                        .toggleStyle(.switch).tint(Theme.accentFans)
                        .disabled(!s.daemonAlive || s.busy)
                }
                if !s.daemonAlive {
                    Label("Requires Full Access — enable it in Settings first.", systemImage: "exclamationmark.shield")
                        .font(.system(size: 11)).foregroundStyle(Theme.accentFiles)
                }
                Text("The daemon ramps fan RPM with CPU temperature, running in the background even when the app is closed.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)

                ForEach($s.curve) { $point in
                    HStack {
                        Text("\(Int(point.tempC))°C")
                            .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .leading)
                        Slider(value: $point.percent, in: 0...100, step: 5)
                            .tint(Theme.accentFans)
                            .disabled(!s.enabled)
                        AnimatedNumber(text: "\(Int(point.percent))%", value: point.percent)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary).frame(width: 40, alignment: .trailing)
                    }
                }
                HStack {
                    Button("Reset Default") { s.curve = AppSettings.defaultCurve; apply() }
                        .buttonStyle(AccentButtonStyle(prominent: false))
                    Spacer()
                    if s.enabled {
                        Button("Apply Curve") { apply() }
                            .buttonStyle(AccentButtonStyle(accent: Theme.accentFans))
                            .disabled(s.busy)
                    }
                    if s.busy { ProgressView().controlSize(.small) }
                }
                if !s.status.isEmpty {
                    Text(s.status).font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary)
                }
            }
        }
        .hoverLift(accent: Theme.accentFans, scale: 1.01, pointer: false)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        s.daemonAlive = HelperClient.shared.isDaemonInstalled()
        HelperClient.shared.fanCurveStatus { running, status in
            DispatchQueue.main.async { if running { s.status = status } }
        }
    }

    private func apply() {
        AppSettings.shared.fanCurveEnabled = s.enabled
        AppSettings.shared.fanCurve = s.curve
        s.busy = true
        let enabled = s.enabled
        let curve = s.curve
        DispatchQueue.global(qos: .userInitiated).async {
            let result = HelperClient.shared.setFanCurve(enabled: enabled, curve: curve)
            DispatchQueue.main.async {
                s.busy = false
                s.status = result.message
                if !result.ok { s.enabled = false }
            }
        }
    }
}
