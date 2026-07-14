//
//  Theme.swift
//  Rebes
//
//  Design tokens and reusable components — Liquid Glass (macOS 26):
//  translucent material surfaces over a live blurred backdrop, adaptive to
//  light/dark, with the LQ teal brand accent.
//

import SwiftUI
import AppKit
import RebesCore

enum Theme {
    /// Root background is the glass backdrop itself — cards float over it.
    static let bg = Color.clear
    static let stroke = Color.primary.opacity(0.10)
    static let teal = Color(red: 124/255, green: 243/255, blue: 209/255)

    // Per-module accents (colorful, glass-friendly)
    static let accentScan = teal
    static let accentFiles = Color(red: 255/255, green: 168/255, blue: 60/255)
    static let accentUninstall = Color(red: 255/255, green: 96/255, blue: 112/255)
    static let accentMaintenance = Color(red: 96/255, green: 150/255, blue: 255/255)
    static let accentBattery = Color(red: 120/255, green: 205/255, blue: 90/255)
    static let accentFans = Color(red: 90/255, green: 180/255, blue: 255/255)
    static let accentStartup = Color(red: 200/255, green: 130/255, blue: 255/255)
    static let accentSettings = Color.secondary
}

/// Live translucent window backdrop (NSVisualEffectView) — the "glass" the
/// whole UI floats on. Adapts to light/dark automatically.
struct GlassBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    /// Rounds the effect itself via maskImage (behind-window blending ignores
    /// SwiftUI clip shapes — the mask is the only way to round true glass).
    var cornerRadius: CGFloat = 0

    /// Decoration must NEVER eat clicks: an NSViewRepresentable used as a
    /// SwiftUI .background can still land ABOVE SwiftUI-drawn controls in
    /// AppKit hit-testing (representables are real subviews of the hosting
    /// view). hitTest nil makes the glass purely visual.
    final class PassthroughEffectView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = PassthroughEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        if cornerRadius > 0 { v.maskImage = .roundedRectMask(cornerRadius: cornerRadius) }
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.maskImage = cornerRadius > 0 ? .roundedRectMask(cornerRadius: cornerRadius) : nil
    }
}

extension NSImage {
    /// Stretchable rounded-rect mask for NSVisualEffectView.maskImage.
    static func roundedRectMask(cornerRadius r: CGFloat) -> NSImage {
        let edge = r * 2 + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
}

/// A Control Center-style frosted panel: rounded translucent material that
/// refracts the backdrop, with a hairline top highlight and soft elevation.
struct LQCard<Content: View>: View {
    var padding: CGFloat = 16
    var cornerRadius: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.03), Color.clear],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 14, y: 7)
    }
}

struct AccentButtonStyle: ButtonStyle {
    var accent: Color = Theme.teal
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background {
                if prominent {
                    Capsule().fill(accent.gradient)
                        .shadow(color: accent.opacity(0.35), radius: 6, y: 2)
                } else {
                    Capsule().fill(.ultraThinMaterial)
                        .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
                }
            }
            .foregroundStyle(prominent ? Color.black : Color.primary)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Transient per-view state holder. This toolchain (CommandLineTools, no
/// macro plugins) can't expand SwiftUI's @State macro, so tiny view state
/// uses the app's ObservableObject/@Published pattern instead.
final class LocalState<Value>: ObservableObject {
    @Published var value: Value
    init(_ initial: Value) { value = initial }
}

/// Rolling numeric readout — digits tick over instead of jumping. Use for any
/// live number (CPU %, RAM %, rpm, °C, sizes): pass the formatted string plus
/// the raw value that drives the transition. Equivalent hand-rolled pattern:
/// `Text(str).monospacedDigit().contentTransition(.numericText(value: v))`
/// + `.animation(..., value: v)`.
struct AnimatedNumber: View {
    var text: String
    var value: Double            // raw value behind the string

    var body: some View {
        Text(text)
            .monospacedDigit()
            .contentTransition(.numericText(value: value))
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: value)
    }
}

/// Circular gauge used on the dashboard and menu bar panel.
/// On first appearance the ring sweeps from 0 to its value (one-shot spring);
/// afterwards it tracks live updates. Digits roll instead of jumping.
struct StatRing: View {
    var progress: Double         // 0...1
    var accent: Color = Theme.teal
    var lineWidth: CGFloat = 10
    var label: String
    var sublabel: String
    /// Raw value behind `label`, driving the digit-roll direction. Defaults to
    /// `progress` — pass it explicitly whenever the label shows a different
    /// quantity than the ring (e.g. free space over a used-fraction ring),
    /// otherwise the digits roll opposite to the displayed number.
    var labelValue: Double? = nil

