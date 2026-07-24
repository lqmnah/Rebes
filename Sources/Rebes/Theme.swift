//
//  Theme.swift
//  Rebes
//
//  Design tokens and reusable components — macOS native dark look with a
//  #34C759 green accent, solid cards, subtle hover lift. Font: -apple-system
//  stack (SF Pro native). Derived from the Rebes! HTML design system.
//

import SwiftUI
import AppKit
import RebesCore

/// Named colors matching the HTML design palette.
extension Color {
    static let rebesBg     = Color(red: 28/255, green: 28/255, blue: 30/255)   // #1C1C1E
    static let rebesSide   = Color(red: 32/255, green: 32/255, blue: 34/255)   // #202022
    static let rebesSurface  = Color(red: 44/255, green: 44/255, blue: 46/255)   // #2C2C2E
    static let rebesSurface2 = Color(red: 58/255, green: 58/255, blue: 60/255)   // #3A3A3C
    static let rebesLine   = Color.white.opacity(0.08)
    static let rebesLine2  = Color.white.opacity(0.14)

    // Base palette (for direct use)
    static let lqGreen     = Color(red:  52/255, green: 199/255, blue:  89/255)  // #34C759
    static let lqGreenDeep = Color(red:  45/255, green: 164/255, blue:  72/255)  // #2DA448
    static let lqOrange    = Color(red: 255/255, green: 159/255, blue:  10/255)  // #FF9F0A
    static let lqRed       = Color(red: 255/255, green:  69/255, blue:  58/255)  // #FF453A
    static let lqBlue      = Color(red:  10/255, green: 132/255, blue: 255/255)  // #0A84FF
    static let lqPurple    = Color(red: 191/255, green:  90/255, blue: 242/255)  // #BF5AF2
}

enum Theme {
    // Root background — solid dark, no glass.
    static let bg: Color = .rebesBg
    static let sidebarBg: Color = .rebesSide
    static let surface: Color = .rebesSurface
    static let surface2: Color = .rebesSurface2
    static let stroke: Color = .rebesLine
    static let stroke2: Color = .rebesLine2

    // Primary brand accent — green, not teal.
    static let teal: Color = .lqGreen    // legacy name kept for compatibility
    static let accent: Color = .lqGreen
    static let accentDeep: Color = .lqGreenDeep

    // Per-module accents (screen semantics, design palette).
    static let accentScan       = accent
    static let accentFiles      = Color.lqOrange
    static let accentUninstall  = Color.lqRed
    static let accentMaintenance = Color.lqBlue
    static let accentBattery    = accent
    static let accentFans       = Color.lqBlue
    static let accentStartup    = Color.lqPurple
    static let accentSettings   = Color.secondary
}

/// Now a plain solid-background view — the "glass" era is retired.
struct GlassBackdrop: View {
    var material: NSVisualEffectView.Material = .hudWindow
    var cornerRadius: CGFloat = 0

    var body: some View {
        Theme.bg.ignoresSafeArea()
    }
}

/// macOS-native style: solid dark surface, 1pt border, no shadow. Cards feel
/// grounded — elevation comes from hover lift, not permanent drop shadow.
struct LQCard<Content: View>: View {
    var padding: CGFloat = 20
    var cornerRadius: CGFloat = 11           // design uses 11–14px
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            )
    }
}

struct AccentButtonStyle: ButtonStyle {
    var accent: Color = Theme.accent
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        AccentButtonBody(accent: accent, prominent: prominent,
                         label: configuration.label, isPressed: configuration.isPressed)
    }
}

/// Buttons are a SYSTEM: hover (glow + slight lift) · press (scale .97,
/// ≤60ms ack) · release (spring back). Focus ring via :focus-visible.
private struct AccentButtonBody<Label: View>: View {
    var accent: Color
    var prominent: Bool
    let label: Label
    let isPressed: Bool

    @StateObject private var hovering = LocalState(false)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hoverScale: CGFloat { hovering.value && !reduceMotion ? 1.02 : 1 }

    var body: some View {
        label
            .font(.system(size: 13.5, weight: .semibold))
            .padding(.horizontal, 20)
            .padding(.vertical, 11)
            .background {
                if prominent {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(LinearGradient(colors: [accent.opacity(0.82), accent],
                                             startPoint: .top, endPoint: .bottom))
                        .shadow(color: accent.opacity(hovering.value ? 0.5 : 0.35),
                                radius: hovering.value ? 10 : 6, y: 2)
                } else {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Theme.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(hovering.value ? accent.opacity(0.5) : Theme.stroke2, lineWidth: 1)
                        )
                }
            }
            .foregroundStyle(prominent ? .white : .primary)
            .scaleEffect(isPressed ? 0.97 : hoverScale)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isPressed)
            .animation(.easeOut(duration: 0.15), value: hovering.value)
            .onHover { hovering.value = $0 }
    }
}

/// Transient per-view state holder.
final class LocalState<Value>: ObservableObject {
    @Published var value: Value
    init(_ initial: Value) { value = initial }
}

