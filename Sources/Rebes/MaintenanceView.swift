//
//  MaintenanceView.swift
//  Rebes
//
//  Maintenance actions (all async, all with feedback):
//  - Flush DNS / Purge RAM (root ops — via the Full Access daemon when
//    installed, so no password prompt; else one admin prompt)
//  - Empty Trash (confirmation required — the ONLY irreversible action here)
//  Plus Startup Items (LaunchAgents enable/disable).
//

import SwiftUI
import AppKit
import RebesCore

class MaintenanceState: ObservableObject {
    @Published var busyAction: String?
    @Published var errorMessage: String?
    @Published var confirmEmptyTrash = false
    @Published var trashSize: Int64 = 0
    // Successes get the BeresStamp; only errors use the log card.
    @Published var showBeres = false
    @Published var beresDetail = ""
}

struct MaintenanceView: View {
    @StateObject private var state = MaintenanceState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(
                    title: "Maintenance",
                    subtitle: "One-click system maintenance",
                    accent: Theme.accentMaintenance,
                    icon: "wrench.and.screwdriver"
                )

                VStack(spacing: 10) {
                    actionCard(
                        icon: "network", title: "Flush DNS Cache",
                        buttonTitle: "Run", accent: Theme.accentMaintenance, actionKey: "dns",
                        action: {
                            runPrivileged("dns", done: "DNS cache cleared") { HelperClient.shared.flushDNS() }
                        }
                    ) {
                        Text("Clear the DNS cache (dscacheutil + mDNSResponder) — no password needed with Full Access")
                    }
                    actionCard(
                        icon: "memorychip", title: "Purge RAM",
                        buttonTitle: "Purge", accent: Theme.accentStartup, actionKey: "purge",
                        action: {
                            runPrivileged("purge", done: "RAM purged") { HelperClient.shared.purgeRAM() }
                        }
                    ) {
                        Text("Release inactive/purgeable memory — no password needed with Full Access")
                    }
                    actionCard(
                        icon: "trash", title: "Empty Trash",
                        buttonTitle: "Empty…", accent: Theme.accentUninstall, actionKey: "trash",
                        action: { state.confirmEmptyTrash = true }
                    ) {
                        // Live size rolls as the Trash fills/empties.
                        HStack(spacing: 3) {
                            Text("PERMANENT —")
                            AnimatedNumber(text: state.trashSize.formattedSize, value: Double(state.trashSize))
                                .fontWeight(.semibold)
                            Text("in Trash right now. Cannot be undone.")
                        }
                    }
                }

                if let err = state.errorMessage {
                    LQCard(padding: 12) {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.accentUninstall)
                    }
                }

                Divider().overlay(Theme.stroke)
                StartupItemsInline()
            }
            .padding(24)
        }
        .background(Theme.bg)
        .beresStamp(isPresented: $state.showBeres, detail: state.beresDetail)
        .onAppear(perform: refreshTrashSize)
        .confirmationDialog(
            "Empty Trash (\(state.trashSize.formattedSize))? All contents are deleted PERMANENTLY and cannot be undone.",
            isPresented: $state.confirmEmptyTrash
        ) {
            Button("Empty Permanently", role: .destructive) { emptyTrash() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func actionCard<Detail: View>(
        icon: String, title: String, buttonTitle: String,
        accent: Color, actionKey: String,
        action: @escaping () -> Void,
        @ViewBuilder detail: () -> Detail
    ) -> some View {
        LQCard(padding: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(accent.opacity(0.15))
                        .frame(width: 38, height: 38)
                    Image(systemName: icon)
                        .foregroundStyle(accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                    detail()
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if state.busyAction == actionKey {
                    ProgressView().controlSize(.small)
                } else {
                    Button(buttonTitle, action: action)
                        .buttonStyle(AccentButtonStyle(accent: accent, prominent: false))
                        .disabled(state.busyAction != nil)
                }
            }
        }
        .hoverLift(accent: accent)
    }

    private func runPrivileged(_ key: String, done: String,
                               _ operation: @escaping @Sendable () -> (ok: Bool, message: String)) {
        state.busyAction = key
        state.errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = operation()
            DispatchQueue.main.async {
                state.busyAction = nil
                if result.ok {
                    state.beresDetail = done
                    state.showBeres = true
                } else {
                    state.errorMessage = "Failed: \(result.message)"
                }
            }
        }
    }

    private func emptyTrash() {
        state.busyAction = "trash"
        state.errorMessage = nil
        let freed = state.trashSize
        DispatchQueue.global(qos: .userInitiated).async {
            let result = AdminShell.runOsascript("tell application \"Finder\" to empty trash")
            SafeCleaner.shared.logAction(result.ok ? "Emptied Trash" : "Empty Trash failed: \(result.output)")
            DispatchQueue.main.async {
                state.busyAction = nil
                if result.ok {
                    state.beresDetail = freed > 0 ? "\(freed.formattedSize) freed from Trash" : ""
                    state.showBeres = true
                } else {
                    state.errorMessage = "Failed to empty Trash: \(result.output)"
                }
                refreshTrashSize()
            }
        }
    }

    private func refreshTrashSize() {
        DispatchQueue.global(qos: .utility).async {
            var size: Int64 = 0
            let trashUrl = URL(fileURLWithPath: "\(SafeCleaner.shared.homeDir)/.Trash")
            if let contents = try? FileManager.default.contentsOfDirectory(at: trashUrl, includingPropertiesForKeys: nil) {
                for items in contents {
                    size += SafeCleaner.shared.directorySize(url: items)
                }
            }
            DispatchQueue.main.async { state.trashSize = size }
        }
    }
}

