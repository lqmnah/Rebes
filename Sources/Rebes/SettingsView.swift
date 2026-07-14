//
//  SettingsView.swift
//  Rebes
//
//  App settings: one-time "Full Access" (installs the root helper daemon
//  so fan/battery controls never ask for a password again), plus about info.
//

import SwiftUI
import AppKit
import RebesCore

class SettingsState: ObservableObject {
    @Published var daemonInstalled = HelperClient.shared.isDaemonInstalled()
    @Published var daemonAlive = false
    @Published var busy = false
    @Published var message: String?

    // Menu bar (persisted via AppSettings)
    @Published var menuMetrics: Set<MenuBarMetric> = Set(AppSettings.shared.menuBarMetrics)
    @Published var showMenuIcon = AppSettings.shared.menuBarShowIcon

    // Dock
    @Published var showDockIcon = AppSettings.shared.showDockIcon

    // Menu bar panel sections
    @Published var panelHealth = AppSettings.shared.menuBarPanelShowHealth
    @Published var panelStatCards = AppSettings.shared.menuBarPanelShowStatCards
    @Published var panelNetwork = AppSettings.shared.menuBarPanelShowNetwork
    @Published var panelFanControl = AppSettings.shared.menuBarPanelShowFanControl
    @Published var panelQuickActions = AppSettings.shared.menuBarPanelShowQuickActions
}

struct SettingsView: View {
    @StateObject private var state = SettingsState()

    var helperBinaryPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/RebesHelper").path
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(
                    title: "Settings",
                    subtitle: "Permissions, menu bar & app info",
                    accent: Theme.accentSettings,
                    icon: "gearshape"
                )

                Text("Permissions").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                PermissionsList()

                if state.daemonInstalled {
                    LQCard(padding: 12) {
                        HStack {
                            Text("Full Access is installed. Remove it to revoke the privileged helper.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Disable & Remove") { uninstall() }
                                .buttonStyle(AccentButtonStyle(accent: Theme.accentUninstall, prominent: false))
                                .disabled(state.busy)
                        }
                    }
                    .hoverLift(accent: Theme.accentUninstall, scale: 1.01, pointer: false)
                }
                if let msg = state.message {
                    Text(msg).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                }

                dockCard
                menuBarCard
                panelCard

