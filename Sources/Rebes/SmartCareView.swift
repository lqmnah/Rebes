//
//  SmartCareView.swift
//  Rebes
//
//  One-click "Smart Care": scans every module (junk, trash, startup, temps),
//  shows a single recommendation screen, and cleans everything selected.
//

import SwiftUI
import RebesCore

class SmartCareState: ObservableObject {
    @Published var isScanning = false
    @Published var didScan = false
    @Published var junkCategories: [JunkCategory] = []
    @Published var trashSize: Int64 = 0
    @Published var startupCount = 0
    @Published var maxTemp: Double = 0
    @Published var isCleaning = false
    @Published var resultMessage: String?
    @Published var confirm = false
    @Published var showBeres = false
    @Published var beresDetail = ""

    var reclaimable: Int64 {
        junkCategories.filter { !$0.isDisplayOnly && $0.isSelected }.reduce(0) { $0 + $1.size }
    }
}

struct SmartCareView: View {
    @StateObject private var state = SmartCareState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(
                    title: "Smart Care",
                    subtitle: "One click to check & care for your whole Mac",
                    accent: Theme.teal,
                    icon: "wand.and.stars",
                    isBusy: state.isScanning
                )

                if !state.didScan {
                    LQCard(padding: 40) {
                        VStack(spacing: 16) {
                            ZStack {
                                Circle().fill(Theme.teal.opacity(0.12)).frame(width: 120, height: 120)
                                // No repeating symbolEffect here — scan life is
                                // cued once, by the SectionHeader isBusy pulse
                                // (the one allowed continuous animation).
                                Image(systemName: state.isScanning ? "rays" : "wand.and.stars")
                                    .font(.system(size: 46)).foregroundStyle(Theme.teal)
                            }
                            Text(state.isScanning ? "Taking a good look around your Mac…" : "One click and Rebes checks junk, Trash, startup items, and temperature. You just relax.")
                                .font(.system(size: 14)).foregroundStyle(.primary)
                                .multilineTextAlignment(.center)
                            Button(state.isScanning ? "Checking…" : "Start Smart Care") { scan() }
                                .buttonStyle(AccentButtonStyle())
                                .controlSize(.large)
                                .disabled(state.isScanning)
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            // Scan total: slow, event-driven → AnimatedNumber
                            // stays. 32pt matches the Smart Scan hero numeral.
                            AnimatedNumber(text: state.reclaimable.formattedSize, value: Double(state.reclaimable))
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.teal)
                            Text(state.reclaimable == 0 ? "all clean — nothing to do here. Nice." : "can be cleaned")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Rescan") { scan() }.buttonStyle(AccentButtonStyle(prominent: false))
                        Button(state.isCleaning ? "Cleaning…" : "Care Now") { state.confirm = true }
                            .buttonStyle(AccentButtonStyle())
                            .disabled(state.reclaimable == 0 || state.isCleaning)
                    }

                    if let msg = state.resultMessage {
                        LQCard(padding: 12) {
                            Label(msg, systemImage: "checkmark.seal.fill")
                                .font(.system(size: 12)).foregroundStyle(Theme.accentBattery)
                        }
                    }

                    careRow("sparkles", "Junk & Cache", state.reclaimable.formattedSize, Theme.accentScan,
                            "\(state.junkCategories.filter { !$0.isDisplayOnly }.count) categories — will be moved to Trash")
                        .cascadeIn(0)
                    careRow("trash", "Current Trash", state.trashSize.formattedSize, Theme.accentUninstall,
                            "empty manually in Maintenance")
                        .cascadeIn(1)
                    careRow("bolt.badge.clock", "Startup Items", "\(state.startupCount)", Theme.accentStartup,
                            "active launch agents in ~/Library/LaunchAgents")
                        .cascadeIn(2)
                    careRow("thermometer.medium", "Highest CPU temperature",
                            state.maxTemp > 0 ? String(format: "%.0f°C", state.maxTemp) : "—",
                            state.maxTemp > 85 ? Theme.accentUninstall : Theme.accentFans,
                            state.maxTemp > 85 ? "hot — consider a fan curve in Settings" : "within normal range")
                        .cascadeIn(3)
                }
            }
            .padding(24)
        }
        .background(Theme.bg)
        .beresStamp(isPresented: $state.showBeres, detail: state.beresDetail)
        .confirmationDialog("Move \(state.reclaimable.formattedSize) of junk to Trash?", isPresented: $state.confirm) {
            Button("Care Now", role: .destructive) { clean() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func careRow(_ icon: String, _ title: String, _ value: String, _ accent: Color, _ detail: String) -> some View {
        LQCard(padding: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(accent.opacity(0.15)).frame(width: 34, height: 34)
                    Image(systemName: icon).foregroundStyle(accent)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                    Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(value).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(accent)
            }
        }
    }

    private func scan() {
        state.isScanning = true
        state.resultMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let cats = SafeCleaner.shared.scanJunk()
            let trash = cats.first { $0.isDisplayOnly }?.size ?? 0
            let startup = ((try? FileManager.default.contentsOfDirectory(atPath: "\(SafeCleaner.shared.homeDir)/Library/LaunchAgents"))?.filter { $0.hasSuffix(".plist") }.count) ?? 0
            let temp = ["Tp01", "Tp05", "TC10"].compactMap { SMC.shared.getValue($0) }.max() ?? 0
            DispatchQueue.main.async {
                state.junkCategories = cats
                state.trashSize = trash
                state.startupCount = startup
                state.maxTemp = temp
                state.isScanning = false
                state.didScan = true
            }
        }
    }

    private func clean() {
        state.isCleaning = true
        let cats = state.junkCategories.filter { !$0.isDisplayOnly && $0.isSelected }
        DispatchQueue.global(qos: .userInitiated).async {
            var freed: Int64 = 0
            for cat in cats {
                for items in cat.items {
                    let size = SafeCleaner.shared.directorySize(url: items)
                    if (try? SafeCleaner.shared.trashItem(at: items)) != nil { freed += size }
                }
            }
            let freedFinal = freed
            DispatchQueue.main.async {
                state.isCleaning = false
                state.resultMessage = "\(freedFinal.formattedSize) moved to Trash — your Mac feels fresher already."
                state.beresDetail = freedFinal > 0 ? "\(freedFinal.formattedSize) cleaned" : ""
                state.showBeres = true
                scan()
            }
        }
    }
}
