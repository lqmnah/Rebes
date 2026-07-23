//
//  MenuBarPanel.swift
//  Rebes
//
//  Menu bar presence (MenuMeters / One Menu inspired): live CPU label
//  in the bar, dropdown panel with system meters, temps, fans, battery,
//  and quick actions (keep-awake, hidden files, empty trash, lock).
//

import SwiftUI
import AppKit
import RebesCore

// The status-bar label itself is owned by StatusBarController (manual
// NSStatusItem); it feeds MenuBarRenderer below.

/// Renders the menu bar label (SF Symbol icons + values) into a single template
/// NSImage that the status bar tints for light/dark automatically.
///
/// The battery metric is special-cased to match the system status item:
/// a custom-drawn native-style battery glyph (rounded body outline, inner
/// fill proportional to charge, tip nub, charging bolt knocked out of the
/// fill) rendered TEXT-FIRST ("60% [battery]") like macOS.
enum MenuBarRenderer {
    static func render(metrics: [MenuBarMetric], showIcon: Bool,
                       battery: (percent: Int, charging: Bool)?,
                       icon: (MenuBarMetric) -> String,
                       value: (MenuBarMetric) -> String) -> NSImage {
        let height: CGFloat = 18
        let iconSize: CGFloat = 15   // SF glyphs; the battery glyph draws at its natural size
        let iconTextGap: CGFloat = 2
        let segmentGap: CGFloat = 8
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let symConfig = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .semibold)

        func glyph(_ name: String) -> NSImage? {
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(symConfig)
        }

        struct Seg {
            let icon: NSImage?
            let text: String
            /// macOS battery convention: value text before the glyph.
            var textFirst = false
            /// Draw the icon at its natural pixel size (custom battery glyph)
            /// instead of scaling to `iconSize`.
            var naturalIconSize = false
        }
        var segs: [Seg] = []
        if showIcon {
            segs.append(Seg(icon: glyph("hand.thumbsup.fill"), text: ""))
        }
        for m in metrics {
            if m == .battery, let b = battery {
                segs.append(Seg(icon: batteryGlyph(percent: b.percent, charging: b.charging),
                                text: value(m), textFirst: true, naturalIconSize: true))
            } else {
                segs.append(Seg(icon: glyph(icon(m)), text: value(m)))
            }
        }
        if segs.isEmpty {
            segs.append(Seg(icon: glyph("hand.thumbsup.fill"), text: ""))
        }

        // Measure — each icon keeps its natural aspect ratio (battery is wide).
        var totalW: CGFloat = 0
        var iconSizes: [NSSize] = []
        for (i, seg) in segs.enumerated() {
            var isz = NSSize.zero
            if let ic = seg.icon {
                if seg.naturalIconSize {
                    isz = ic.size
                } else {
                    let iw = ic.size.height > 0 ? iconSize * (ic.size.width / ic.size.height) : iconSize
                    isz = NSSize(width: iw, height: iconSize)
                }
            }
            iconSizes.append(isz)
            let tw = seg.text.isEmpty ? 0 : (seg.text as NSString).size(withAttributes: attrs).width + (isz.width > 0 ? iconTextGap : 0)
            totalW += isz.width + tw
            if i < segs.count - 1 { totalW += segmentGap }
        }
        totalW = max(totalW, 16)