// MARK: - Startup Items

class StartupItemsState: ObservableObject {
    @Published var items: [StartupItem] = []
    @Published var errorMessage: String?
}

struct StartupItem: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    var isDisabled: Bool
}

struct StartupItemsInline: View {
    @StateObject private var state = StartupItemsState()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Startup Items (~/Library/LaunchAgents)", systemImage: "bolt.badge.clock")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            if let err = state.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accentUninstall)
            }

            if state.items.isEmpty {
                Label("Nothing launches behind your back. Nice.", systemImage: "hand.thumbsup")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            ForEach($state.items) { $items in
                LQCard(padding: 10) {
                    HStack {
                        Circle()
                            .fill(items.isDisabled ? Color.secondary.opacity(0.4) : Theme.accentBattery)
                            .frame(width: 8, height: 8)
                        Text(items.name)
                            .font(.system(size: 11))
                            .foregroundStyle(.primary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([items.url])
                        } label: {
                            Image(systemName: "magnifyingglass.circle")
                        }
                        .buttonStyle(.plain)
                        Toggle("", isOn: Binding(
                            get: { !items.isDisabled },
                            set: { enable in toggleItem(items: items, enable: enable) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .tint(Theme.accentStartup)
                    }
                }
                .hoverLift(accent: Theme.accentStartup)
            }
        }
        .onAppear(perform: loadItems)
    }

    private func loadItems() {
        let dir = URL(fileURLWithPath: "\(SafeCleaner.shared.homeDir)/Library/LaunchAgents")
        var found: [StartupItem] = []
        if let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in contents {
                if url.pathExtension == "plist" {
                    found.append(StartupItem(url: url, name: url.lastPathComponent, isDisabled: false))
                } else if url.pathExtension == "disabled" {
                    found.append(StartupItem(url: url, name: url.deletingPathExtension().lastPathComponent, isDisabled: true))
                }
            }
        }
        state.items = found.sorted { $0.name < $1.name }
    }

    private func toggleItem(items: StartupItem, enable: Bool) {
        let oldUrl = items.url
        let newUrl: URL
        if enable {
            // name.plist.disabled -> name.plist
            newUrl = oldUrl.deletingPathExtension()
        } else {
            newUrl = oldUrl.appendingPathExtension("disabled")
        }

        do {
            try FileManager.default.moveItem(at: oldUrl, to: newUrl)
            SafeCleaner.shared.logAction("Renamed \(oldUrl.path) to \(newUrl.path)")
            state.errorMessage = nil
            loadItems()
        } catch {
            state.errorMessage = "Failed to change \(items.name): \(error.localizedDescription)"
        }
    }
}

/// Kept for sidebar compatibility — Startup Items also has its own entry.
struct StartupItemsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(
                    title: "Startup Items",
                    subtitle: "Manage user-level launch agents",
                    accent: Theme.accentStartup,
                    icon: "bolt.badge.clock"
                )
                StartupItemsInline()
            }
            .padding(24)
        }
        .background(Theme.bg)
    }
}
