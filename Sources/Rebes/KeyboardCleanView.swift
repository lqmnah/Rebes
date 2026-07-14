//
//  KeyboardCleanView.swift
//  Rebes
//
//  Keyboard cleaning mode (One Menu-style): blocks all keyboard input via a
//  CGEventTap so you can wipe the keys, then release with a mouse click on the
//  big button (mouse stays active). Requires Accessibility permission.
//

import SwiftUI
import AppKit
import ApplicationServices

final class KeyboardBlocker: ObservableObject, @unchecked Sendable {
    static let shared = KeyboardBlocker()

    @Published var isBlocking = false
    @Published var needsPermission = false

    fileprivate var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func trusted() -> Bool { AXIsProcessTrusted() }

    func requestPermission() {
        let key = "AXTrustedCheckOptionPrompt"
        let opts = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    func start() {
        guard trusted() else { needsPermission = true; requestPermission(); return }
        let mask = (1 << CGEventType.keyDown.rawValue) |
                   (1 << CGEventType.keyUp.rawValue) |
                   (1 << CGEventType.flagsChanged.rawValue)
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
        isBlocking = true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        isBlocking = false
    }
}

struct KeyboardCleanView: View {
    @ObservedObject private var blocker = KeyboardBlocker.shared
    // "Beres!" when the user releases the lock after cleaning.
    @StateObject private var beres = LocalState(false)

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
                            Text("Keyboard LOCKED")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.primary)
                            Text("All keys are disabled. Wipe the keyboard now. Click the button below (with mouse/trackpad) to re-enable.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
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
                            Text("While active, all key presses are blocked (mouse still works) until you click release. Requires Accessibility permission.")
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
