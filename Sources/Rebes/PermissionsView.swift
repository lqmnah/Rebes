//
//  PermissionsView.swift
//  Rebes
//
//  A status list of every access Rebes needs: green when granted, red when
//  missing, with a Grant/Open Settings button per row. Shown both on first
//  launch (as a sheet) and inside Settings.
//

import SwiftUI
import AppKit
import RebesCore

final class PermissionsListState: ObservableObject {
    @Published var busy: PermissionKind?
}

struct PermissionsList: View {
    @ObservedObject private var perms = PermissionsManager.shared
    @StateObject private var ls = PermissionsListState()

    private var helperBinaryPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/RebesHelper").path
    }

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(PermissionKind.allCases.enumerated()), id: \.element.id) { index, kind in
                row(kind)
                    .cascadeIn(index)
            }
        }
        .onAppear { perms.refresh() }
        // Re-check when the app regains focus (user may have granted in System Settings).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            perms.refresh()
        }
    }

    private func row(_ kind: PermissionKind) -> some View {
        let ok = perms.isGranted(kind)
        return LQCard(padding: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill((ok ? Color.green : Color.red).opacity(0.16)).frame(width: 34, height: 34)
                    Image(systemName: kind.icon).foregroundStyle(ok ? .green : .red)
                        // One-shot bounce the moment the permission flips.
                        .symbolEffect(.bounce, value: ok)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(kind.title).font(.system(size: 13, weight: .semibold))
                        if kind.required {
                            Text("REQUIRED").font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Theme.accentFiles.opacity(0.2)))
                                .foregroundStyle(Theme.accentFiles)
                        }
                    }
                    Text(kind.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if ls.busy == kind {
                    ProgressView().controlSize(.small)
                } else if ok {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
                } else {
                    Button(kind == .accessibility || kind == .fullDisk ? "Open Settings" : "Grant") {
                        grant(kind)
                    }
                    .buttonStyle(AccentButtonStyle())
                }
            }
        }
        // Red → green (and the Granted swap) animate instead of snapping.
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: ok)
        .hoverLift(accent: Theme.teal, scale: 1.01, pointer: false)
    }

    private func grant(_ kind: PermissionKind) {
        ls.busy = kind
        perms.request(kind, helperBinary: helperBinaryPath) { _ in
            ls.busy = nil
            perms.refresh()
        }
        if kind == .accessibility || kind == .fullDisk { ls.busy = nil }
    }
}

struct FullAccessOnboardingView: View {
    @EnvironmentObject private var boot: AppBootstrap
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var iconIn = LocalState(false)

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(Theme.teal.opacity(0.16)).frame(width: 72, height: 72)
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: 52, height: 52)
            }
            .padding(.top, 4)
            // Gentle one-shot spring-in for the welcome icon.
            .scaleEffect(iconIn.value || reduceMotion ? 1 : 0.6)
            .opacity(iconIn.value ? 1 : 0)
            .onAppear {
                guard !iconIn.value else { return }
                let anim: Animation = reduceMotion
                    ? .easeOut(duration: 0.25)
                    : .spring(response: 0.45, dampingFraction: 0.75)
                withAnimation(anim) { iconIn.value = true }
            }

            Text("Welcome to Rebes!").font(.system(size: 20, weight: .bold))
            Text("Rebes needs a few permissions to clean, monitor, and care for your Mac. Grant them now, or later from Settings — anything still missing shows up in red.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)

            PermissionsList().frame(maxWidth: 460)

            HStack {
                Spacer()
                Button("Continue") { boot.dismissOnboarding(); dismiss() }
                    .buttonStyle(AccentButtonStyle())
            }
            .frame(maxWidth: 460)
            .padding(.top, 2)
        }
        .padding(28)
        .frame(width: 520)
        .background(GlassBackdrop(material: .hudWindow).ignoresSafeArea())
    }
}