        let image = NSImage(size: NSSize(width: ceil(totalW) + 2, height: height))
        image.lockFocus()
        var x: CGFloat = 1
        for (i, seg) in segs.enumerated() {
            func drawIcon() {
                guard let icon = seg.icon else { return }
                let isz = iconSizes[i]
                // SF glyphs sit up a hair (baseline compensation); the custom
                // battery glyph centers exactly.
                let iy = (height - isz.height) / 2 - (seg.naturalIconSize ? 0 : 1)
                icon.draw(in: NSRect(x: x, y: iy, width: isz.width, height: isz.height))
                x += isz.width
            }
            func drawText() {
                guard !seg.text.isEmpty else { return }
                let ty = (height - font.ascender + font.descender) / 2
                (seg.text as NSString).draw(at: NSPoint(x: x, y: ty), withAttributes: attrs)
                x += (seg.text as NSString).size(withAttributes: attrs).width
            }
            if seg.textFirst {
                drawText()
                if seg.icon != nil && !seg.text.isEmpty { x += iconTextGap }
                drawIcon()
            } else {
                drawIcon()
                if seg.icon != nil && !seg.text.isEmpty { x += iconTextGap }
                drawText()
            }
            x += segmentGap
        }
        image.unlockFocus()
        image.isTemplate = true   // status bar tints it for light/dark
        return image
    }

    /// Native-style battery glyph whose fill follows the charge level, using
    /// the DISCRETE SF battery symbols (battery.0/25/50/75/100percent).
    ///
    /// Why discrete, not variableValue: `battery.100percent` + `variableValue`
    /// does NOT render a proportional fill once the symbol is baked into a
    /// bitmap for the status bar — it always draws FULL (verified), so the
    /// icon never reflected the real level. The discrete symbols are the same
    /// artwork macOS itself shows and always render the correct fill.
    ///
    /// Charging: a small `bolt.fill` is placed just LEFT of the battery
    /// ("⚡▯") — always cleanly readable at menu-bar size (only
    /// `battery.100percent.bolt` ships as a bolt variant, and knocking the
    /// bolt out of the fill reads as a jagged notch, not a lightning bolt).
    static func batteryGlyph(percent: Int, charging: Bool) -> NSImage? {
        let level: String
        switch max(0, min(percent, 100)) {
        case ..<13: level = "battery.0percent"
        case ..<38: level = "battery.25percent"
        case ..<63: level = "battery.50percent"
        case ..<88: level = "battery.75percent"
        default:    level = "battery.100percent"
        }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let base = NSImage(systemSymbolName: level, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        base.isTemplate = true
        guard charging,
              let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)) else {
            return base
        }
        let gap: CGFloat = 2
        let out = NSImage(size: NSSize(width: bolt.size.width + gap + base.size.width,
                                       height: base.size.height))
        out.lockFocus()
        bolt.draw(in: NSRect(x: 0, y: (base.size.height - bolt.size.height) / 2,
                             width: bolt.size.width, height: bolt.size.height))
        base.draw(in: NSRect(x: bolt.size.width + gap, y: 0,
                             width: base.size.width, height: base.size.height))
        out.unlockFocus()
        out.isTemplate = true
        return out
    }
}

class MenuBarPanelState: ObservableObject {
    // NEVER initialize this by running a subprocess: @StateObject init happens
    // during a SwiftUI layout pass, and Process.waitUntilExit re-enters the
    // run loop → AttributeGraph re-entrancy → SIGABRT. Loaded async in onAppear.
    @Published var hiddenFilesOn = false
    @Published var speedUpBusy = false
    @Published var speedUpNote: String?
    /// Shows the compact "Beres!" chip after a successful Speed Up.
    @Published var speedUpDone = false
    /// Generation token for the chip's hide timer — bumped per Speed Up run so
    /// a stale timer from an earlier run can't hide a newer chip early.
    var speedUpGen = 0
    /// Health ring sweep (0…1) — animated 0 → score on appear (one-shot).
    @Published var ringSweep: Double = 0

    // Which sections show (editable in Settings). Reading UserDefaults is
    // cheap and safe here — unlike subprocesses.
    @Published var showHealth = AppSettings.shared.menuBarPanelShowHealth
    @Published var showStatCards = AppSettings.shared.menuBarPanelShowStatCards
    @Published var showNetwork = AppSettings.shared.menuBarPanelShowNetwork
    @Published var showFanControl = AppSettings.shared.menuBarPanelShowFanControl
    @Published var showQuickActions = AppSettings.shared.menuBarPanelShowQuickActions

    func reloadSections() {
        let s = AppSettings.shared
        showHealth = s.menuBarPanelShowHealth
        showStatCards = s.menuBarPanelShowStatCards
        showNetwork = s.menuBarPanelShowNetwork
        showFanControl = s.menuBarPanelShowFanControl
        showQuickActions = s.menuBarPanelShowQuickActions
    }
}

