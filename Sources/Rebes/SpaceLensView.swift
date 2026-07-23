//
//  SpaceLensView.swift
//  Rebes
//
//  Space Lens: drill-down folder size map. Duplicate Finder: hash-based
//  duplicate detection with one-click reclaim (to Trash).
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RebesCore

class SpaceLensState: ObservableObject {
    @Published var stack: [URL] = []
    @Published var entries: [DiskEntry] = []
    @Published var isScanning = false
    @Published var mode: Mode = .lens

    // Duplicates
    @Published var groups: [DuplicateGroup] = []
    @Published var isFindingDupes = false
    @Published var dupeProgress = ""
    @Published var errorMessage: String?
    @Published var showBeres = false
    @Published var beresDetail = ""

    @Published var showPicker = false

    enum Mode { case lens, duplicates }
    var current: URL? { stack.last }

    /// Generation token serializing lens scans: a slow scan of a big folder
    /// must never overwrite the results of a newer scan of a smaller one.
    var lensGeneration = 0

    // Thread-safe cancel flag (written on main, read on the hashing thread).
    private let cancelLock = NSLock()
    private var _cancelled = false
    func requestCancel() { cancelLock.lock(); _cancelled = true; cancelLock.unlock() }
    func resetCancel() { cancelLock.lock(); _cancelled = false; cancelLock.unlock() }
    var cancelled: Bool { cancelLock.lock(); defer { cancelLock.unlock() }; return _cancelled }
}

struct SpaceLensView: View {
    @StateObject private var state = SpaceLensState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(
                    title: "Space Lens",
                    subtitle: "Folder size map & duplicate file finder",
                    accent: Theme.accentFiles,
                    icon: "chart.pie"
                )

                Picker("", selection: $state.mode) {
                    Text("Space Map").tag(SpaceLensState.Mode.lens)
                    Text("Duplicates").tag(SpaceLensState.Mode.duplicates)
                }
                .pickerStyle(.segmented)
                .frame(width: 280)

