//
//  KeyboardCleanView.swift
//  Rebes
//
//  Keyboard cleaning mode, two layers:
//  • FULL LOCK — seizes every keyboard-class HID device (IOHIDManager with
//    kIOHIDOptionsTypeSeizeDevice). A seized device delivers events to
//    NOTHING else: not apps, not system shortcuts, not the brightness HUD,
//    not the Globe key. IOKit auto-releases on quit/crash, so the keyboard
//    can never be left dead. Needs Input Monitoring permission.
//  • PARTIAL LOCK (fallback) — CGEventTap swallowing keyDown/keyUp/
//    flagsChanged/systemDefined. Media & Globe keys may still respond.
//  Mouse/trackpad always stays alive for the unlock button, and a 10-minute
//  auto-unlock timer covers the weirdest window states.
//  Spec: docs/superpowers/specs/2026-07-23-keyboard-full-lock-design.md
//

import SwiftUI
import AppKit
import ApplicationServices
import IOKit.hid

/// True "keyboard off" via exclusive HID device seizure.
final class KeyboardSeizer {
    private var manager: IOHIDManager?

    /// Seize keyboards, keypads and consumer-control collections (media and
    /// brightness keys live in the latter) — built-in AND external alike.
    /// Returns false when Input Monitoring is missing or the open fails.
    func start() -> Bool {
        guard manager == nil else { return true }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        let matches: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keypad],
            [kIOHIDDeviceUsagePageKey: kHIDPage_Consumer,      kIOHIDDeviceUsageKey: kHIDUsage_Csmr_ConsumerControl],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(m, matches as CFArray)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        guard IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            return false
        }
        manager = m
        return true
    }

    func stop() {
        guard let m = manager else { return }
        manager = nil
        IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}

final class KeyboardBlocker: ObservableObject, @unchecked Sendable {
    static let shared = KeyboardBlocker()

    enum LockMode {
        case seized   // FULL: every key dead, incl. media & Globe
        case tap      // PARTIAL: letters/shortcuts dead; media/Globe may leak
    }

    @Published var isBlocking = false
    @Published var needsPermission = false
    @Published private(set) var mode: LockMode?
    @Published private(set) var autoUnlockSeconds = 0

    fileprivate var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let seizer = KeyboardSeizer()
    private var autoUnlockTimer: Timer?
    private var countdownTimer: Timer?

    func trusted() -> Bool { AXIsProcessTrusted() }

    func requestPermission() {
        let key = "AXTrustedCheckOptionPrompt"
        let opts = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    func start() {
        // Primary: HID seizure — the true full lock.
        if seizer.start() {
            mode = .seized
            isBlocking = true
            armAutoUnlock()
            return
        }
        // Fallback: event tap (partial). Requires Accessibility.
        guard trusted() else { needsPermission = true; requestPermission(); return }
        let mask = (1 << CGEventType.keyDown.rawValue) |
                   (1 << CGEventType.keyUp.rawValue) |
                   (1 << CGEventType.flagsChanged.rawValue) |
                   (1 << 14)   // kCGEventSystemDefined (media keys; not exported in Swift's CGEventType)
        // Swallow key events. If the system disables the tap (timeout / heavy
        // input), re-enable the stored tap so the keyboard can never silently
        // unlock while the user still thinks it is blocked.
        let callback: CGEventTapCallBack = { _, type, _, userInfo in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let userInfo {
                    let blocker = Unmanaged<KeyboardBlocker>.fromOpaque(userInfo).takeUnretainedValue()
                    if let tap = blocker.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                }
                return nil
            }
            return nil   // block the key event
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { needsPermission = true; return }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        mode = .tap
        isBlocking = true
        armAutoUnlock()
    }

    func stop() {
        seizer.stop()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        autoUnlockTimer?.invalidate(); autoUnlockTimer = nil
        countdownTimer?.invalidate(); countdownTimer = nil
        autoUnlockSeconds = 0
        mode = nil
        isBlocking = false
    }

    /// Safety net: even in a broken window state the lock self-heals.
    private func armAutoUnlock() {
        autoUnlockSeconds = 600
        autoUnlockTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.autoUnlockSeconds > 0 else { return }
                self.autoUnlockSeconds -= 1
            }
        }
    }
}

struct KeyboardCleanView: View {
    @ObservedObject private var blocker = KeyboardBlocker.shared
    // "Beres!" when the user releases the lock after cleaning.
    @StateObject private var beres = LocalState(false)

    private var countdownText: String {
        String(format: "%d:%02d", blocker.autoUnlockSeconds / 60, blocker.autoUnlockSeconds % 60)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(
                    title: "Keyboard Cleaning",
                    subtitle: "Temporarily lock the keyboard so you can wipe it without triggering keys",
                    accent: Theme.accentMaintenance,
                    icon: "keyboard"
                )

                if blocker.isBlocking {
                    LQCard(padding: 30) {
                        VStack(spacing: 16) {
                            Image(systemName: "keyboard.badge.ellipsis")
                                .font(.system(size: 52))
                                .foregroundStyle(Theme.accentUninstall)
                                .symbolEffect(.pulse, options: .repeating)

                            if blocker.mode == .seized {
                                Text("Keyboard FULLY LOCKED")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(.primary)
                                Text("Every key is dead — letters, shortcuts, media and Globe keys. Wipe away. Click the button below (mouse/trackpad) to re-enable.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            } else {
                                Text("Keyboard LOCKED — PARTIAL")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(.primary)
                                Text("Letters and shortcuts are blocked, but media/Globe keys may still respond. Grant Input Monitoring for a full lock.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                Button("Open Input Monitoring Settings") {
                                    PermissionsManager.openSettings("Privacy_ListenEvent")
                                }
                                .buttonStyle(AccentButtonStyle(accent: Theme.accentFiles))
                            }

                            Text("Note: no software can disable the Touch ID/power button — avoid pressing it. Auto-unlocks in \(countdownText).")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)

                            Button("Re-enable Keyboard") {
                                blocker.stop()
                                beres.value = true
                            }
                            .buttonStyle(AccentButtonStyle(accent: Theme.accentBattery))
                            .controlSize(.large)
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    LQCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Locks every keyboard (built-in and external) until you click release — mouse stays active. Full lock (media & Globe keys included) uses Input Monitoring; without it a basic lock still blocks letters and shortcuts via Accessibility.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            if blocker.needsPermission {
                                Label("Grant Accessibility in System Settings → Privacy & Security → Accessibility, then try again.", systemImage: "exclamationmark.shield")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.accentFiles)
                            }
                            Button("Lock Keyboard for Cleaning") { blocker.start() }
                                .buttonStyle(AccentButtonStyle(accent: Theme.accentMaintenance))
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(Theme.bg)
        .beresStamp(
            isPresented: Binding(get: { beres.value }, set: { beres.value = $0 }),
            detail: "Keyboard unlocked — spotless"
        )
        .onDisappear { blocker.stop() }
    }
}
