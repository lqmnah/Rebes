import SwiftUI
import AppKit
import RebesCore

@main
struct RebesApp: App {
    @StateObject private var boot = AppBootstrap()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(boot)
                .task { boot.onLaunch() }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)   // transparent titlebar → glass shows through

        // Menu bar presence is a manual NSStatusItem + borderless clear panel
        // (StatusBarController) — SwiftUI's MenuBarExtra window carries square
        // system chrome behind the content that macOS 27 won't let us remove.
    }
}

/// Runs once per launch: re-arms a saved fan curve (so it survives reboots)
/// and surfaces first-run Full Access onboarding.
@MainActor
final class AppBootstrap: ObservableObject {
    @Published var showFullAccessOnboarding = false

    private var helperBinaryPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/RebesHelper").path
    }

    func onLaunch() {
        UIShots.runIfRequested()   // dev screenshot mode; inert normally

        let s = AppSettings.shared
        let daemon = HelperClient.shared

        DockIconPolicy.shared.install()
        StatusBarController.shared.install()

        // First run: show the permissions welcome once.
        if !s.didOfferFullAccess {
            showFullAccessOnboarding = true
        }
        PermissionsManager.shared.refresh()

        // Re-arm a saved fan curve after reboot / relaunch.
        if s.fanCurveEnabled, daemon.isDaemonInstalled() {
            let curve = s.fanCurve
            DispatchQueue.global(qos: .utility).async {
                _ = daemon.setFanCurve(enabled: true, curve: curve)
            }
        }
    }

    func enableFullAccess(completion: @escaping @Sendable (Bool, String) -> Void) {
        AppSettings.shared.didOfferFullAccess = true
        let helper = helperBinaryPath
        DispatchQueue.global(qos: .userInitiated).async {
            let r = HelperClient.shared.installDaemon(helperBinary: helper)
            DispatchQueue.main.async { completion(r.ok, r.output) }
        }
    }

    func dismissOnboarding() {
        AppSettings.shared.didOfferFullAccess = true
        showFullAccessOnboarding = false
    }
}

/// Keeps the Dock presence in sync with the "Show Dock Icon" setting.
/// With the setting off, Rebes lives in the menu bar (accessory policy) —
/// but flips to regular while the main window is open, because accessory
/// apps get no main menu (⌘C/⌘V/⌘Q would silently stop working).
@MainActor
final class DockIconPolicy {
    static let shared = DockIconPolicy()
    private var installed = false

    func install() {
        guard !installed else { return }
        installed = true
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in DockIconPolicy.shared.apply() }
        }
        // At willClose the window is still visible — re-evaluate a beat later.
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                DockIconPolicy.shared.apply()
            }
        }
        apply()
    }

    func apply() {
        let mainWindowOpen = NSApp.windows.contains { $0.canBecomeMain && $0.isVisible }
        let policy: NSApplication.ActivationPolicy =
            (AppSettings.shared.showDockIcon || mainWindowOpen) ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }
}