    @StateObject private var sweep = LocalState(0.0)   // animated 0 → progress on appear
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.10), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(sweep.value, 1)))
                .stroke(
                    AngularGradient(colors: [accent.opacity(0.5), accent], center: .center),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                AnimatedNumber(text: label, value: labelValue ?? progress)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(sublabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            // One-shot reveal; Reduce Motion snaps straight to the value.
            if reduceMotion {
                sweep.value = progress
            } else {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    sweep.value = progress
                }
            }
        }
        .onChange(of: progress) { _, newValue in
            withAnimation(.easeInOut(duration: 0.6)) { sweep.value = newValue }
        }
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String
    var accent: Color = Theme.teal
    var icon: String = "sparkles"
    /// While true the header icon pulses — "scan life" for running scanners.
    var isBusy: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(accent.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(accent)
                    .symbolEffect(.pulse, isActive: isBusy)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - Rebes personality

/// Rebes' voice — short, warm, confident. Never corporate, never robotic.
/// Centralized so every module speaks with one voice.
enum RebesVoice {
    /// Time-of-day greeting for the dashboard header. `score` is the 0–100
    /// health score; a healthy Mac gets the signature line, otherwise the
    /// greeting nudges toward care. Name falls back gracefully when empty.
    static func greeting(name: String, score: Int) -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let timeOfDay: String
        switch hour {
        case 5..<12:  timeOfDay = "Good morning"
        case 12..<17: timeOfDay = "Good afternoon"
        case 17..<22: timeOfDay = "Good evening"
        default:      timeOfDay = "Up late"
        }
        let who = name.isEmpty ? "" : ", \(name)"
        let status = score >= 90
            ? "everything's in great shape 👍"
            : "your Mac could use a little care"
        return "\(timeOfDay)\(who) — \(status)"
    }

    /// Detail line for a completion moment (BeresStamp, empty states).
    /// Pass what happened ("2.1 GB cleaned"); falls back to a friendly line
    /// when there was nothing to do. No emoji — the thumbs-up symbol carries
    /// the motif.
    static func doneLine(detail: String) -> String {
        detail.isEmpty ? "Nothing to do here. Nice." : detail
    }

    /// First name of the current user, for greetings. Empty if unavailable.
    static var firstName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
    }
}

/// Completion stamp — the signature "Beres!" moment. A translucent glass chip
/// where the thumbs-up springs in (scale 0.4 → 1.08 → 1.0, rotate -8° → 0°)
/// over the label and a one-line detail. Present via `.beresStamp(...)`, which
/// adds the haptic and the ~1.8s auto-dismiss.
struct BeresStamp: View {
    var title: String = "Done!"
    var detail: String

    @StateObject private var landed = LocalState(false)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "hand.thumbsup.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Theme.teal)
                .scaleEffect(landed.value ? 1 : 0.4)
                .rotationEffect(.degrees(landed.value ? 0 : -8))
            Text(title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text(RebesVoice.doneLine(detail: detail))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.03), Color.clear],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 18, y: 9)
        .onAppear {
            if reduceMotion {
                landed.value = true   // fade only — the modifier's transition covers it
            } else {
                // Under-damped spring overshoots ~1.08 before settling at 1.
                withAnimation(.spring(response: 0.38, dampingFraction: 0.55)) {
                    landed.value = true
                }
            }
        }
    }
}

private struct BeresStampModifier: ViewModifier {
    @Binding var isPresented: Bool
    var detail: String
    /// Restartable identity for the auto-dismiss: bumped on every re-trigger
    /// while the stamp is already visible, so `.task(id:)` cancels the stale
    /// dismiss and the new message gets its full 1.8s.
    @StateObject private var generation = LocalState(0)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            if isPresented {
                BeresStamp(detail: detail)
                    .id(generation.value)   // replay the spring-in on re-trigger
                    .transition(reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.9)))
                    .task(id: generation.value) {
                        NSHapticFeedbackManager.defaultPerformer
                            .perform(.levelChange, performanceTime: .default)
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeOut(duration: 0.3)) { isPresented = false }
                    }
            }
        }
        .onChange(of: detail) { _, _ in
            // A second job finishing while the stamp is up swaps `detail`
            // (setting isPresented=true again is a no-op) — restart the timer.
            if isPresented { generation.value += 1 }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isPresented)
    }
}

extension View {
    /// Overlays a BeresStamp while `isPresented` is true: plays the haptic,
    /// auto-fades after ~1.8s (flipping the binding back). Set the binding to
    /// true when a job finishes — Smart Care, purge, Empty Trash, etc.
    func beresStamp(isPresented: Binding<Bool>, detail: String) -> some View {
        modifier(BeresStampModifier(isPresented: isPresented, detail: detail))
    }
}

