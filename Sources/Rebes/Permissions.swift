//
//  Permissions.swift
//  Rebes
//
//  Tracks the access Rebes needs and whether each is granted, for the
//  first-run onboarding and the Settings status list (red = missing,
//  green = granted).
//

import SwiftUI
import AppKit
import ApplicationServices
import IOKit.hid
import RebesCore

enum PermissionKind: CaseIterable, Identifiable {
    case fullAccess     // root helper daemon (fan/battery control)
    case accessibility  // CGEventTap for Keyboard Cleaning (fallback lock)
    case inputMonitoring // HID seizure for Keyboard Cleaning (TRUE full lock)
    case automation     // Apple Events → Finder (Empty Trash)
    case fullDisk       // read protected caches for a complete clean

    var id: Self { self }

    var title: String {
        switch self {
        case .fullAccess: return "Full Access (privileged helper)"
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        case .automation: return "Automation (Finder)"
        case .fullDisk: return "Full Disk Access"
        }
    }
    var detail: String {
        switch self {
        case .fullAccess: return "Control fans and the battery charge limit without a password each time."
        case .accessibility: return "Lock the keyboard during Keyboard Cleaning (basic lock)."
        case .inputMonitoring: return "FULL keyboard lock during cleaning — media & Globe keys also die."
        case .automation: return "Empty the Trash on your behalf via Finder."
        case .fullDisk: return "Scan every cache and log for a complete cleanup."
        }
    }
    var icon: String {
        switch self {
        case .fullAccess: return "checkmark.shield.fill"
        case .accessibility: return "accessibility"
        case .inputMonitoring: return "keyboard.fill"
        case .automation: return "app.connected.to.app.below.fill"
        case .fullDisk: return "externaldrive.fill"
        }
    }
    /// Whether the app can function acceptably without it.
    var required: Bool {
        switch self {
        case .fullAccess: return true
        case .accessibility, .inputMonitoring, .automation, .fullDisk: return false
        }
    }
}

@MainActor
final class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()
    @Published var granted: [PermissionKind: Bool] = [:]
    private init() {}

    func refresh() {
        granted[.fullAccess] = HelperClient.shared.isDaemonInstalled()
        // Query fresh each time (prompt:false) so a just-granted change is seen.
        let axOpts = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        granted[.accessibility] = AXIsProcessTrustedWithOptions(axOpts)
        granted[.inputMonitoring] = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        granted[.fullDisk] = Self.hasFullDiskAccess()
        granted[.automation] = Self.hasAutomation()
        // Confirm the daemon actually answers, not just that files exist.
        HelperClient.shared.pingDaemon { alive in
            Task { @MainActor in if !alive { self.granted[.fullAccess] = false } }
        }
    }

    func isGranted(_ k: PermissionKind) -> Bool { granted[k] ?? false }

    // MARK: - checks

    /// Full Disk Access: actually attempt to READ the system TCC database.
    /// It exists on every Mac (root:wheel) but is only readable with FDA —
    /// access(R_OK) reflects POSIX bits not TCC, so we must open it for real.
    static func hasFullDiskAccess() -> Bool {
        let path = "/Library/Application Support/com.apple.TCC/TCC.db"
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        // A successful read of even 1 byte means TCC granted FDA.
        if let data = try? fh.read(upToCount: 1) { return data != nil }
        return false
    }

    /// Automation to Finder: AEDeterminePermissionToAutomateTarget without prompting.
    static func hasAutomation() -> Bool {
        var addr = AEAddressDesc()
        let bundleID = "com.apple.finder"
        let data = bundleID.data(using: .utf8)!
        _ = data.withUnsafeBytes { raw in
            AECreateDesc(typeApplicationBundleID, raw.baseAddress, data.count, &addr)
        }
        defer { AEDisposeDesc(&addr) }
        let status = AEDeterminePermissionToAutomateTarget(&addr, typeWildCard, typeWildCard, false)
        return status == noErr
    }

    // MARK: - request / open settings

    func request(_ k: PermissionKind, helperBinary: String, completion: @escaping @Sendable (Bool) -> Void) {
        switch k {
        case .fullAccess:
            DispatchQueue.global(qos: .userInitiated).async {
                let r = HelperClient.shared.installDaemon(helperBinary: helperBinary)
                DispatchQueue.main.async { self.refresh(); completion(r.ok) }
            }
        case .accessibility:
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            completion(false)
        case .inputMonitoring:
            // Triggers the system prompt when undetermined; user lands in
            // System Settings → Privacy & Security → Input Monitoring.
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            Self.openSettings("Privacy_ListenEvent")
            completion(false)
        case .automation:
            // Triggering a benign Finder event surfaces the system prompt.
            DispatchQueue.global(qos: .userInitiated).async {
                _ = AdminShell.runOsascript("tell application \"Finder\" to count windows")
                DispatchQueue.main.async { self.refresh(); completion(self.isGranted(.automation)) }
            }
        case .fullDisk:
            Self.openSettings("Privacy_AllFiles")
            completion(false)
        }
    }

    static func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    func openSettingsPane(for k: PermissionKind) {
        switch k {
        case .accessibility: Self.openSettings("Privacy_Accessibility")
        case .inputMonitoring: Self.openSettings("Privacy_ListenEvent")
        case .automation: Self.openSettings("Privacy_Automation")
        case .fullDisk: Self.openSettings("Privacy_AllFiles")
        case .fullAccess: break
        }
    }
}
