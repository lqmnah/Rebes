//
//  LargeFilesView.swift
//  Rebes
//
//  Find large files in a user-picked folder; move to Trash with
//  confirmation. Errors are surfaced — a row only disappears when the
//  file really went to the Trash.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RebesCore

struct LargeFileItem: Identifiable {
    let id = UUID()
    let url: URL
    let size: Int64
}

class LargeFilesState: ObservableObject {
    @Published var items: [LargeFileItem] = []
    @Published var isScanning = false
    @Published var scannedFolder: URL?
    @Published var thresholdMB: Double = 100
    @Published var showPicker = false
    @Published var itemToTrash: LargeFileItem?
    @Published var showConfirmTrash = false
    @Published var errorMessage: String?
    @Published var showBeres = false
    @Published var beresDetail = ""
}

struct LargeFilesView: View {
    @StateObject private var state = LargeFilesState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(
                    title: "Large Files",
                    subtitle: "Find huge files in a folder you pick",
                    accent: Theme.accentFiles,
                    icon: "doc.text.magnifyingglass"
                )

                LQCard(padding: 14) {
                    HStack(spacing: 14) {
                        Button("Choose Folder…") { state.showPicker = true }
                            .buttonStyle(AccentButtonStyle(accent: Theme.accentFiles))
                            .disabled(state.isScanning)
                        if let folder = state.scannedFolder {
                            Text(folder.path)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text("Minimum:")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Slider(value: $state.thresholdMB, in: 50...1000, step: 50)
                            .frame(width: 140)
                        Text("\(Int(state.thresholdMB)) MB")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 60, alignment: .leading)
                    }
                }

                if let err = state.errorMessage {
                    LQCard(padding: 12) {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.accentUninstall)
                    }
                }

                if state.isScanning {
                    LQCard(padding: 30) {
                        HStack {
                            Spacer()
                            ProgressView("Scanning…")
                            Spacer()
                        }
                    }
                } else if !state.items.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(Array(state.items.enumerated()), id: \.element.id) { index, items in
                            LQCard(padding: 12) {
                                HStack {
                                    Image(systemName: "doc.fill")
                                        .foregroundStyle(Theme.accentFiles)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(items.url.lastPathComponent)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(items.url.deletingLastPathComponent().path)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    Text(items.size.formattedSize)
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Theme.accentFiles)
                                    Button {
                                        NSWorkspace.shared.activateFileViewerSelecting([items.url])
                                    } label: {
                                        Image(systemName: "magnifyingglass.circle")
                                    }
                                    .buttonStyle(.plain)
                                    .help("Show in Finder")
                                    Button {
                                        state.itemToTrash = items
                                        state.showConfirmTrash = true
                                    } label: {
                                        Image(systemName: "trash.circle")
                                            .foregroundStyle(Theme.accentUninstall)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Move to Trash")
                                }
                            }
                            .hoverLift(accent: Theme.accentFiles)
                            .cascadeIn(min(index, 12))
                        }
                    }
                } else if state.scannedFolder != nil {
                    LQCard(padding: 24) {
                        HStack(spacing: 12) {
                            Image(systemName: "hand.thumbsup.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(Theme.accentFiles)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Nothing huge in here — all clear.")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Text("No files above \(Int(state.thresholdMB)) MB in this folder.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(Theme.bg)
        .beresStamp(isPresented: $state.showBeres, detail: state.beresDetail)
        .fileImporter(isPresented: $state.showPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { scan(url) }
        }
        .confirmationDialog(
            "Move \"\(state.itemToTrash?.url.lastPathComponent ?? "")\" to Trash?",
            isPresented: $state.showConfirmTrash,
            presenting: state.itemToTrash
        ) { items in
            Button("Move to Trash", role: .destructive) { trash(items) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func scan(_ folder: URL) {
        state.isScanning = true
        state.scannedFolder = folder
        state.errorMessage = nil
        let threshold = Int64(state.thresholdMB) * 1_000_000
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [LargeFileItem] = []
            if let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                for case let url as URL in enumerator {
                    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                          values.isRegularFile == true,
                          let size = values.fileSize, Int64(size) >= threshold else { continue }
                    found.append(LargeFileItem(url: url, size: Int64(size)))
                }
            }
            found.sort { $0.size > $1.size }
            DispatchQueue.main.async {
                state.items = found
                state.isScanning = false
            }
        }
    }

    private func trash(_ items: LargeFileItem) {
        do {
            try SafeCleaner.shared.trashItem(at: items.url)
            state.items.removeAll { $0.id == items.id }
            state.errorMessage = nil
            state.beresDetail = "\(items.size.formattedSize) moved to Trash"
            state.showBeres = true
        } catch {
            // Row stays; the user must see that nothing was deleted.
            state.errorMessage = "Could not move \"\(items.url.lastPathComponent)\": \(error.localizedDescription)"
        }
    }
}