                LQCard(padding: 12) {
                    HStack {
                        Button("Choose Folder…") { state.showPicker = true }
                            .buttonStyle(AccentButtonStyle(accent: Theme.accentFiles))
                        if state.mode == .lens, state.stack.count > 1 {
                            Button {
                                state.stack.removeLast()
                                if let url = state.current { scanLens(url) }
                            } label: { Label("Back", systemImage: "chevron.left") }
                            .buttonStyle(AccentButtonStyle(prominent: false))
                        }
                        if let url = state.current {
                            Text(url.path).font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.head)
                        }
                        Spacer()
                        if state.isScanning || state.isFindingDupes { ProgressView().controlSize(.small) }
                    }
                }

                if let err = state.errorMessage {
                    LQCard(padding: 10) {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(Theme.accentUninstall)
                    }
                }

                if state.mode == .lens {
                    lensView
                } else {
                    duplicatesView
                }
            }
            .padding(24)
        }
        .background(Theme.bg)
        .beresStamp(isPresented: $state.showBeres, detail: state.beresDetail)
        .fileImporter(isPresented: $state.showPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                if state.mode == .lens {
                    state.stack = [url]; scanLens(url)
                } else {
                    findDuplicates(url)
                }
            }
        }
    }

    private var maxSize: Int64 { state.entries.map(\.size).max() ?? 1 }

    private var lensView: some View {
        VStack(spacing: 6) {
            ForEach(Array(state.entries.enumerated()), id: \.element.id) { index, entry in
                LQCard(padding: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                            .foregroundStyle(entry.isDirectory ? Theme.accentFiles : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(entry.url.lastPathComponent)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.primary).lineLimit(1)
                                Spacer()
                                Text(entry.size.formattedSize)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Theme.accentFiles)
                            }
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Theme.accentFiles.opacity(0.35))
                                    .frame(width: geo.size.width * CGFloat(Double(entry.size) / Double(maxSize)))
                            }
                            .frame(height: 5)
                        }
                        if entry.isDirectory {
                            Button {
                                state.stack.append(entry.url); scanLens(entry.url)
                            } label: { Image(systemName: "chevron.right.circle") }
                            .buttonStyle(.plain)
                        }
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                        } label: { Image(systemName: "magnifyingglass.circle") }
                        .buttonStyle(.plain)
                    }
                }
                .hoverLift(accent: Theme.accentFiles)
                .cascadeIn(min(index, 12))
            }
            if state.entries.isEmpty && !state.isScanning {
                Text("Pick a folder — Rebes maps where your space went.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var duplicatesView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.isFindingDupes {
                LQCard(padding: 14) {
                    HStack {
                        ProgressView()
                        Text("Hashing: \(state.dupeProgress)")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Cancel") { state.requestCancel() }
                            .buttonStyle(AccentButtonStyle(prominent: false))
                    }
                }
            } else if !state.groups.isEmpty {
                let total = state.groups.reduce(Int64(0)) { $0 + $1.reclaimable }
                Text("\(state.groups.count) duplicate groups · can save \(total.formattedSize)")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accentFiles)
                ForEach(Array(state.groups.enumerated()), id: \.element.id) { index, group in
                    LQCard(padding: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(group.urls.count)× \(group.sizeEach.formattedSize) — save \(group.reclaimable.formattedSize)")
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                            ForEach(Array(group.urls.enumerated()), id: \.offset) { idx, url in
                                HStack {
                                    Image(systemName: idx == 0 ? "checkmark.circle.fill" : "doc")
                                        .foregroundStyle(idx == 0 ? Theme.accentBattery : .secondary)
                                        .font(.system(size: 11))
                                    Text(url.path).font(.system(size: 10)).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    if idx == 0 {
                                        Text("kept").font(.system(size: 9)).foregroundStyle(Theme.accentBattery)
                                    } else {
                                        Button("Trash") { trashDuplicate(group: group, url: url) }
                                            .buttonStyle(AccentButtonStyle(accent: Theme.accentUninstall, prominent: false))
                                    }
                                }
                            }
                        }
                    }
                    .hoverLift(accent: Theme.accentFiles)
                    .cascadeIn(min(index, 12))
                }
            } else if state.current != nil {
                Label("No duplicates here — every file is one of a kind.", systemImage: "hand.thumbsup")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text("Pick a folder — Rebes sniffs out true duplicates (matched by SHA-256 hash).")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private func scanLens(_ url: URL) {
        state.lensGeneration += 1
        let generation = state.lensGeneration
        state.isScanning = true
        state.errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let entries = DiskScanner.spaceLens(at: url)
            DispatchQueue.main.async {
                // A newer scan started while this one ran — drop stale results.
                guard generation == state.lensGeneration else { return }
                state.entries = entries
                state.isScanning = false
            }
        }
    }

    private func findDuplicates(_ url: URL) {
        state.stack = [url]
        state.isFindingDupes = true
        state.groups = []
        state.errorMessage = nil
        state.resetCancel()
        DispatchQueue.global(qos: .userInitiated).async {
            let groups = DiskScanner.findDuplicates(
                in: url,
                shouldCancel: { state.cancelled },
                progress: { name in DispatchQueue.main.async { state.dupeProgress = name } }
            )
            DispatchQueue.main.async {
                state.groups = groups
                state.isFindingDupes = false
            }
        }
    }

    private func trashDuplicate(group: DuplicateGroup, url: URL) {
        do {
            try SafeCleaner.shared.trashItem(at: url)
            state.beresDetail = "\(group.sizeEach.formattedSize) reclaimed"
            state.showBeres = true
            if let gi = state.groups.firstIndex(where: { $0.id == group.id }) {
                let remaining = state.groups[gi].urls.filter { $0 != url }
                if remaining.count > 1 {
                    state.groups[gi] = DuplicateGroup(sizeEach: group.sizeEach, urls: remaining)
                } else {
                    state.groups.remove(at: gi)
                }
            }
        } catch {
            state.errorMessage = "Could not move \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}
