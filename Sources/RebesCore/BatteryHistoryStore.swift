//
//  BatteryHistoryStore.swift
//  RebesCore
//
//  Persistent battery-health snapshots so the Health Trend chart survives
//  app restarts. One snapshot at most every 30 minutes (app launch + the
//  2.5s sampler both funnel through the dedupe), capped at ~90 days.
//  Storage: ~/Library/Application Support/Rebes/battery-history.json
//  (~4 KB/month). Corruption-tolerant: a bad file starts fresh, never crashes.
//

import Foundation

public struct BatterySnapshot: Codable, Sendable {
    public var t: Date
    /// Measured full-charge capacity in mAh.
    public var fcc: Int
    /// Health percent (one decimal).
    public var health: Double
    public var cycles: Int
    public var tempC: Double

    public init(t: Date, fcc: Int, health: Double, cycles: Int, tempC: Double) {
        self.t = t; self.fcc = fcc; self.health = health; self.cycles = cycles; self.tempC = tempC
    }
}

public final class BatteryHistoryStore: @unchecked Sendable {
    public static let shared = BatteryHistoryStore()

    private let lock = NSLock()
    private var snapshots: [BatterySnapshot] = []
    private let maxEntries = 4320                    // ~90 days at 30-min cadence
    private let minInterval: TimeInterval = 30 * 60
    private let fileURL: URL

    private init() {
        let dir = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Rebes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("battery-history.json")
        lock.lock()
        snapshots = Self.loadFromDisk(fileURL)
        lock.unlock()
    }

    /// Testing seam: isolated file location (never touches the real history).
    public init(fileURL: URL) {
        self.fileURL = fileURL
        lock.lock()
        snapshots = Self.loadFromDisk(fileURL)
        lock.unlock()
    }

    /// All snapshots, oldest first.
    public var all: [BatterySnapshot] {
        lock.lock(); defer { lock.unlock() }
        return snapshots
    }

    /// Record a snapshot. No-ops when the previous snapshot is <30 min old.
    /// Safe to call from any thread; the file write happens off the lock.
    public func record(fcc: Int, health: Double, cycles: Int, tempC: Double) {
        guard fcc > 0, health > 0 else { return }   // never persist junk readings
        lock.lock()
        if let last = snapshots.last, Date().timeIntervalSince(last.t) < minInterval {
            lock.unlock()
            return
        }
        snapshots.append(BatterySnapshot(t: Date(), fcc: fcc, health: health, cycles: cycles, tempC: tempC))
        if snapshots.count > maxEntries { snapshots.removeFirst(snapshots.count - maxEntries) }
        let toWrite = snapshots
        lock.unlock()

        if let data = try? JSONEncoder().encode(toWrite) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func loadFromDisk(_ url: URL) -> [BatterySnapshot] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([BatterySnapshot].self, from: data) else {
            return []
        }
        return Array(decoded.suffix(4320))
    }
}