/// Rolling numeric readout — digits tick over instead of jumping.
struct AnimatedNumber: View {
    var text: String
    var value: Double

    var body: some View {
        Text(text)
            .monospacedDigit()
            .contentTransition(.numericText(value: value))
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: value)
    }
}

/// Circular gauge — one-shot spring reveal on appear, then ease-in-out tracking.
struct StatRing: View {
    var progress: Double         // 0...1
    var accent: Color = Theme.accent
    var lineWidth: CGFloat = 10
    var label: String
    var sublabel: String
    var labelValue: Double? = nil

    @StateObject private var sweep = LocalState(0.0)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: lineWidth)
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
    var accent: Color = Theme.accent
    var icon: String = "sparkles"
    var isBusy: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(accent.opacity(0.12))
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

enum RebesVoice {
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

    static func doneLine(detail: String) -> String {
        detail.isEmpty ? "Nothing to do here. Nice." : detail
    }

    static var firstName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
    }
}

/// Completion stamp — the signature "Done!" moment.
struct BeresStamp: View {
    var title: String = "Done!"
    var detail: String

    @StateObject private var landed = LocalState(false)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "hand.thumbsup.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Theme.accent)
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
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 18, y: 9)
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

private struct BeresStampModifier: ViewModifier {
    @Binding var isPresented: Bool
    var detail: String
    @StateObject private var generation = LocalState(0)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            if isPresented {
                BeresStamp(detail: detail)
                    .id(generation.value)
                    .transition(reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.9)))
                    .task(id: generation.value) {
                        NSHapticFeedbackManager.defaultPerformer
                            .perform(.levelChange, performanceTime: .default)
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeIn(duration: 0.2)) { isPresented = false }
                    }
            }
        }
        .onChange(of: detail) { _, _ in
            if isPresented { generation.value += 1 }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isPresented)
    }
}

extension View {
    func beresStamp(isPresented: Binding<Bool>, detail: String) -> some View {
        modifier(BeresStampModifier(isPresented: isPresented, detail: detail))
    }
}

// MARK: - HoverLift

private final class HoverLiftState: ObservableObject {
    @Published var hovering = false
    var cursorPushed = false
}

struct HoverLift: ViewModifier {
    var accent: Color = Theme.accent
    var cornerRadius: CGFloat = 11
    var scale: CGFloat = 1.015
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
                if inside, !state.cursorPushed {
                    NSCursor.pointingHand.push()
                    state.cursorPushed = true
                } else if !inside, state.cursorPushed {
                    NSCursor.pop()
                    state.cursorPushed = false
                }
            }
            .onDisappear {
                state.hovering = false
                if state.cursorPushed { NSCursor.pop(); state.cursorPushed = false }
            }
    }
}

extension View {
    func hoverLift(accent: Color = Theme.accent, cornerRadius: CGFloat = 11,
                   scale: CGFloat = 1.015, pointer: Bool = true) -> some View {
        modifier(HoverLift(accent: accent, cornerRadius: cornerRadius, scale: scale, pointer: pointer))
    }
}

// MARK: - BeresStampInline

struct BeresStampInline: View {
    var title: String = "Done!"
    var detail: String
    @StateObject private var landed = LocalState(false)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.thumbsup.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
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
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
        .onAppear {
            if reduceMotion { landed.value = true }
            else { withAnimation(.spring(response: 0.38, dampingFraction: 0.55)) { landed.value = true } }
        }
    }
}

// MARK: - Cascade entrance

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
    func cascadeIn(_ index: Int) -> some View { modifier(CascadeIn(index: index)) }
}

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
    func panelSection(_ index: Int) -> some View { modifier(PanelSectionIn(index: index)) }
}

// MARK: - Stacked stat groups

struct StackCard<Content: View>: View {
    var title: String? = nil
    var cornerRadius: CGFloat = 12
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
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StatRow<Trailing: View>: View {
    var icon: String
    var accent: Color = Theme.accent
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

struct StatValue: View {
    var text: String
    var raw: Double? = nil

    var body: some View {
        Group {
            if let raw { AnimatedNumber(text: text, value: raw) }
            else { Text(text).monospacedDigit() }
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(.primary)
    }
}

extension StatRow where Trailing == StatValue {
    init(icon: String, accent: Color = Theme.accent, label: String,
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

    var rpmLabel: String {
        self <= 0 ? "idle" : "\(Int(self)) rpm"
    }
}

extension Notification.Name {
    static let rebesMenuBarSettingsChanged = Notification.Name("rebesMenuBarSettingsChanged")
    static let rebesNavigate = Notification.Name("rebesNavigate")
}

// MARK: - Chips

private struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

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
                        if on { Capsule().fill(Theme.accent.gradient) }
                        else { Capsule().fill(Theme.surface).overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1)) }
                    }
                    .foregroundStyle(on ? .white : .primary)
                }
                .buttonStyle(ChipButtonStyle())
            }
        }
    }
}
