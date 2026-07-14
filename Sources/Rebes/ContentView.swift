import SwiftUI
import AppKit
import RebesCore

enum SidebarItem: Hashable {
    case dashboard
    case smartCare
    case smartScan
    case largeFiles
    case spaceLens
    case uninstaller
    case maintenance
    case startupItems
    case keyboardClean
    case battery
    case fans
    case settings
}

class AppState: ObservableObject {
    @Published var selection: SidebarItem? = .dashboard
}

/// One hover tracker for the WHOLE sidebar. Per-row `.onHover` on macOS
/// drops enter/exit events on fast pointer movement (stale highlights,
/// "missed" rows) and the spacing gaps between rows kill tracking entirely.
/// Instead, every row reports its frame and a single `.onContinuousHover`
/// on the sidebar resolves the hovered row geometrically — one source of
/// truth, no tracking areas to miss.
@MainActor
final class SidebarHoverModel: ObservableObject {
    @Published var hovered: SidebarItem?
    var frames: [SidebarItem: CGRect] = [:]

    func pointerMoved(to location: CGPoint) {
        // Slightly outset each frame so the 2pt inter-row gaps never read
        // as "no row" (which is what made the highlight flicker/slip).
        let hit = frames.first { $0.value.insetBy(dx: 0, dy: -1.5).contains(location) }?.key
        if hovered != hit { hovered = hit }
    }

    func pointerLeft() {
        if hovered != nil { hovered = nil }
    }
}

