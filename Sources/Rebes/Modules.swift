//
//  Modules.swift
//  Rebes
//
//  Smart Scan module: scan junk categories, review, clean to Trash.
//

import SwiftUI
import AppKit
import RebesCore

extension Int64 {
    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: self)
    }
}

class SmartScanState: ObservableObject {
    @Published var categories: [JunkCategory] = []
    @Published var isScanning = false
    @Published var isCleaning = false
    @Published var showConfirm = false
    @Published var lastFreed: Int64?
    @Published var failures: [String] = []
    @Published var showBeres = false
    @Published var beresDetail = ""
}

struct SmartScanView: View {
    @StateObject private var state = SmartScanState()

    var totalSize: Int64 {
        state.categories.filter { $0.isSelected && !$0.isDisplayOnly }.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(
                    title: "Smart Scan",
                    subtitle: "Caches, logs & junk that are safe to clean — all go to Trash first",
                    accent: Theme.accentScan,
                    icon: "sparkles",
                    isBusy: state.isScanning
                )

                if state.categories.isEmpty {
                    LQCard(padding: 40) {
                        VStack(spacing: 16) {
                            ZStack {
                                Circle().fill(Theme.teal.opacity(0.12)).frame(width: 110, height: 110)
                                // No repeating symbolEffect here — scan life is
                                // cued once, by the SectionHeader isBusy pulse
                                // (the one allowed continuous animation).
                                Image(systemName: state.isScanning ? "rays" : "sparkles")
                                    .font(.system(size: 42))
                                    .foregroundStyle(Theme.teal)
                            }
                            Text(state.isScanning ? "Sniffing out junk on your Mac…" : "Let's find the junk hiding on your Mac. Everything goes to Trash first — nothing is deleted outright.")
                                .foregroundStyle(.primary)
                                .font(.system(size: 14, weight: .medium))
                                .multilineTextAlignment(.center)
                            Button(state.isScanning ? "Scanning…" : "Start Scan") { scan() }
                                .buttonStyle(AccentButtonStyle())
                                .disabled(state.isScanning)
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            AnimatedNumber(text: totalSize.formattedSize, value: Double(totalSize))
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.teal)
                            Text(totalSize == 0 ? "nothing selected to clean — all done" : "can be cleaned (selected)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Rescan") { scan() }
                            .buttonStyle(AccentButtonStyle(prominent: false))
                            .disabled(state.isScanning || state.isCleaning)
                        Button(state.isCleaning ? "Cleaning…" : "Clean") { state.showConfirm = true }
                            .buttonStyle(AccentButtonStyle())
                            .disabled(totalSize == 0 || state.isCleaning)
                    }

                    if let freed = state.lastFreed {
                        LQCard(padding: 12) {
                            Label("\(freed.formattedSize) moved to Trash — done. Empty the Trash in Maintenance when you're sure.", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.accentBattery)
                        }
                    }
                    if !state.failures.isEmpty {
                        LQCard(padding: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("\(state.failures.count) items failed to move:", systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.accentFiles)
                                ForEach(state.failures.prefix(5), id: \.self) { f in
                                    Text(f).font(.system(size: 10)).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
                    }

                    VStack(spacing: 10) {
                        ForEach(state.categories.indices, id: \.self) { i in
                            let cat = state.categories[i]
                            LQCard(padding: 12) {
                                HStack {
                                    if cat.isDisplayOnly {
                                        Image(systemName: "trash")
                                            .foregroundStyle(.secondary)
                                            .frame(width: 24)
                                    } else {
                                        Toggle("", isOn: $state.categories[i].isSelected)
                                            .toggleStyle(.checkbox)
                                            .frame(width: 24)
                                    }
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(cat.name)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(.primary)
                                        Text(cat.isDisplayOnly ? "info only — empty via Maintenance" : "\(cat.items.count) items")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(cat.size.formattedSize)
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .foregroundStyle(cat.isDisplayOnly ? .secondary : Theme.teal)
                                }
                            }
                            .cascadeIn(i)
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(Theme.bg)
        .beresStamp(isPresented: $state.showBeres, detail: state.beresDetail)
        .confirmationDialog(
            "Move \(totalSize.formattedSize) to Trash?",
            isPresented: $state.showConfirm
        ) {
            Button("Move to Trash", role: .destructive) { clean() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func scan() {
        state.isScanning = true
        state.lastFreed = nil
        state.failures = []
        DispatchQueue.global(qos: .userInitiated).async {
            let result = SafeCleaner.shared.scanJunk()
            DispatchQueue.main.async {
                state.categories = result
                state.isScanning = false
            }
        }
    }

    private func clean() {
        state.isCleaning = true
        let selected = state.categories.filter { $0.isSelected && !$0.isDisplayOnly }
        DispatchQueue.global(qos: .userInitiated).async {
            var freed: Int64 = 0
            var failures: [String] = []
            for cat in selected {
                for items in cat.items {
                    let size = SafeCleaner.shared.directorySize(url: items)
                    do {
                        try SafeCleaner.shared.trashItem(at: items)
                        freed += size
                    } catch {
                        failures.append(items.lastPathComponent)
                    }
                }
            }
            let freedFinal = freed
            let failuresFinal = failures
            DispatchQueue.main.async {
                state.isCleaning = false
                state.lastFreed = freedFinal
                state.failures = failuresFinal
                if failuresFinal.isEmpty {
                    state.beresDetail = freedFinal > 0 ? "\(freedFinal.formattedSize) cleaned" : ""
                    state.showBeres = true
                }
                scan()
            }
        }
    }
}