struct MenuBarPanel: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var caffeinate = CaffeinateManager.shared
    @ObservedObject private var keyboard = KeyboardBlocker.shared
    @StateObject private var state = MenuBarPanelState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let health = monitor.health()
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: 20, height: 20)
                Text("Rebes!").font(.system(size: 13, weight: .bold))
                Spacer()
                Button("Open App") { openApp(.dashboard) }
                .buttonStyle(AccentButtonStyle(prominent: false))
            }
            .padding(.bottom, 2)   // header gets a touch more breathing room
            .panelSection(0)

            // Health hero (CleanMyMac-style) — radius aligned with the stacks
            if state.showHealth {
            LQCard(padding: 12, cornerRadius: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().stroke(Color.primary.opacity(0.1), lineWidth: 5).frame(width: 46, height: 46)
                        Circle().trim(from: 0, to: max(0.001, min(state.ringSweep, 1)))
                            .stroke(health.color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90)).frame(width: 46, height: 46)
                            .animation(.easeInOut(duration: 0.4), value: health.score)
                        AnimatedNumber(text: "\(health.score)", value: Double(health.score))
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Mac Health").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(health.label).font(.system(size: 16, weight: .bold)).foregroundStyle(health.color)
                    }
                    Spacer()
                }
            }
            .panelSection(1)
            }

            // 2x2 stat cards (non-lazy so the panel window can measure its
            // exact height — LazyVGrid reports estimated sizes).
            if state.showStatCards {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    statCard("internaldrive", "Storage", monitor.snapshot.diskFreeBytes.formattedSize, "free",
                             raw: Double(monitor.snapshot.diskFreeBytes),
                             monitor.snapshot.diskUsedPercent / 100, Theme.teal) { openApp(.smartScan) }
                    memoryCard
                }
                HStack(alignment: .top, spacing: 8) {
                    if let b = monitor.battery {
                        statCard("battery.75", "Battery", "\(b.currentChargePercent)%",
                                 String(format: "%.1f W · health %d%%", abs(b.watts), b.healthPercent),
                                 raw: Double(b.currentChargePercent),
                                 Double(b.currentChargePercent)/100, Theme.accentBattery) { openApp(.battery) }
                    } else {
                        statCard("battery.75", "Battery", "—", "", raw: nil, 0, Theme.accentBattery) { openApp(.battery) }
                    }
                    // 1 Hz value → raw nil renders plain monospaced digits.
                    statCard("cpu", "CPU", String(format: "%.0f%%", monitor.snapshot.cpuUsagePercent),
                             monitor.cpuTemp.map { String(format: "%.0f°C", $0) } ?? "",
                             raw: nil,
                             monitor.snapshot.cpuUsagePercent / 100, Theme.accentFans) { openApp(.fans) }
                }
                if let note = state.speedUpNote {
                    Text(note).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .panelSection(2)
            }

            if state.showNetwork {
            // 1 Hz row: plain monospaced digits; parked fans read "idle".
            HStack(spacing: 14) {
                Label(monitor.snapshot.netDownBytesPerSec.bytesPerSecFormatted, systemImage: "arrow.down")
                Label(monitor.snapshot.netUpBytesPerSec.bytesPerSecFormatted, systemImage: "arrow.up")
                Spacer()
                if let fan = monitor.fans.first {
                    Label(fan.actual.rpmLabel, systemImage: "fanblades")
                }
            }
            .monospacedDigit()
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .panelSection(3)
            }

            // Fan quick control — grouped stack card (Control Center style)
            if state.showFanControl && !monitor.fans.isEmpty {
                FanQuickControl(fans: monitor.fans)
                    .panelSection(4)
            }

            // Toggles + actions — grouped stack cards, hairline-divided rows
            if state.showQuickActions {
            VStack(alignment: .leading, spacing: 10) {
                StackCard {
                    StatRow(icon: "keyboard", accent: Theme.accentMaintenance, label: "Keyboard Cleaning") {
                        miniSwitch(isOn: Binding(
                            get: { keyboard.isBlocking },
                            set: { on in on ? keyboard.start() : keyboard.stop() }),
                                   accent: Theme.accentMaintenance)
                    }
                    StatRow(icon: "cup.and.saucer.fill", accent: Theme.accentFiles, label: "Keep Awake") {
                        miniSwitch(isOn: Binding(get: { caffeinate.isActive }, set: { _ in caffeinate.toggle() }),
                                   accent: Theme.accentFiles)
                    }
                    StatRow(icon: "eye", accent: Theme.accentStartup, label: "Show Hidden Files") {
                        miniSwitch(isOn: Binding(
                            get: { state.hiddenFilesOn },
                            set: { newVal in
                                state.hiddenFilesOn = newVal
                                MenuBarActions.setHiddenFiles(visible: newVal)
                            }),
                                   accent: Theme.accentStartup)
                    }
                }
                if keyboard.needsPermission {
                    Text("Grant Accessibility permission, then try again.")
                        .font(.system(size: 10)).foregroundStyle(Theme.accentFiles)
                        .padding(.leading, 4)
                }
                StackCard {
                    actionRow("trash", Theme.accentFiles, "Empty Trash…") {
                        // Confirm via a NATIVE NSAlert, not a SwiftUI
                        // confirmationDialog: a modal presented inside the
                        // borderless non-activating panel can't take key, and
                        // the panel's click-dismiss monitors swallow the
                        // dialog's button clicks — the whole thing froze.
                        MenuBarActions.confirmAndEmptyTrash()
                    }
                    actionRow("lock.fill", Theme.accentMaintenance, "Lock Screen") {
                        StatusBarController.shared.hidePanel()
                        MenuBarActions.lockScreen()
                    }
                }
            }
            .panelSection(5)
            }

            Divider()

            QuitRow()
        }
        .padding(14)
        .frame(width: 340)
        // Exact ideal size: StatusBarController sizes its borderless clear
        // panel to this content's fittingSize — the rounded glass box below
        // IS the entire visible window (nothing exists behind it).
        .fixedSize(horizontal: false, vertical: true)
        .background(GlassBackdrop(material: .hudWindow, cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.25), Color.white.opacity(0.04), Color.clear],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
        )
        .onAppear {
            monitor.start()
            state.reloadSections()
            // One-shot health ring reveal: sweep 0 → score (directive §5).
            let target = Double(monitor.health().score) / 100
            if reduceMotion {
                state.ringSweep = target
            } else {
                state.ringSweep = 0
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    state.ringSweep = target
                }
            }
            DispatchQueue.global(qos: .utility).async {
                let visible = MenuBarActions.hiddenFilesVisible()
                DispatchQueue.main.async { state.hiddenFilesOn = visible }
            }
        }
        .onChange(of: health.score) { _, score in
            withAnimation(.easeInOut(duration: 0.6)) { state.ringSweep = Double(score) / 100 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .rebesMenuBarSettingsChanged)) { _ in
            state.reloadSections()
        }
        .onDisappear { monitor.stop() }
    }

    /// Purge RAM from the menu bar — silent (daemon) when Full Access is on,
    /// one admin prompt otherwise.
    private func speedUp() {
        state.speedUpGen += 1
        let gen = state.speedUpGen
        state.speedUpBusy = true
        state.speedUpNote = nil
        state.speedUpDone = false
        DispatchQueue.global(qos: .userInitiated).async {
            let r = HelperClient.shared.purgeRAM()
            DispatchQueue.main.async {
                state.speedUpBusy = false
                if r.ok {
                    // Compact "Beres!" moment — haptic + chip, auto-fades.
                    NSHapticFeedbackManager.defaultPerformer
                        .perform(.levelChange, performanceTime: .default)
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        state.speedUpDone = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        // Only the timer from the latest run may hide the chip.
                        guard gen == state.speedUpGen else { return }
                        withAnimation(.easeOut(duration: 0.3)) { state.speedUpDone = false }
                    }
                } else {
                    state.speedUpNote = "Failed: \(r.message)"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        if !state.speedUpBusy { state.speedUpNote = nil }
                    }
                }
            }
        }
    }

    private func openApp(_ item: SidebarItem) {
        StatusBarController.shared.hidePanel()
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.canBecomeMain }) {
            w.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: .rebesNavigate, object: item)
        } else {
            // Main window was closed. The panel lives outside the SwiftUI
            // scene graph (@Environment openWindow is a no-op here), so ask
            // the App scene to recreate the window the same way a Dock-icon
            // click does — a reopen Apple event to ourselves — and navigate
            // once the fresh ContentView is up. The destination travels via
            // pendingNavigate (consumed on ContentView.onAppear); the delayed
            // post is belt-and-suspenders for an already-alive view.
            MenuBarActions.pendingNavigate = item
            MenuBarActions.sendReopenEvent()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                NotificationCenter.default.post(name: .rebesNavigate, object: item)
            }
        }
    }

    /// The Memory stat card with the compact purge control in its top-right
    /// corner (its own Button — tapping it purges without navigating) and the
    /// "Beres!" chip overlaid on success.
    private var memoryCard: some View {
        statCard("memorychip", "Memory", String(format: "%.0f%%", monitor.snapshot.memUsedPercent), "used",
                 raw: nil,   // 1 Hz value → plain monospaced digits
                 monitor.snapshot.memUsedPercent / 100, Theme.accentStartup,
                 accessory: {
                     Button {
                         speedUp()
                     } label: {
                         Group {
                             if state.speedUpBusy {
                                 ProgressView().controlSize(.mini)
                             } else {
                                 Image(systemName: "bolt.fill")
                                     .font(.system(size: 10, weight: .semibold))
                                     .foregroundStyle(Theme.accentStartup)
                             }
                         }
                         .frame(width: 16, height: 14)
                         .contentShape(Rectangle())
                     }
                     .buttonStyle(.plain)
                     .disabled(state.speedUpBusy)
                     .help("Speed Up (Purge RAM)")
                 }) { openApp(.maintenance) }
        .overlay {
            if state.speedUpDone {
                BeresStampInline(title: "Speed Up!", detail: "RAM purged")
                    .fixedSize()
                    .transition(reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.9)))
            }
        }
    }

    private func statCard(_ icon: String, _ title: String, _ value: String, _ detail: String,
                          raw: Double?,
                          _ progress: Double, _ accent: Color, action: @escaping () -> Void) -> some View {
        statCard(icon, title, value, detail, raw: raw, progress, accent,
                 accessory: { EmptyView() }, action)
    }

    /// Small variant of the dashboard metric card: icon + title row, rounded
    /// numeric, caption, thin progress — 12 radius, 12 padding. `raw` drives
    /// the digit roll on slow/event-driven values (battery %, storage);
    /// pass nil for 1 Hz telemetry (CPU %, memory %) so it renders as plain
    /// monospaced digits (the 1 Hz rule — see KipasSuhu).
    private func statCard<Accessory: View>(
        _ icon: String, _ title: String, _ value: String, _ detail: String,
        raw: Double?,
        _ progress: Double, _ accent: Color,
        @ViewBuilder accessory: () -> Accessory,
        _ action: @escaping () -> Void
    ) -> some View {
        // The card navigates via an onTapGesture (NOT a Button) so a nested
        // accessory Button — e.g. the Memory card's Speed Up bolt — reliably
        // consumes its own tap without also firing the card's navigation
        // (nested SwiftUI Buttons have version-dependent hit-test quirks).
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(accent)
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                accessory()
            }
            Group {
                if let raw {
                    AnimatedNumber(text: value, value: raw)
                } else {
                    Text(value).monospacedDigit()
                }
            }
            .font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(.primary)
            Text(detail).monospacedDigit().font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            ProgressView(value: max(0, min(progress, 1))).tint(accent).controlSize(.mini)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { action() }
        .hoverLift(accent: accent, cornerRadius: 12, scale: 1.01)
    }

    /// Label-less mini switch for `StatRow` trailing slots.
    private func miniSwitch(isOn: Binding<Bool>, accent: Color) -> some View {
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(accent)
    }

    /// Full-width clickable row for the actions stack card.
    private func actionRow(_ icon: String, _ accent: Color, _ title: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            StatRow(icon: icon, accent: accent, label: title) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Footer "Quit Rebes!" row: quiet secondary style, full-width hover wash
/// (9-radius row pill), ⌘Q shortcut while the panel is open.
private struct QuitRow: View {
    @StateObject private var hovering = LocalState(false)

    var body: some View {
        Button { NSApp.terminate(nil) } label: {
            HStack {
                Text("Quit Rebes!")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("⌘Q")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(hovering.value ? 0.06 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("q")   // ⌘ is the default modifier
        .onHover { hovering.value = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering.value)
    }
}

enum MenuBarActions {
    /// Sidebar destination pending delivery to a not-yet-created ContentView.
    /// Set before sendReopenEvent(); consumed by ContentView.onAppear. Fixes
    /// the race where a fixed 350ms delayed notification fired into the void
    /// on a cold start and the user landed on Dashboard instead of the pane
    /// they clicked.
    @MainActor static var pendingNavigate: SidebarItem?

    /// Ask our own App scene to recreate the main WindowGroup window — the
    /// same reopen Apple event a Dock-icon click delivers. Needed because the
    /// menu bar panel lives outside the SwiftUI scene graph.
    static func sendReopenEvent() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(0x61657674),   // 'aevt'
            eventID: AEEventID(0x72617070),         // 'rapp' (reopen)
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        _ = try? event.sendEvent(options: [.noReply], timeout: 1)
    }

    static func hiddenFilesVisible() -> Bool {
        let out = run("/usr/bin/defaults", ["read", "com.apple.finder", "AppleShowAllFiles"])
        return out.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "1"
            || out.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
    }

    static func setHiddenFiles(visible: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = run("/usr/bin/defaults", ["write", "com.apple.finder", "AppleShowAllFiles", visible ? "true" : "false"])
            _ = run("/usr/bin/killall", ["Finder"])
        }
    }

    static func lockScreen() {
        // Off the main thread: the pmset fallback spawns a subprocess, and
        // nothing here needs to touch the UI.
        DispatchQueue.global(qos: .userInitiated).async {
            // login.framework's SACLockScreenImmediate locks without needing
            // Accessibility (synthetic ⌃⌘Q would be silently dropped without it).
            typealias LockFn = @convention(c) () -> Int32
            if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW),
               let sym = dlsym(handle, "SACLockScreenImmediate") {
                let lock = unsafeBitCast(sym, to: LockFn.self)
                _ = lock()
                dlclose(handle)
                return
            }
            // Fallback: pmset (locks if "require password immediately" is set).
            _ = run("/usr/bin/pmset", ["displaysleepnow"])
        }
    }

    /// Hide the panel, activate the app, then confirm with a native NSAlert
    /// (app-modal — works regardless of the panel's key state) before emptying.
    @MainActor
    static func confirmAndEmptyTrash() {
        StatusBarController.shared.hidePanel()
        NSApp.activate(ignoringOtherApps: true)
        // Next runloop tick so the panel is fully gone before the modal.
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Empty Trash?"
            alert.informativeText = "All Trash contents are deleted permanently and cannot be undone."
            alert.addButton(withTitle: "Empty Permanently")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                emptyTrash { _ in }
            }
        }
    }

    static func emptyTrash(completion: @escaping @Sendable (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = AdminShell.runOsascript("tell application \"Finder\" to empty trash")
            SafeCleaner.shared.logAction(result.ok ? "Emptied Trash (menu bar)" : "Empty Trash failed: \(result.output)")
            completion(result.ok)
        }
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        // Discard stderr rather than piping it: an unread stderr pipe that
        // fills its 64KB buffer would deadlock the child (and this reader).
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Compact per-fan control for the menu bar: Auto or Max, driven through the
/// helper (daemon if installed, else one admin prompt).
class FanQuickState: ObservableObject {
    @Published var busy = false
    @Published var note: String?
}

struct FanQuickControl: View {
    let fans: [FanReading]
    @StateObject private var fq = FanQuickState()

    private var helperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/RebesHelper").path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            StackCard(title: "Fans") {
                ForEach(fans) { fan in
                    StatRow(icon: "fanblades", accent: Theme.accentFans, label: "Fan \(fan.id + 1)") {
                        HStack(spacing: 8) {
                            // 1 Hz telemetry: plain monospaced digits — and
                            // parked fans read "idle", not "0 rpm".
                            Text(fan.actual.rpmLabel)
                                .monospacedDigit()
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(fan.mode == 1 ? Theme.accentUninstall : .secondary)
                            modePair(fan)
                        }
                    }
                }
            }
            if fq.busy || fq.note != nil {
                HStack(spacing: 6) {
                    if fq.busy { ProgressView().controlSize(.mini) }
                    if let note = fq.note {
                        Text(note).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 4)
            }
        }
    }

    /// Compact Auto/Max segmented-style pair — Auto highlighted while the fan
    /// is in automatic mode, Max while forced.
    private func modePair(_ fan: FanReading) -> some View {
        HStack(spacing: 2) {
            modeButton("Auto", selected: fan.mode != 1) { run(.fanAuto(fan.id)) }
            modeButton("Max", selected: fan.mode == 1) { run(.fanSet(fan.id, Float(fan.max))) }
        }
        .padding(2)
        // Radius scale: buttons/chips are capsules — no stray radii.
        .background(Color.primary.opacity(0.06), in: Capsule())
        .disabled(fq.busy)
    }

    private func modeButton(_ title: String, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background {
                    if selected {
                        Capsule().fill(Theme.accentFans.opacity(0.9))
                    }
                }
                .foregroundStyle(selected ? Color.black : Color.secondary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func run(_ action: HelperClient.Action) {
        fq.busy = true; fq.note = nil
        let helper = helperPath
        DispatchQueue.global(qos: .userInitiated).async {
            let r = HelperClient.shared.perform(action, fallbackHelperBinary: helper)
            DispatchQueue.main.async {
                fq.busy = false
                if !r.ok { fq.note = "Failed: \(r.message)" }
            }
        }
    }
}
