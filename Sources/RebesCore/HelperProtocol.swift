//
//  HelperProtocol.swift
//  RebesCore
//
//  XPC protocol between the app and the privileged daemon
//  (RebesHelper running as a root launchd daemon).
//

import Foundation

public let kHelperMachServiceName = "com.lqmnah.rebes.helper"

@objc public protocol RebesHelperProtocol {
    /// Liveness + version check.
    func ping(reply: @escaping (String) -> Void)
    /// Wire-compat shim: flips `enabled` on the engine's charge config (the
    /// CHWA key is retired — the ChargeLoopEngine owns all charge writes).
    func setChargeLimit(_ value: Int, reply: @escaping (Bool, String) -> Void)
    /// Restore a fan to automatic mode (relocks Ftst when all fans are auto).
    func setFanAuto(_ index: Int, reply: @escaping (Bool, String) -> Void)
    /// Force a fan to a target RPM. Validated against hardware bounds daemon-side.
    func setFanSpeed(_ index: Int, rpm: Float, reply: @escaping (Bool, String) -> Void)
    /// Enable an automatic temperature→fan curve run entirely inside the daemon.
    /// `curveJSON` = JSON-encoded [FanCurvePoint]. enabled=false stops it.
    func setFanCurve(enabled: Bool, curveJSON: String, reply: @escaping (Bool, String) -> Void)
    /// Current daemon fan-curve status: (running, human-readable description).
    func fanCurveStatus(reply: @escaping (Bool, String) -> Void)
    /// Legacy status shim, kept for wire compatibility.
    /// reply(supported, enabled): supported=charge control available, enabled=limit on.
    func chargeLimitStatus(reply: @escaping (Bool, Bool) -> Void)
    /// Apply the full charge configuration (JSON-encoded ChargeConfig).
    /// This is the write path — setChargeLimit is a 0/1 shim onto it.
    func setChargeConfig(_ configJSON: Data, withReply reply: @escaping (Bool, String) -> Void)
    /// Rich engine status (JSON-encoded ChargeStatus): mode, probe results,
    /// phase, band read-back, battery %, heat-pause/failsafe, helper version.
    func chargeStatus(withReply reply: @escaping (Data) -> Void)
    /// One-shot: charge to full once, then restore the limit.
    func startTopUp(withReply reply: @escaping (Bool, String) -> Void)
    /// One-shot: disable the adapter input until the battery reaches `percent`.
    func startDischarge(to percent: Int, withReply reply: @escaping (Bool, String) -> Void)
    /// One-shot: full calibration run (full → hold → 15% → full → hold).
    func startCalibration(withReply reply: @escaping (Bool, String) -> Void)
    /// Cancel any one-shot phase and return to normal limit maintenance.
    func cancelPhase(withReply reply: @escaping (Bool, String) -> Void)
    /// Release inactive/purgeable memory (/usr/sbin/purge) — fixed command, no input.
    func purgeRAM(reply: @escaping (Bool, String) -> Void)
    /// Clear the DNS cache (dscacheutil -flushcache + HUP mDNSResponder) — fixed commands.
    func flushDNS(reply: @escaping (Bool, String) -> Void)
}