                LQCard {
                    HStack(alignment: .top, spacing: 12) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable().interpolation(.high)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("About").font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                            Text("Rebes! 1.0 — open-source all-in-one Mac utility: cleaner, battery, fans & system monitor.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Text("Free & open source — credit Rebes!, resale not permitted.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Text("SMC layer adapted from exelban/stats (MIT).")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
                .hoverLift(accent: Theme.teal, scale: 1.01, pointer: false)
            }
            .padding(24)
        }
        .background(Theme.bg)
        .onAppear(perform: refresh)
    }

    // MARK: - Dock settings

    private var dockCard: some View {
        LQCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Dock", systemImage: "dock.rectangle")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                Toggle("Show Dock Icon", isOn: Binding(
                    get: { state.showDockIcon },
                    set: { on in
                        state.showDockIcon = on
                        AppSettings.shared.showDockIcon = on
                        DockIconPolicy.shared.apply()
                    }
                ))
                .toggleStyle(.switch).tint(Theme.teal).font(.system(size: 12))
                Text("Off = clean Dock: Rebes lives in the menu bar. The Dock icon appears only while this window is open (so menus & shortcuts keep working) and disappears when you close it.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .hoverLift(accent: Theme.teal, scale: 1.01, pointer: false)
    }

    // MARK: - Menu bar settings

    private var menuBarCard: some View {
        LQCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Menu Bar Display", systemImage: "menubar.rectangle")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                Text("Choose what shows in the menu bar. Multiple allowed.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)

                FlowChips(all: MenuBarMetric.allCases.filter { $0 != .none },
                          selected: state.menuMetrics) { metric in
                    if state.menuMetrics.contains(metric) { state.menuMetrics.remove(metric) }
                    else { state.menuMetrics.insert(metric) }
                    if state.menuMetrics.isEmpty { state.menuMetrics = [.cpu] }
                    persistMenuBar()
                }

                Toggle("Show 👍 icon in menu bar", isOn: Binding(
                    get: { state.showMenuIcon },
                    set: { state.showMenuIcon = $0; persistMenuBar() }
                ))
                .toggleStyle(.switch).tint(Theme.teal).font(.system(size: 12))

                Text("Preview: \(previewText)")
                    .font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.teal)
            }
        }
        .hoverLift(accent: Theme.teal, scale: 1.01, pointer: false)
    }

    // MARK: - Menu bar panel sections

    private var panelCard: some View {
        LQCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Menu Bar Panel", systemImage: "rectangle.grid.1x2")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                Text("Choose what the menu bar dropdown shows.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)

                panelToggle("Mac Health score", \.panelHealth) { AppSettings.shared.menuBarPanelShowHealth = $0 }
                panelToggle("Storage / Memory / Battery / CPU cards", \.panelStatCards) { AppSettings.shared.menuBarPanelShowStatCards = $0 }
                panelToggle("Network & fan speed row", \.panelNetwork) { AppSettings.shared.menuBarPanelShowNetwork = $0 }
                panelToggle("Fan quick control", \.panelFanControl) { AppSettings.shared.menuBarPanelShowFanControl = $0 }
                panelToggle("Quick actions (Speed Up, Trash, Lock…)", \.panelQuickActions) { AppSettings.shared.menuBarPanelShowQuickActions = $0 }
            }
        }
        .hoverLift(accent: Theme.teal, scale: 1.01, pointer: false)
    }

    private func panelToggle(_ title: String,
                             _ keyPath: ReferenceWritableKeyPath<SettingsState, Bool>,
                             persist: @escaping (Bool) -> Void) -> some View {
        Toggle(title, isOn: Binding(
            get: { state[keyPath: keyPath] },
            set: { on in
                state[keyPath: keyPath] = on
                persist(on)
                NotificationCenter.default.post(name: .rebesMenuBarSettingsChanged, object: nil)
            }
        ))
        .toggleStyle(.switch).tint(Theme.teal).font(.system(size: 12))
        .controlSize(.small)
    }

    private var previewText: String {
        let parts = MenuBarMetric.allCases.filter { state.menuMetrics.contains($0) }.map { m -> String in
            switch m {
            case .cpu: return "18%"; case .memory: return "61%"; case .cpuTemp: return "52°"
            case .fanRPM: return "2300"; case .battery: return "87%"; case .none: return ""
            }
        }
        return (state.showMenuIcon ? "👍 " : "") + parts.joined(separator: " · ")
    }

    private func persistMenuBar() {
        let ordered = MenuBarMetric.allCases.filter { state.menuMetrics.contains($0) }
        AppSettings.shared.menuBarMetrics = ordered
        AppSettings.shared.menuBarShowIcon = state.showMenuIcon
        NotificationCenter.default.post(name: .rebesMenuBarSettingsChanged, object: nil)
    }

    private func refresh() {
        state.daemonInstalled = HelperClient.shared.isDaemonInstalled()
        HelperClient.shared.pingDaemon { alive in
            DispatchQueue.main.async { state.daemonAlive = alive }
        }
    }

    private func install() {
        state.busy = true
        state.message = nil
        let helper = helperBinaryPath
        DispatchQueue.global(qos: .userInitiated).async {
            let result = HelperClient.shared.installDaemon(helperBinary: helper)
            DispatchQueue.main.async {
                state.busy = false
                state.message = result.ok ? "Full access enabled ✓" : "Failed: \(result.output)"
                refresh()
            }
        }
    }

    private func uninstall() {
        state.busy = true
        state.message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = HelperClient.shared.uninstallDaemon()
            DispatchQueue.main.async {
                state.busy = false
                state.message = result.ok ? "Daemon removed." : "Failed: \(result.output)"
                refresh()
            }
        }
    }
}