/// Hover + cursor bookkeeping for HoverLift. `cursorPushed` is deliberately
/// not published — it only balances the NSCursor stack (every push must be
/// paired with a pop, even when the view disappears mid-hover) and never
/// drives layout.
private final class HoverLiftState: ObservableObject {
    @Published var hovering = false
    var cursorPushed = false
}

/// Hover treatment for interactive cards: gentle lift (scale 1.015), a touch
/// more shadow, module-accent stroke, and the pointing-hand cursor. With
/// Reduce Motion the lift is dropped — the stroke/shadow fade still signals
/// hover.
struct HoverLift: ViewModifier {
    var accent: Color = Theme.teal
    var cornerRadius: CGFloat = 18
    /// Lift amount — use 1.01 for compact surfaces (menu bar panel, settings).
    var scale: CGFloat = 1.015
    /// Show the pointing-hand cursor. Turn off for informational (non-click)
    /// cards that still get the hover glow.
    var pointer: Bool = true

    @StateObject private var state = HoverLiftState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let on = state.hovering
        content
            .scaleEffect(on && !reduceMotion ? scale : 1)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(accent.opacity(on ? 0.35 : 0), lineWidth: 1)
            )
            .shadow(color: .black.opacity(on ? 0.16 : 0), radius: on ? 4 : 0, y: 3)
            .animation(.spring(response: 0.30, dampingFraction: 0.8), value: on)
            .onHover { inside in
                state.hovering = inside
                guard pointer else { return }
                if inside {
                    if !state.cursorPushed {
                        NSCursor.pointingHand.push()
                        state.cursorPushed = true
                    }
                } else if state.cursorPushed {
                    NSCursor.pop()
                    state.cursorPushed = false
                }
            }
            .onDisappear {
                // The exit hover event is not delivered when the hovered view
                // is removed (card clicked away, panel closed, row deleted) —
                // pop only what we pushed so the cursor stack stays balanced.
                state.hovering = false
                if state.cursorPushed {
                    NSCursor.pop()
                    state.cursorPushed = false
                }
            }
    }
}

extension View {
    /// Apply to any clickable card/row. Match `cornerRadius` to the card's.
    func hoverLift(accent: Color = Theme.teal, cornerRadius: CGFloat = 18,
                   scale: CGFloat = 1.015, pointer: Bool = true) -> some View {
        modifier(HoverLift(accent: accent, cornerRadius: cornerRadius, scale: scale, pointer: pointer))
    }
}

/// Compact inline "Beres!" confirmation for tight spaces (the 340pt menu bar
/// panel): a capsule chip where the thumbs-up springs in next to the label.
/// Present/dismiss it from the call site (transition + timed removal) — this
/// view only handles the thumb landing.
struct BeresStampInline: View {
    var title: String = "Done!"
    var detail: String

    @StateObject private var landed = LocalState(false)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.thumbsup.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.teal)
                .scaleEffect(landed.value ? 1 : 0.4)
                .rotationEffect(.degrees(landed.value ? 0 : -8))
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text(RebesVoice.doneLine(detail: detail))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.teal.opacity(0.35), lineWidth: 1))
        .onAppear {
            if reduceMotion {
                landed.value = true
            } else {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.55)) {
                    landed.value = true
                }
            }
        }
    }
}

/// One-shot cascade entrance for result rows: each row fades in with a 6pt
/// rise, staggered 0.04s per index. With Reduce Motion the rise is dropped —
/// rows still fade in. Fires once per insertion (results appearing), never
/// re-runs on scroll or data refresh.
struct CascadeIn: ViewModifier {
    var index: Int

    @StateObject private var shown = LocalState(false)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown.value ? 1 : 0)
            .offset(y: shown.value || reduceMotion ? 0 : 6)
            .onAppear {
                guard !shown.value else { return }
                let delay = Double(index) * 0.04
                let anim: Animation = reduceMotion
                    ? .easeOut(duration: 0.2).delay(delay)
                    : .spring(response: 0.35, dampingFraction: 0.85).delay(delay)
                withAnimation(anim) { shown.value = true }
            }
    }
}

extension View {
    /// Staggered row entrance — pass the row's position in its list.
    func cascadeIn(_ index: Int) -> some View {
        modifier(CascadeIn(index: index))
    }
}

/// Menu bar panel entrance (directive §9): each section fades in with an 8pt
/// rise, staggered 0.05s per index. One-shot; with Reduce Motion the rise is
/// dropped and sections simply fade in.
struct PanelSectionIn: ViewModifier {
    var index: Int