/// Reports each sidebar row's frame (in the sidebar coordinate space).
struct SidebarRowFrameKey: PreferenceKey {
    static let defaultValue: [SidebarItem: CGRect] = [:]
    static func reduce(value: inout [SidebarItem: CGRect], nextValue: () -> [SidebarItem: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Same rows in the window (.global) space — feeds the click-probe harness
/// and lets us verify hit-testing against real synthesized events.
struct SidebarRowGlobalFrameKey: PreferenceKey {
    static let defaultValue: [SidebarItem: CGRect] = [:]
    static func reduce(value: inout [SidebarItem: CGRect], nextValue: () -> [SidebarItem: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Debug bridge for the `--click-probe` harness: live row frames (window
/// space) + the live selection. Negligible cost in normal runs.
@MainActor
final class ClickProbeBridge {
    static let shared = ClickProbeBridge()
    var globalFrames: [SidebarItem: CGRect] = [:]
    var currentSelection: () -> SidebarItem? = { nil }
    var setSelection: (SidebarItem?) -> Void = { _ in }
}

/// One custom sidebar row: icon chip + label, our own selection pill and a
/// quiet hover wash. Built on Button (NOT List selection) so macOS never
/// paints its accent-blue highlight underneath the pill.
private struct SidebarRowButton: View {
    let item: SidebarItem
    let title: String
    let icon: String
    let accent: Color
    @ObservedObject var appState: AppState
    @ObservedObject var hoverModel: SidebarHoverModel
    let pillNamespace: Namespace.ID

    @StateObject private var bounce = LocalState(0)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isSelected: Bool { appState.selection == item }
    private var isHovered: Bool { hoverModel.hovered == item }

    var body: some View {
        Button {
            let anim: Animation = reduceMotion
                ? .easeInOut(duration: 0.15)
                : .spring(response: 0.35, dampingFraction: 0.8)
            withAnimation(anim) { appState.selection = item }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(accent.opacity(isSelected ? 0.24 : 0.16))
                        .frame(width: 26, height: 26)
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent)
                        .symbolEffect(.bounce, value: bounce.value)
                }
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .background {
                if isSelected {
                    let pill = RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(accent.opacity(0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(accent.opacity(0.28), lineWidth: 1)
                        )
                    if reduceMotion {
                        pill.transition(.opacity)
                    } else {
                        pill.matchedGeometryEffect(id: "sidebar-selection-pill", in: pillNamespace)
                    }
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                }
            }
        }
        .buttonStyle(.plain)
        .background(GeometryReader { g in
            Color.clear
                .preference(key: SidebarRowFrameKey.self,
                            value: [item: g.frame(in: .named("rebes-sidebar"))])
                .preference(key: SidebarRowGlobalFrameKey.self,
                            value: [item: g.frame(in: .global)])
        })
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onChange(of: isSelected) { _, nowSelected in
            if nowSelected && !reduceMotion { bounce.value += 1 }
        }
    }
}

struct ContentView: View {
    @StateObject private var appState = AppState()
    @StateObject private var hoverModel = SidebarHoverModel()
    @EnvironmentObject private var boot: AppBootstrap
    @Namespace private var sidebarPill

    var body: some View {
        NavigationSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sidebarHeader
                        .padding(.bottom, 8)

                    row(.dashboard, "Dashboard", "gauge.with.dots.needle.67percent", Theme.teal)
                    row(.smartCare, "Smart Care", "wand.and.stars", Theme.teal)
                    sectionLabel("Cleaning")
                    row(.smartScan, "Smart Scan", "sparkles", Theme.accentScan)
                    row(.largeFiles, "Large Files", "doc.text.magnifyingglass", Theme.accentFiles)
                    row(.spaceLens, "Space Lens", "chart.pie", Theme.accentFiles)
                    row(.uninstaller, "Uninstaller", "xmark.app.fill", Theme.accentUninstall)
                    sectionLabel("Device")
                    row(.battery, "Battery", "battery.100percent", Theme.accentBattery)
                    row(.fans, "Fans & Temps", "fanblades", Theme.accentFans)
                    sectionLabel("System")
                    row(.maintenance, "Maintenance", "wrench.and.screwdriver", Theme.accentMaintenance)
                    row(.startupItems, "Startup Items", "bolt.badge.clock", Theme.accentStartup)
                    row(.keyboardClean, "Keyboard Clean", "keyboard", Theme.accentMaintenance)
                    row(.settings, "Settings", "gearshape", Theme.accentSettings)
                }
                .padding(.horizontal, 10)
                // Manual titlebar clearance: the safe-area path is buggy here
                // (see ignoresSafeArea below) — plain padding shifts layout
                // AND hit-testing together.
                .padding(.top, 48)
                .padding(.bottom, 12)
            }
            // macOS bug (measured with the --click-probe harness): with
            // .hiddenTitleBar, the sidebar column's safe-area inset shifts the
            // RENDERED content down 38pt but NOT the hit-test coordinates —
            // every click landed one row off. Opting out of the safe area
            // makes visuals and hit-testing share the same space again.
            .ignoresSafeArea(.container, edges: .top)
            .coordinateSpace(name: "rebes-sidebar")
            .onPreferenceChange(SidebarRowFrameKey.self) { frames in
                Task { @MainActor in hoverModel.frames = frames }
            }
            .onPreferenceChange(SidebarRowGlobalFrameKey.self) { frames in
                Task { @MainActor in ClickProbeBridge.shared.globalFrames = frames }
            }
            .onAppear {
                ClickProbeBridge.shared.currentSelection = { [weak appState] in appState?.selection }
                ClickProbeBridge.shared.setSelection = { [weak appState] in appState?.selection = $0 }
            }
            .onContinuousHover(coordinateSpace: .named("rebes-sidebar")) { phase in
                switch phase {
                case .active(let location): hoverModel.pointerMoved(to: location)
                case .ended: hoverModel.pointerLeft()
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            Group {
                switch appState.selection {
                case .dashboard, .none: DashboardView(selection: $appState.selection)
                case .smartCare: SmartCareView()
                case .smartScan: SmartScanView()
                case .largeFiles: LargeFilesView()
                case .spaceLens: SpaceLensView()
                case .uninstaller: UninstallerView()
                case .maintenance: MaintenanceView()
                case .startupItems: StartupItemsView()
                case .keyboardClean: KeyboardCleanView()
                case .battery: BateraiView()
                case .fans: KipasTemperatureView()
                case .settings: SettingsView()
                }
            }
            .frame(minWidth: 800, minHeight: 640)
        }
        .background(GlassBackdrop().ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: .rebesNavigate)) { note in
            if let item = note.object as? SidebarItem { appState.selection = item }
        }
        .sheet(isPresented: $boot.showFullAccessOnboarding) {
            FullAccessOnboardingView()
                .environmentObject(boot)
        }
    }

    /// Brand header: app icon + wordmark at the top of the sidebar.
    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 26, height: 26)
            Text("Rebes!")
                .font(.system(size: 15, weight: .bold, design: .rounded))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.top, 14)
            .padding(.bottom, 3)
    }

    private func row(_ item: SidebarItem, _ title: String, _ icon: String, _ accent: Color) -> some View {
        SidebarRowButton(item: item, title: title, icon: icon, accent: accent,
                         appState: appState, hoverModel: hoverModel, pillNamespace: sidebarPill)
    }
}
