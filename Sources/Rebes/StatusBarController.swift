//
//  StatusBarController.swift
//  Rebes
//
//  Manual NSStatusItem + borderless clear NSPanel replacing SwiftUI's
//  MenuBarExtra. The MenuBarExtra window ships its own square system chrome
//  that cannot reliably be blanked on macOS 27 — with our own panel the
//  window has NO other layer: the rounded GlassBackdrop box in MenuBarPanel
//  is the entire visible surface.
//

import SwiftUI
import AppKit
import RebesCore

/// Borderless panel that can still take key status (⌘Q row, toggles).
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class StatusBarController: NSObject {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private var panel: FloatingPanel?
    private var hosting: NSHostingView<AnyView>?
    private var labelTimer: Timer?
    private var globalClickMonitor: Any?
    private var localMonitor: Any?

    private override init() { super.init() }

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        statusItem = item

        SystemMonitor.shared.start()
        updateLabel()
        // 2s cadence is plenty for the tiny label; the panel has its own
        // live monitor while open.
        labelTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in StatusBarController.shared.updateLabel() }
        }
        NotificationCenter.default.addObserver(
            forName: .rebesMenuBarSettingsChanged, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in StatusBarController.shared.updateLabel() }
        }
    }

    private func updateLabel() {
        let monitor = SystemMonitor.shared
        let s = monitor.snapshot
        func value(for metric: MenuBarMetric) -> String {
            switch metric {
            case .cpu: return String(format: "%.0f%%", s.cpuUsagePercent)
            case .memory: return String(format: "%.0f%%", s.memUsedPercent)
            case .cpuTemp: return monitor.cpuTemp.map { String(format: "%.0f°", $0) } ?? "—"
            case .fanRPM: return monitor.fans.first.map { "\(Int($0.actual))" } ?? "—"
            case .battery: return monitor.battery.map { "\($0.currentChargePercent)%" } ?? "—"
            case .none: return ""
            }
        }
        statusItem?.button?.image = MenuBarRenderer.render(
            metrics: AppSettings.shared.menuBarMetrics,
            showIcon: AppSettings.shared.menuBarShowIcon,
            battery: monitor.battery.map { ($0.currentChargePercent, $0.isCharging) },
            icon: { $0.symbol }, value: value(for:)
        )
    }

    // MARK: - panel

    @objc private func togglePanel() {
        if panel?.isVisible == true { hidePanel() } else { showPanel() }
    }

    private func showPanel() {
        let panel = ensurePanel()

        // Size to the content's exact ideal (sections are user-configurable).
        guard let hosting else { return }
        hosting.rootView = AnyView(MenuBarPanel())
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        if size.width < 100 || size.height < 100 { size = NSSize(width: 368, height: 600) }
        panel.setContentSize(size)

        // Position: under the status item, right-aligned to its button,
        // clamped to the screen edge.
        if let button = statusItem?.button, let bWindow = button.window {
            let bFrame = bWindow.convertToScreen(button.convert(button.bounds, to: nil))
            var x = bFrame.midX - size.width / 2
            var y = bFrame.minY - size.height - 6
            if let screen = bWindow.screen ?? NSScreen.main {
                x = min(max(x, screen.visibleFrame.minX + 8),
                        screen.visibleFrame.maxX - size.width - 8)
                y = max(y, screen.visibleFrame.minY + 8)
            }
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        panel.makeKey()
        statusItem?.button?.highlight(true)
        installDismissMonitors()
    }

    /// Dev-only entry for the --panel-probe harness.
    func debugShowPanel() { showPanel() }

    func hidePanel() {
        panel?.orderOut(nil)
        statusItem?.button?.highlight(false)
        removeDismissMonitors()
    }

    private func ensurePanel() -> FloatingPanel {
        if let panel { return panel }
        let host = NSHostingView(rootView: AnyView(MenuBarPanel()))
        let p = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 368, height: 600),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.contentView = host
        p.isOpaque = false
        p.backgroundColor = .clear      // the WHOLE point: no window surface at all
        p.hasShadow = true              // shadow wraps the rounded glass shape
        p.level = .popUpMenu
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        p.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        hosting = host
        panel = p
        return p
    }

    // MARK: - dismissal (click outside / Esc / other apps)

    private func installDismissMonitors() {
        removeDismissMonitors()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { _ in
            Task { @MainActor in StatusBarController.shared.hidePanel() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.hidePanel(); return nil }   // Esc
                return event
            }
            // Click in one of OUR windows: dismiss only if it's not the panel
            // and not the status item button.
            if event.window !== panel,
               event.window !== statusItem?.button?.window {
                self.hidePanel()
            }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let m = globalClickMonitor { NSEvent.removeMonitor(m); globalClickMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }
}
