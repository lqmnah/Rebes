//
//  ChargeTypes.swift
//  RebesCore
//
//  Shared Codable types for the charge-control engine: the config the app
//  sends to the daemon, and the rich status the daemon reports back.
//  All charge SMC-key semantics (band encoding, clamping) live here so the
//  daemon, the CLI fallback, and the self-tests share one implementation.
//

import Foundation

/// Which SMC mechanism the firmware exposes for charge control.
/// Probed by key presence, never by macOS version.
public enum ChargeControlMode: String, Codable, Sendable {
    /// bfF0/bfD0/bfE0 — firmware enforces the band itself (incl. during sleep).
    case firmware
    /// CHTE — 4-byte binary charging gate, software hysteresis loop.
    case tahoeGate
    /// CH0B + CH0C — legacy 1-byte gates, software hysteresis loop.
    case legacyGate
    /// None present — point the user at System Settings.
    case unsupported

    public var label: String {
        switch self {
        case .firmware: return "Firmware-managed"
        case .tahoeGate: return "Software gate (CHTE)"
        case .legacyGate: return "Software gate (CH0B/CH0C)"
        case .unsupported: return "Not supported"
        }
    }
}

/// MagSafe LED behavior (SMC ACLC). Cosmetic — absence is never an error.
public enum ChargeLEDMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case system, off, greenAtLimit, orangeCharging

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .system: return "System"
        case .off: return "Off"
        case .greenAtLimit: return "Green at limit"
        case .orangeCharging: return "Orange while charging"
        }
    }
}

/// Steps of the battery calibration run:
/// charge to full → hold 1 h → discharge to 15% → recharge to full → hold 1 h.
public enum CalibrationStep: String, Codable, Sendable, CaseIterable {
    case chargeToFull, holdAtFull, dischargeToLow, rechargeToFull, finalHold

    public var stepNumber: Int { (CalibrationStep.allCases.firstIndex(of: self) ?? 0) + 1 }
    public static var stepCount: Int { allCases.count }
    public var label: String {
        switch self {
        case .chargeToFull: return "Charging to full"
        case .holdAtFull: return "Holding at full (1 h)"
        case .dischargeToLow: return "Discharging to 15%"
        case .rechargeToFull: return "Recharging to full"
        case .finalHold: return "Final hold (1 h)"
        }
    }
}

/// What the engine is currently doing. `idle` = control disabled,
/// `maintain` = normal limit/sailing enforcement.
public enum ChargePhase: Codable, Sendable, Equatable {
    case idle
    case maintain
    case topUp
    case discharge(target: Int)
    case calibration(step: CalibrationStep)

    /// True for the one-shot phases that override normal maintain logic.
    public var isOneShot: Bool {
        switch self {
        case .idle, .maintain: return false
        case .topUp, .discharge, .calibration: return true
        }
    }

    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .maintain: return "Maintaining limit"
        case .topUp: return "Topping up to full"
        case .discharge(let t): return "Discharging to \(t)%"
        case .calibration(let s): return "Calibration \(s.stepNumber)/\(CalibrationStep.stepCount): \(s.label)"
        }
    }
}

/// Heat protection: pause charging while the battery (SMC TB0T) is hot.
public struct HeatProtect: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// Pause at/above this °C; resume below `thresholdC − 2` (5-min flip hysteresis).
    public var thresholdC: Double

    public init(enabled: Bool = false, thresholdC: Double = 35) {
        self.enabled = enabled
        self.thresholdC = thresholdC
    }
}