    @StateObject private var shown = LocalState(false)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown.value ? 1 : 0)
            .offset(y: shown.value || reduceMotion ? 0 : 8)
            .onAppear {
                guard !shown.value else { return }
                let delay = Double(index) * 0.05
                let anim: Animation = reduceMotion
                    ? .easeOut(duration: 0.2).delay(delay)
                    : .spring(response: 0.35, dampingFraction: 0.85).delay(delay)
                withAnimation(anim) { shown.value = true }
            }
    }
}

extension View {
    /// Staggered section entrance for the menu bar panel — pass the section's
    /// top-to-bottom position.
    func panelSection(_ index: Int) -> some View {
        modifier(PanelSectionIn(index: index))
    }
}

// MARK: - Stacked stat groups (AlDente / Control Center style)

/// Grouped stack card: one rounded translucent container per group, rows
/// inside separated by hairline dividers inset past the icon column — the
/// AlDente / Control Center module look. Compose it with `StatRow`s (or any
/// row views); conditional rows (`if`) simply drop out of the stack and the
/// dividers follow. Used by the Battery stats card and the menu bar panel
/// groups.
struct StackCard<Content: View>: View {
    /// Optional small uppercase-style caption above the group.
    var title: String? = nil
    var cornerRadius: CGFloat = 12
    /// Leading inset for the hairline separators, aligning them with the row
    /// labels (icon column + row padding). Pass 0 for full-bleed dividers.
    var dividerInset: CGFloat = 42
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows.indices, id: \.self) { i in
                        rows[i]
                        if i != rows.indices.last {
                            Rectangle()
                                .fill(Color.primary.opacity(0.08))
                                .frame(height: 1)
                                .padding(.leading, dividerInset)
                        }
                    }
                }
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One row inside a `StackCard`: fixed-width icon column | label | trailing
/// value or control, at the panel's uniform ~34pt row height. Pass any
/// trailing view (a control, a `StatValue`, …) — or use the convenience init
/// for plain value rows.
struct StatRow<Trailing: View>: View {
    var icon: String
    var accent: Color = Theme.teal
    var label: String
    var minHeight: CGFloat = 34
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 20, alignment: .center)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(minHeight: minHeight)
    }
}

/// Standard trailing value for `StatRow` — rounded semibold digits. Pass the
/// raw value behind the string to get the rolling-digit treatment on live
/// numbers; omit it for static text ("Normal", a serial number).
struct StatValue: View {
    var text: String
    var raw: Double? = nil

    var body: some View {
        Group {
            if let raw {
                AnimatedNumber(text: text, value: raw)
            } else {
                Text(text).monospacedDigit()
            }
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(.primary)
    }
}

extension StatRow where Trailing == StatValue {
    /// Plain value row: icon | label | value. `raw` drives the digit roll on
    /// live values; leave nil for static text.
    init(icon: String, accent: Color = Theme.teal, label: String,
         value: String, raw: Double? = nil, minHeight: CGFloat = 34) {
        self.init(icon: icon, accent: accent, label: label, minHeight: minHeight) {
            StatValue(text: value, raw: raw)
        }
    }
}

extension Double {
    var bytesPerSecFormatted: String {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        return f.string(fromByteCount: Int64(self)) + "/s"
    }

    /// Fan rpm readout. Fans legitimately park at 0 rpm when the machine is
    /// cool — "0 rpm" reads as broken, so parked fans say "idle" instead.
    /// 1 Hz telemetry: render this as PLAIN `.monospacedDigit()` text, never
    /// AnimatedNumber (rolling-digit springs every tick read as lag).
    var rpmLabel: String {
        self <= 0 ? "idle" : "\(Int(self)) rpm"
    }
}

extension Notification.Name {
    static let rebesMenuBarSettingsChanged = Notification.Name("rebesMenuBarSettingsChanged")
    /// Posted with a SidebarItem to navigate the main window from the menu bar.
    static let rebesNavigate = Notification.Name("rebesNavigate")
}

/// Wrapping grid of selectable metric chips (menu bar settings).
struct FlowChips: View {
    let all: [MenuBarMetric]
    let selected: Set<MenuBarMetric>
    let toggle: (MenuBarMetric) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(all, id: \.self) { metric in
                let on = selected.contains(metric)
                Button { toggle(metric) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: metric.symbol).font(.system(size: 10))
                        Text(metric.label).font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background {
                        if on { Capsule().fill(Theme.teal.gradient) }
                        else { Capsule().fill(.ultraThinMaterial).overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1)) }
                    }
                    .foregroundStyle(on ? Color.black : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
