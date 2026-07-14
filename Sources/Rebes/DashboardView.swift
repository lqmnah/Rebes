//
//  DashboardView.swift
//  Rebes
//
//  Hero landing view: disk ring, live system meters, quick actions.
//

import SwiftUI
import RebesCore

struct DashboardView: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @Binding var selection: SidebarItem?

    /// Rough live health score driving the greeting tone — full marks unless
    /// disk, memory, CPU load or temperature look stressed.
    private var healthScore: Int {
        var score = 100
        let s = monitor.snapshot
        if s.diskUsedPercent > 90 { score -= 30 } else if s.diskUsedPercent > 80 { score -= 10 }
        if s.memUsedPercent > 90 { score -= 15 }
        if s.cpuUsagePercent > 85 { score -= 15 }
        if let t = monitor.cpuTemp, t > 85 { score -= 20 }
        return max(0, score)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(
                    title: "Dashboard",
                    subtitle: RebesVoice.greeting(name: RebesVoice.firstName, score: healthScore),
                    accent: Theme.teal,
                    icon: "gauge.with.dots.needle.67percent"
                )

                HStack(spacing: 20) {
                    LQCard {
                        VStack(spacing: 14) {
                            StatRing(
                                progress: monitor.snapshot.diskUsedPercent / 100,
                                accent: Theme.teal,
                                lineWidth: 12,
                                label: monitor.snapshot.diskFreeBytes.formattedSize,
                                sublabel: "free of \(monitor.snapshot.diskTotalBytes.formattedSize)",
                                // The label shows FREE space while the ring shows
                                // the USED fraction — drive the digit roll with the
                                // free-bytes value so it moves with the number.
                                labelValue: Double(monitor.snapshot.diskFreeBytes)
                            )
                            .frame(width: 170, height: 170)

                            Button("Smart Scan Now") { selection = .smartScan }
                                .buttonStyle(AccentButtonStyle())
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .frame(width: 260)

                    VStack(spacing: 14) {
                        HStack(spacing: 14) {
                            meterCard(
                                icon: "cpu", title: "CPU",
                                value: String(format: "%.0f%%", monitor.snapshot.cpuUsagePercent),
                                detail: monitor.cpuTemp.map { String(format: "%.0f°C", $0) } ?? "—",
                                progress: monitor.snapshot.cpuUsagePercent / 100,
                                accent: Theme.accentFans
                            )
                            meterCard(
                                icon: "memorychip", title: "Memory",
                                value: String(format: "%.0f%%", monitor.snapshot.memUsedPercent),
                                detail: "\(Int64(monitor.snapshot.memUsedBytes).formattedSize) used",
                                progress: monitor.snapshot.memUsedPercent / 100,
                                accent: Theme.accentStartup
                            )
                        }
                        HStack(spacing: 14) {
                            meterCard(
                                icon: "arrow.down.circle", title: "Download",
                                value: monitor.snapshot.netDownBytesPerSec.bytesPerSecFormatted,
                                detail: "network",
                                progress: min(monitor.snapshot.netDownBytesPerSec / 10_000_000, 1),
                                accent: Theme.accentBattery
                            )
                            meterCard(
                                icon: "arrow.up.circle", title: "Upload",
                                value: monitor.snapshot.netUpBytesPerSec.bytesPerSecFormatted,
                                detail: "network",
                                progress: min(monitor.snapshot.netUpBytesPerSec / 10_000_000, 1),
                                accent: Theme.accentFiles
                            )
                        }
                        if let battery = monitor.battery {
                            // Aligned with the Fans row below: same card
                            // padding, icon size and trailing capsule button.
                            LQCard(padding: 14) {
                                HStack(spacing: 12) {
                                    Image(systemName: battery.isCharging ? "battery.100.bolt" : "battery.75")
                                        .font(.system(size: 18))
                                        .foregroundStyle(Theme.accentBattery)
                                    AnimatedNumber(
                                        text: "Battery \(battery.currentChargePercent)%",
                                        value: Double(battery.currentChargePercent)
                                    )
                                    .foregroundStyle(.primary)
                                    Text("· Health \(battery.healthPercent)% · \(battery.cycleCount) cycles")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Details") { selection = .battery }
                                        .buttonStyle(AccentButtonStyle(accent: Theme.accentBattery, prominent: false))
                                        // 17 = half the capsule button's ~34pt
                                        // height, so the hover ring IS a capsule.
                                        .hoverLift(accent: Theme.accentBattery, cornerRadius: 17, scale: 1.02)
                                }
                                .font(.system(size: 12))
                            }
                        }
                    }
                }

                if !monitor.fans.isEmpty {
                    LQCard(padding: 14) {
                        HStack(spacing: 22) {
                            Image(systemName: "fanblades")
                                .font(.system(size: 18))
                                .foregroundStyle(Theme.accentFans)
                            ForEach(monitor.fans) { fan in
                                HStack(spacing: 6) {
                                    Text("Fan \(fan.id + 1)")
                                        .foregroundStyle(.secondary)
                                    // 1 Hz telemetry: plain monospaced digits
                                    // (see KipasSuhu) — parked fans say "idle".
                                    Text(fan.actual.rpmLabel)
                                        .monospacedDigit()
                                        .foregroundStyle(.primary)
                                        .fontWeight(.semibold)
                                    if fan.mode == 1 {
                                        Text("MANUAL")
                                            .font(.system(size: 9, weight: .bold))
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Capsule().fill(Theme.accentUninstall.opacity(0.25)))
                                            .foregroundStyle(Theme.accentUninstall)
                                    }
                                }
                                .font(.system(size: 12))
                            }
                            Spacer()
                            Button("Control") { selection = .fans }
                                .buttonStyle(AccentButtonStyle(accent: Theme.accentFans, prominent: false))
                                .hoverLift(accent: Theme.accentFans, cornerRadius: 17, scale: 1.02)
                        }
                    }
                }

                // Quick actions — equal-width tiles filling the row.
                LQCard(padding: 14) {
                    HStack(spacing: 12) {
                        quickAction("sparkles", "Smart Scan", Theme.teal) { selection = .smartScan }
                        quickAction("doc.text.magnifyingglass", "Large Files", Theme.accentFiles) { selection = .largeFiles }
                        quickAction("xmark.app.fill", "Uninstaller", Theme.accentUninstall) { selection = .uninstaller }
                        quickAction("wrench.and.screwdriver", "Maintenance", Theme.accentMaintenance) { selection = .maintenance }
                    }
                }
            }
            .padding(24)
        }
        .background(Theme.bg)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    /// One live metric card. All four (CPU/Memory/Download/Upload) share this
    /// exact structure — icon chip + title row, big rounded numeric, caption,
    /// thin progress — so heights and typography stay identical.
    /// 1 Hz rule: these values tick every monitor update, so they render as
    /// PLAIN monospaced digits — no AnimatedNumber (see KipasSuhu).
    private func meterCard(icon: String, title: String, value: String, detail: String, progress: Double, accent: Color) -> some View {
        LQCard(padding: 14, cornerRadius: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(accent.opacity(0.15))
                            .frame(width: 26, height: 26)
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Text(value)
                    .monospacedDigit()
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(detail)
                    .monospacedDigit()
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                ProgressView(value: max(0, min(progress, 1)))
                    .tint(accent)
            }
        }
        .hoverLift(accent: accent, cornerRadius: 12, pointer: false)   // informational card, not clickable
    }

    private func quickAction(_ icon: String, _ title: String, _ accent: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(accent)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(accent.opacity(0.10))
            )
        }
        .buttonStyle(.plain)
        .hoverLift(accent: accent, cornerRadius: 12)
    }
}