/// Full user-facing charge configuration. The app persists a copy for
/// instant UI restore; the daemon persists the authoritative copy at
/// /Library/Application Support/com.lqmnah.rebes.helper/charge.json.
public struct ChargeConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// Charge limit in percent, 20...100. 100 = no limit (band deactivated).
    public var limitPercent: Int
    /// Sailing interval: charging resumes below `limitPercent − sailingDelta`. 2...10.
    public var sailingDelta: Int
    public var heatProtect: HeatProtect
    public var ledMode: ChargeLEDMode
    /// Keep the firmware band active when the daemon stops (survives reboots,
    /// sleep, and daemon restarts — the firmware enforces it alone).
    public var persistOnExit: Bool
    /// Automatically discharge back down to the limit when the battery sits
    /// more than 3% above it (requires an adapter-disable key).
    public var autoDischarge: Bool
    /// App-side: hold a sleep assertion while plugged in below the limit.
    public var disableSleepUntilLimit: Bool

    public init(enabled: Bool = false,
                limitPercent: Int = 80,
                sailingDelta: Int = 5,
                heatProtect: HeatProtect = HeatProtect(),
                ledMode: ChargeLEDMode = .system,
                persistOnExit: Bool = true,
                autoDischarge: Bool = false,
                disableSleepUntilLimit: Bool = false) {
        self.enabled = enabled
        self.limitPercent = limitPercent
        self.sailingDelta = sailingDelta
        self.heatProtect = heatProtect
        self.ledMode = ledMode
        self.persistOnExit = persistOnExit
        self.autoDischarge = autoDischarge
        self.disableSleepUntilLimit = disableSleepUntilLimit
    }

    /// Clamped copy that is safe to act on (UI floor 20%, delta 2...10,
    /// heat threshold 30...40 °C).
    public func sanitized() -> ChargeConfig {
        var c = self
        c.limitPercent = min(100, max(20, c.limitPercent))
        c.sailingDelta = min(10, max(2, c.sailingDelta))
        c.heatProtect.thresholdC = min(40, max(30, c.heatProtect.thresholdC))
        return c
    }

    /// The firmware band for a limit: upper = limit, lower = limit − sailingDelta.
    /// Delta is clamped to ≥2 so there is ALWAYS a hysteresis band — charging
    /// never toggles at a single threshold. Lower never goes below the 10%
    /// whitelist floor.
    public static func band(limitPercent: Int, sailingDelta: Int) -> (upper: UInt32, lower: UInt32) {
        let upper = min(100, max(20, limitPercent))
        let delta = min(10, max(2, sailingDelta))
        let lower = max(10, upper - delta)
        return (UInt32(upper), UInt32(lower))
    }

    /// Little-endian byte encoding used by bfD0/bfE0 (byte-reversed vs the
    /// conventional big-endian SMC ui32 — batt bits.ReverseBytes32).
    public static func leBytes(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }
}

/// Rich daemon-side status for the UI. The daemon is the source of truth;
/// `config` echoes what it is currently acting on.
public struct ChargeStatus: Codable, Sendable {
    public var mode: ChargeControlMode
    public var dischargeSupported: Bool
    public var ledSupported: Bool
    public var phase: ChargePhase
    /// Firmware-mode band read-back (LE-decoded percents) and activation flag.
    public var bandUpper: Int?
    public var bandLower: Int?
    public var bandActive: Bool
    public var batteryPercent: Int?
    public var isCharging: Bool
    public var externalConnected: Bool
    public var heatPaused: Bool
    public var failsafe: Bool
    public var lastError: String?
    public var helperVersion: String
    public var config: ChargeConfig?

    public init(mode: ChargeControlMode = .unsupported,
                dischargeSupported: Bool = false,
                ledSupported: Bool = false,
                phase: ChargePhase = .idle,
                bandUpper: Int? = nil,
                bandLower: Int? = nil,
                bandActive: Bool = false,
                batteryPercent: Int? = nil,
                isCharging: Bool = false,
                externalConnected: Bool = false,
                heatPaused: Bool = false,
                failsafe: Bool = false,
                lastError: String? = nil,
                helperVersion: String,
                config: ChargeConfig? = nil) {
        self.mode = mode
        self.dischargeSupported = dischargeSupported
        self.ledSupported = ledSupported
        self.phase = phase
        self.bandUpper = bandUpper
        self.bandLower = bandLower
        self.bandActive = bandActive
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.externalConnected = externalConnected
        self.heatPaused = heatPaused
        self.failsafe = failsafe
        self.lastError = lastError
        self.helperVersion = helperVersion
        self.config = config
    }
}
