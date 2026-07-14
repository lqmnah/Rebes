//
//  AppSettings.swift
//  RebesCore
//
//  Persisted user preferences (UserDefaults). Covers menu bar appearance
//  and the automatic fan curve.
//

import Foundation

public enum MenuBarMetric: String, CaseIterable, Codable, Sendable {
    case cpu, memory, cpuTemp, fanRPM, battery, none

    public var label: String {
        switch self {
        case .cpu: return "CPU %"
        case .memory: return "Memory %"
        case .cpuTemp: return "CPU Temp"
        case .fanRPM: return "Fan RPM"
        case .battery: return "Battery %"
        case .none: return "Icon only"
        }
    }
    public var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .cpuTemp: return "thermometer.medium"
        case .fanRPM: return "fanblades"
        case .battery: return "battery.75"
        case .none: return "hand.thumbsup.fill"
        }
    }
}

/// One point on a temperature→fan-speed curve.
public struct FanCurvePoint: Codable, Sendable, Identifiable {
    public var id = UUID()
    public var tempC: Double
    public var percent: Double   // 0...100 of the fan's [min,max] range
    public init(tempC: Double, percent: Double) {
        self.tempC = tempC
        self.percent = percent
    }
}

public final class AppSettings: @unchecked Sendable {
    public static let shared = AppSettings()
    private let d = UserDefaults.standard
    private init() {}

    // Menu bar
    public var menuBarMetrics: [MenuBarMetric] {
        get {
            guard let raw = d.array(forKey: "menuBarMetrics") as? [String] else { return [.cpu] }
            let parsed = raw.compactMap { MenuBarMetric(rawValue: $0) }
            return parsed.isEmpty ? [.cpu] : parsed
        }
        set { d.set(newValue.map(\.rawValue), forKey: "menuBarMetrics") }
    }
    public var menuBarShowIcon: Bool {
        get { d.object(forKey: "menuBarShowIcon") == nil ? true : d.bool(forKey: "menuBarShowIcon") }
        set { d.set(newValue, forKey: "menuBarShowIcon") }
    }
    /// Off by default (clean Dock): the Dock icon then appears only while the
    /// main window is open, so the app menu/shortcuts still work when needed.
    public var showDockIcon: Bool {
        get { d.bool(forKey: "showDockIcon") }
        set { d.set(newValue, forKey: "showDockIcon") }
    }

    // Menu bar panel sections (all shown by default; editable in Settings)
    public var menuBarPanelShowHealth: Bool {
        get { boolDefaultingTrue("menuBarPanelShowHealth") }
        set { d.set(newValue, forKey: "menuBarPanelShowHealth") }
    }
    public var menuBarPanelShowStatCards: Bool {
        get { boolDefaultingTrue("menuBarPanelShowStatCards") }
        set { d.set(newValue, forKey: "menuBarPanelShowStatCards") }
    }
    public var menuBarPanelShowNetwork: Bool {
        get { boolDefaultingTrue("menuBarPanelShowNetwork") }
        set { d.set(newValue, forKey: "menuBarPanelShowNetwork") }
    }
    public var menuBarPanelShowFanControl: Bool {
        get { boolDefaultingTrue("menuBarPanelShowFanControl") }
        set { d.set(newValue, forKey: "menuBarPanelShowFanControl") }
    }
    public var menuBarPanelShowQuickActions: Bool {
        get { boolDefaultingTrue("menuBarPanelShowQuickActions") }
        set { d.set(newValue, forKey: "menuBarPanelShowQuickActions") }
    }

    private func boolDefaultingTrue(_ key: String) -> Bool {
        d.object(forKey: key) == nil ? true : d.bool(forKey: key)
    }
    /// True once the first-run Full Access prompt has been shown (so we don't nag).
    public var didOfferFullAccess: Bool {
        get { d.bool(forKey: "didOfferFullAccess") }
        set { d.set(newValue, forKey: "didOfferFullAccess") }
    }

    // Fan curve
    public var fanCurveEnabled: Bool {
        get { d.bool(forKey: "fanCurveEnabled") }
        set { d.set(newValue, forKey: "fanCurveEnabled") }
    }
    public var fanCurve: [FanCurvePoint] {
        get {
            guard let data = d.data(forKey: "fanCurve"),
                  let points = try? JSONDecoder().decode([FanCurvePoint].self, from: data),
                  !points.isEmpty else {
                return AppSettings.defaultCurve
            }
            return points.sorted { $0.tempC < $1.tempC }
        }
        set {
            if let data = try? JSONEncoder().encode(newValue.sorted { $0.tempC < $1.tempC }) {
                d.set(data, forKey: "fanCurve")
            }
        }
    }

    // Charge control — app-side copy so the UI restores instantly.
    // The daemon persists the authoritative copy and remains the source of
    // truth via chargeStatus.
    public var chargeConfig: ChargeConfig {
        get {
            guard let data = d.data(forKey: "chargeConfig"),
                  let cfg = try? JSONDecoder().decode(ChargeConfig.self, from: data) else {
                return ChargeConfig()
            }
            return cfg
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                d.set(data, forKey: "chargeConfig")
            }
        }
    }

    public static let defaultCurve: [FanCurvePoint] = [
        FanCurvePoint(tempC: 45, percent: 0),
        FanCurvePoint(tempC: 60, percent: 30),
        FanCurvePoint(tempC: 75, percent: 65),
        FanCurvePoint(tempC: 90, percent: 100),
    ]

    /// Linear-interpolate the curve at a temperature → percent, always clamped
    /// to a safe 0...100. Never returns a negative or >100 value even if the
    /// stored curve carries out-of-range points.
    public static func percent(for tempC: Double, curve: [FanCurvePoint]) -> Double {
        let pts = curve.map { FanCurvePoint(tempC: $0.tempC, percent: min(100, max(0, $0.percent))) }
                       .sorted { $0.tempC < $1.tempC }
        guard let first = pts.first, let last = pts.last else { return 0 }
        let raw: Double
        if tempC <= first.tempC { raw = first.percent }
        else if tempC >= last.tempC { raw = last.percent }
        else {
            var v = last.percent
            for i in 1..<pts.count {
                let a = pts[i - 1], b = pts[i]
                if tempC <= b.tempC {
                    let span = b.tempC - a.tempC
                    let t = span > 0 ? (tempC - a.tempC) / span : 0
                    v = a.percent + t * (b.percent - a.percent)
                    break
                }
            }
            raw = v
        }
        return min(100, max(0, raw))
    }
}
