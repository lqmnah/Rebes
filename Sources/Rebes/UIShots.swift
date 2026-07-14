//
//  UIShots.swift
//  Rebes
//
//  Hidden test harness: `Rebes --ui-shots <dir>` renders the key screens to
//  PNGs (the app snapshots its OWN view hierarchy — no screen-recording or
//  accessibility permission needed) and exits. Used to visually verify UI
//  work in development; inert in normal runs.
//
//  Limitation: behind-window glass (NSVisualEffectView) does not composite
//  in cacheDisplay — the shots verify LAYOUT, spacing and strokes, not blur.
//

import SwiftUI
import AppKit
import RebesCore

@MainActor
enum UIShots {
    /// Call once at launch; returns without side effects unless the flag is present.
    static func runIfRequested() {
        panelProbeIfRequested()
        clickProbeIfRequested()
        guard let i = CommandLine.arguments.firstIndex(of: "--ui-shots"),
              CommandLine.arguments.count > i + 1 else { return }
        let dir = CommandLine.arguments[i + 1]
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        SystemMonitor.shared.start()
        // Let the monitor deliver a first sample so meters show real values.
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))

        // Menu bar panel at its natural (fitting) size — the "no gap" check —
        // and once inside an oversized window — the "top-pinned" check.
        shoot(AnyView(MenuBarPanel()), size: nil, name: "panel-fit", dir: dir)
        shoot(AnyView(MenuBarPanel()), size: NSSize(width: 380, height: 950), name: "panel-oversized-window", dir: dir)

        let boot = AppBootstrap()
        shoot(AnyView(ContentView().environmentObject(boot)),
              size: NSSize(width: 1100, height: 760), name: "main-dashboard", dir: dir)
        shoot(AnyView(KipasTemperatureView()), size: NSSize(width: 940, height: 780), name: "fans", dir: dir)
        shoot(AnyView(BateraiView()), size: NSSize(width: 940, height: 1400), name: "battery", dir: dir)
        shoot(AnyView(SettingsView()), size: NSSize(width: 940, height: 1000), name: "settings", dir: dir)

        exit(0)
    }

    /// `--panel-probe <dir>`: open the REAL status-bar panel programmatically,
    /// print the panel window's configuration + full view hierarchy (proves
    /// there is no system chrome behind the glass), snapshot it, exit.
    private static func panelProbeIfRequested() {
        guard let i = CommandLine.arguments.firstIndex(of: "--panel-probe"),
              CommandLine.arguments.count > i + 1 else { return }
        let dir = CommandLine.arguments[i + 1]
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        StatusBarController.shared.install()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        StatusBarController.shared.debugShowPanel()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))

        var report = ""
        if let panel = NSApp.windows.first(where: { $0 is FloatingPanel }) {
            report += "panel frame: \(panel.frame)\n"
            report += "isOpaque: \(panel.isOpaque)  backgroundColor: \(panel.backgroundColor == .clear ? "clear" : "NOT CLEAR")\n"
            report += "styleMask borderless: \(panel.styleMask.contains(.borderless))\n"
            func dump(_ v: NSView, depth: Int) {
                report += String(repeating: "  ", count: depth) + String(describing: type(of: v))
                    + " frame=\(v.frame.integral)\n"
                for s in v.subviews { dump(s, depth: depth + 1) }
            }
            if let cv = panel.contentView {
                report += "content fitting: \(cv.fittingSize)\n--- hierarchy ---\n"
                dump(cv, depth: 0)
                if let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) {
                    cv.cacheDisplay(in: cv.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: dir + "/panel-live.png"))
                }
            }
        } else {
            report = "PANEL NOT FOUND\n"
        }
        try? report.write(toFile: dir + "/panel-report.txt", atomically: true, encoding: .utf8)
        exit(0)
    }

    /// `--click-probe <reportPath>`: synthesize REAL mouse clicks (via
    /// window.sendEvent — no permissions needed) at the VISUAL center of the
    /// first sidebar rows and record which item actually got selected.
    /// Ground truth for the "click hits the row below" bug.
    private static func clickProbeIfRequested() {
        guard let i = CommandLine.arguments.firstIndex(of: "--click-probe"),
              CommandLine.arguments.count > i + 1 else { return }
        let path = CommandLine.arguments[i + 1]

        RunLoop.main.run(until: Date().addingTimeInterval(2.0))
        var report = ""
        defer {
            try? report.write(toFile: path, atomically: true, encoding: .utf8)
            exit(0)
        }
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain }),
              let contentView = window.contentView else {
            report = "NO MAIN WINDOW\n"
            return
        }
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let bridge = ClickProbeBridge.shared
        // Preferences land asynchronously — wait until the sidebar reported.
        var waited = 0.0
        while bridge.globalFrames.count < 12 && waited < 6.0 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            waited += 0.25
        }
        report += "window frame: \(window.frame), contentView bounds: \(contentView.bounds)\n"
        report += "row frames (.global): \(bridge.globalFrames.count) rows after \(waited)s\n"

        func click(atWindowPoint p: NSPoint) {
            let t = ProcessInfo.processInfo.systemUptime
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                              timestamp: t, windowNumber: window.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(e)
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }

        // Offset scan: click at the row's visual center displaced by dy and
        // record what got selected — measures the real hit-test displacement.
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let targets: [(SidebarItem, String)] = [(.smartCare, "smartCare"), (.smartScan, "smartScan"),
                                                (.battery, "battery")]
        for (item, name) in targets {
            guard let rect = bridge.globalFrames[item] else {
                report += "\(name): NO FRAME\n"; continue
            }
            report += "\(name) visual frame \(rect.integral):\n"
            for dy in [CGFloat(-76), -38, 0, 38, 76] {
                bridge.setSelection(.dashboard)
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                let visualY = rect.midY + dy
                let p = NSPoint(x: rect.midX, y: contentView.bounds.height - visualY)
                click(atWindowPoint: p)
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                let got = bridge.currentSelection().map(String.init(describing:)) ?? "nil"
                let marker = got == name ? "  <== matches" : ""
                report += "  dy=\(Int(dy)): clicked appkit \(p) → \(got)\(marker)\n"
            }
        }
    }

    private static func shoot(_ view: AnyView, size: NSSize?, name: String, dir: String) {
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1)   // stand-in for the glass
        if let size {
            window.setContentSize(size)
        } else {
            host.view.layoutSubtreeIfNeeded()
            let fit = host.view.fittingSize
            window.setContentSize(fit.width > 10 && fit.height > 10 ? fit : NSSize(width: 340, height: 800))
        }
        window.orderFront(nil)
        // Let onAppear / async loads / one-shot entrances settle.
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))

        guard let cv = window.contentView,
              let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) else { return }
        rep.size = cv.bounds.size
        cv.cacheDisplay(in: cv.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir + "/\(name).png"))
        }
        window.orderOut(nil)
    }
}
