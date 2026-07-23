//
//  UninstallerView.swift
//  Rebes
//
//  Uninstall /Applications apps with their leftovers. Only unambiguous
//  matches (bundle-id / exact name) are pre-selected; loose name matches
//  are listed unchecked. If the app bundle itself cannot be trashed,
//  nothing else is deleted.
//

import SwiftUI
import AppKit
import RebesCore

struct AppItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let bundleId: String
    let icon: NSImage
}

struct LeftoverItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let size: Int64
    let kind: LeftoverMatchKind
    var isSelected: Bool
}

class UninstallerState: ObservableObject {
    @Published var apps: [AppItem] = []
    @Published var selectedApp: AppItem?
    @Published var leftovers: [LeftoverItem] = []
    @Published var showConfirm = false
    @Published var isLoading = false
    @Published var isFindingLeftovers = false
    @Published var isUninstalling = false
    @Published var errorMessage: String?
    // Success is celebrated with the BeresStamp, not a log line.
    @Published var showBeres = false
    @Published var beresDetail = ""
}

struct UninstallerView: View {
    @StateObject private var state = UninstallerState()

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(
                    title: "Uninstaller",
                    subtitle: "Remove apps + their leftover data",
                    accent: Theme.accentUninstall,
                    icon: "xmark.app.fill"
                )
                if state.isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    List(state.apps, selection: $state.selectedApp) { app in
                        HStack(spacing: 8) {
                            Image(nsImage: app.icon)
                                .resizable()
                                .frame(width: 26, height: 26)
                            Text(app.name)
                                .font(.system(size: 12))
                        }
                        .tag(app)
                        .hoverLift(accent: Theme.accentUninstall, cornerRadius: 8)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .padding(16)
            .frame(width: 300)

            Divider().overlay(Theme.stroke)

            VStack(alignment: .leading, spacing: 12) {
                if let err = state.errorMessage {
                    LQCard(padding: 10) {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.accentUninstall)
                    }
                }
                if let app = state.selectedApp {
                    HStack {
                        Image(nsImage: app.icon).resizable().frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.primary)
                            Text(app.bundleId)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(state.isUninstalling ? "Uninstalling…" : "Uninstall…") { state.showConfirm = true }
                            .buttonStyle(AccentButtonStyle(accent: Theme.accentUninstall))
                            .disabled(state.isFindingLeftovers || state.isUninstalling)
                    }

                    if state.isFindingLeftovers {
                        ProgressView("Finding leftovers…").frame(maxWidth: .infinity)
                    } else if state.leftovers.isEmpty {
                        Label("No leftovers found — this app kept things tidy.", systemImage: "hand.thumbsup")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                    } else {
                        Text("Leftovers — checked items are removed too. Fuzzy items (partial name match) are intentionally left unchecked.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        List($state.leftovers) { $items in
                            HStack {
                                Toggle("", isOn: $items.isSelected)
                                    .toggleStyle(.checkbox)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(items.url.lastPathComponent)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.primary)
                                    Text(items.url.deletingLastPathComponent().path)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                if items.kind == .nameSubstring {
                                    Text("FUZZY")
                                        .font(.system(size: 8, weight: .bold))
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(Capsule().fill(Theme.accentFiles.opacity(0.2)))
                                        .foregroundStyle(Theme.accentFiles)
                                }
                                Spacer()
                                Text(items.size.formattedSize)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .hoverLift(accent: Theme.accentUninstall, cornerRadius: 8)
                            .cascadeIn(min(state.leftovers.firstIndex(where: { $0.id == items.id }) ?? 0, 12))
                        }
                        .scrollContentBackground(.hidden)
                    }
                } else {
                    Spacer()
                    VStack(spacing: 10) {
                        Image(systemName: "hand.thumbsup")
                            .font(.system(size: 32, weight: .medium))
                            .foregroundStyle(.tertiary)
                        Text("Pick an app on the left")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("Rebes finds its leftover files and clears everything in one go.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    Spacer()
                }
            }
            .padding(16)
        }
        .background(Theme.bg)
        .beresStamp(isPresented: $state.showBeres, detail: state.beresDetail)
        .onAppear(perform: loadApps)
        .onChange(of: state.selectedApp) { _, newValue in
            // Keep the message visible after uninstall clears the selection —
            // only a fresh pick resets it.
            if newValue != nil { state.errorMessage = nil }
            if let app = newValue {
                findLeftovers(for: app)
            } else {
                state.leftovers = []
            }
        }
        .confirmationDialog(
            "Move \(state.selectedApp?.name ?? "") + \(state.leftovers.filter(\.isSelected).count) leftovers to Trash?",
            isPresented: $state.showConfirm
        ) {
            Button("Uninstall", role: .destructive) { uninstall() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func loadApps() {
        state.isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let appsDir = URL(fileURLWithPath: "/Applications")
            var foundApps: [AppItem] = []
            if let urls = try? FileManager.default.contentsOfDirectory(at: appsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for url in urls where url.pathExtension == "app" {
                    if let bundle = Bundle(url: url), let bundleId = bundle.bundleIdentifier {
                        let name = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
                        let icon = NSWorkspace.shared.icon(forFile: url.path)
                        foundApps.append(AppItem(url: url, name: name, bundleId: bundleId, icon: icon))
                    }
                }
            }
            foundApps.sort { $0.name.lowercased() < $1.name.lowercased() }
            DispatchQueue.main.async {
                state.apps = foundApps
                state.isLoading = false
            }
        }
    }

    private func findLeftovers(for app: AppItem) {
        state.isFindingLeftovers = true
        let home = SafeCleaner.shared.homeDir
        let searchDirs = [
            "\(home)/Library/Application Support",
            "\(home)/Library/Caches",
            "\(home)/Library/Preferences",
            "\(home)/Library/Containers",
            "\(home)/Library/LaunchAgents",
            "\(home)/Library/Saved Application State",
        ]
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [LeftoverItem] = []
            for dir in searchDirs {
                let dirUrl = URL(fileURLWithPath: dir)
                guard let contents = try? FileManager.default.contentsOfDirectory(at: dirUrl, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
                for itemUrl in contents {
                    let kind = leftoverMatch(itemName: itemUrl.lastPathComponent, appName: app.name, appBundleId: app.bundleId)
                    guard kind.isMatch else { continue }
                    let size = SafeCleaner.shared.directorySize(url: itemUrl)
                    found.append(LeftoverItem(url: itemUrl, size: size, kind: kind, isSelected: kind.preselect))
                }
            }
            found.sort { $0.size > $1.size }
            DispatchQueue.main.async {
                // Guard against a selection change while we were scanning.
                guard state.selectedApp?.id == app.id else { return }
                state.leftovers = found
                state.isFindingLeftovers = false
            }
        }
    }

    private func uninstall() {
        guard let app = state.selectedApp else { return }
        state.errorMessage = nil
        state.isUninstalling = true

        let leftovers = state.leftovers.filter(\.isSelected).map(\.url)
        DispatchQueue.global(qos: .userInitiated).async {
            // Quit the app first — a running app can't be trashed ("permission
            // to access it"). NSRunningApplication matches by bundle id.
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleId)
            for r in running { r.terminate() }
            if !running.isEmpty { Thread.sleep(forTimeInterval: 1.2) }
            for r in NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleId) { r.forceTerminate() }

            // Try trashItem; if it still fails (e.g. app in /Applications the
            // user can't move), fall back to a single admin-privileged move.
            var appOK = (try? SafeCleaner.shared.trashItem(at: app.url)) != nil
            var usedAdmin = false
            if !appOK {
                usedAdmin = true
                let q = AdminShell.shellQuote
                // `~` in a root shell is /var/root — an app moved there would
                // vanish invisibly instead of landing in the USER's Trash.
                // Always move to the explicit user Trash path.
                let cmd = "mv \(q(app.url.path)) \(q("\(NSHomeDirectory())/.Trash/"))"
                appOK = AdminShell.runAsAdmin(cmd).ok
            }

            var failed: [String] = []
            if appOK {
                for url in leftovers {
                    if (try? SafeCleaner.shared.trashItem(at: url)) == nil { failed.append(url.lastPathComponent) }
                }
            }

            DispatchQueue.main.async {
                state.isUninstalling = false
                if appOK {
                    var detail = "\(app.name) moved to Trash"
                    if usedAdmin { detail += " (with administrator privileges)" }
                    state.beresDetail = detail
                    state.showBeres = true
                    if !failed.isEmpty {
                        state.errorMessage = "\(failed.count) leftover(s) couldn't be moved and are still on disk."
                    }
                    state.selectedApp = nil
                    state.leftovers = []
                    loadApps()
                } else {
                    state.errorMessage = "Couldn't remove \(app.name). It may be protected or still running. No data was removed."
                }
            }
        }
    }
}
