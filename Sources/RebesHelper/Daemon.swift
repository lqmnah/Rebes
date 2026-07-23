//
//  Daemon.swift
//  RebesHelper
//
//  XPC daemon mode: launched by launchd as root
//  (`RebesHelper daemon`), serves RebesHelperProtocol.
//  Every request is validated against HelperWhitelist —
//  the daemon trusts nobody, including the app.
//

import Foundation
import IOKit.pwr_mgt
import RebesCore

final class HelperService: NSObject, RebesHelperProtocol {
    func ping(reply: @escaping (String) -> Void) {
        reply(ChargeLoopEngine.helperVersion)
    }

    /// Wire-compat shim for older app builds. No direct SMC write here —
    /// the engine queue is the single writer of every charge key: 1 enables
    /// charge control with the persisted (or default 80%) config, 0 disables.
    func setChargeLimit(_ value: Int, reply: @escaping (Bool, String) -> Void) {
        guard value == 0 || value == 1 else {
            reply(false, "refused: value must be 0 or 1")
            return
        }
        ChargeLoopEngine.shared.setEnabled(value == 1) { ok, msg in reply(ok, msg) }
    }

    // MARK: - charge control (all routed onto the engine's serial queue)

    func setChargeConfig(_ configJSON: Data, withReply reply: @escaping (Bool, String) -> Void) {
        guard let config = try? JSONDecoder().decode(ChargeConfig.self, from: configJSON) else {
            reply(false, "refused: invalid charge config JSON")
            return
        }
        ChargeLoopEngine.shared.apply(config) { ok, msg in reply(ok, msg) }
    }

    func chargeStatus(withReply reply: @escaping (Data) -> Void) {
        let status = ChargeLoopEngine.shared.currentStatus
        if let data = try? JSONEncoder().encode(status) {
            reply(data)
        } else {
            // Never fail silently — an empty reply reads as "daemon offline".
            NSLog("rebes-helper: chargeStatus encode failed")
            reply(Data())
        }
    }

    func startTopUp(withReply reply: @escaping (Bool, String) -> Void) {
        ChargeLoopEngine.shared.startTopUp { ok, msg in reply(ok, msg) }
    }

    func startDischarge(to percent: Int, withReply reply: @escaping (Bool, String) -> Void) {
        ChargeLoopEngine.shared.startDischarge(to: percent) { ok, msg in reply(ok, msg) }
    }

    func startCalibration(withReply reply: @escaping (Bool, String) -> Void) {
        ChargeLoopEngine.shared.startCalibration { ok, msg in reply(ok, msg) }
    }

    func cancelPhase(withReply reply: @escaping (Bool, String) -> Void) {
        ChargeLoopEngine.shared.cancelPhase { ok, msg in reply(ok, msg) }
    }

    func setFanAuto(_ index: Int, reply: @escaping (Bool, String) -> Void) {
        // Routed onto the curve engine's serial queue — the single-writer rule:
        // a manual SMC fan write must never interleave with a curve tick.
        FanCurveEngine.shared.serialize {
            let smc = SMC.shared
            let fNum = Int(smc.getValue("FNum") ?? 0)
            guard index >= 0, index < fNum else {
                reply(false, "refused: fan index out of range")
                return
            }
            guard smc.setFanMode(index, mode: .automatic) else {
                reply(false, "SMC: failed to restore automatic mode")
                return
            }
            #if arch(arm64)
            let allAuto = (0..<fNum).allSatisfy {
                Int(smc.getValueAllowingZero(smc.fanModeKey($0)) ?? 1) == 0
            }
            if allAuto && !smc.resetFanControl() {
                reply(false, "fan is automatic but relocking fan control failed")
                return
            }
            #endif
            reply(true, "OK")
        }
    }

    func setFanSpeed(_ index: Int, rpm: Float, reply: @escaping (Bool, String) -> Void) {
        FanCurveEngine.shared.serialize {
            let smc = SMC.shared
            let fNum = Int(smc.getValue("FNum") ?? 0)
            guard rpm.isFinite,
                  HelperWhitelist.validateFanTarget(key: "F\(index)Tg", target: rpm, fNum: fNum, getBounds: { i in
                      guard let mn = smc.getValueAllowingZero("F\(i)Mn"),
                            let mx = smc.getValue("F\(i)Mx"), mx > mn else { return nil }
                      return (Float(mn), Float(mx))
                  }) else {
                reply(false, "refused: rpm outside hardware bounds")
                return
            }
            reply(smc.setFanSpeed(index, speed: Int(rpm), shouldAbort: { FanCurveEngine.shared.cancelRequested }), "done")
        }
    }

    func setFanCurve(enabled: Bool, curveJSON: String, reply: @escaping (Bool, String) -> Void) {
        if !enabled {
            FanCurveEngine.shared.stop()
            reply(true, "curve stopped")
            return
        }
        guard let data = curveJSON.data(using: .utf8),
              let points = try? JSONDecoder().decode([FanCurvePoint].self, from: data),
              !points.isEmpty else {
            reply(false, "invalid curve JSON")
            return
        }
        FanCurveEngine.shared.start(curve: points)
        reply(true, "curve running (\(points.count) points)")
    }

    func fanCurveStatus(reply: @escaping (Bool, String) -> Void) {
        let e = FanCurveEngine.shared
        reply(e.isRunning, e.lastStatus)
    }

    /// Wire-compat shim: (supported, enabled) now reflects the engine's
    /// probed mode and applied config instead of the retired CHWA key.
    func chargeLimitStatus(reply: @escaping (Bool, Bool) -> Void) {
        let status = ChargeLoopEngine.shared.currentStatus
        reply(status.mode != .unsupported, status.config?.enabled ?? false)
    }

    // Fixed maintenance commands (absolute paths, no arguments from the app,
    // no shell) — the caller is already signature-checked, and there is
    // nothing here a caller could parameterize.

    func purgeRAM(reply: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = runFixed("/usr/sbin/purge", [])
            reply(r.status == 0, r.status == 0 ? "RAM purged" : "purge failed: \(r.stderr)")
        }
    }

    func flushDNS(reply: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let flush = runFixed("/usr/bin/dscacheutil", ["-flushcache"])
            guard flush.status == 0 else {
                reply(false, "dscacheutil failed: \(flush.stderr)")
                return
            }
            let hup = runFixed("/usr/bin/killall", ["-HUP", "mDNSResponder"])
            reply(hup.status == 0, hup.status == 0 ? "DNS cache cleared" : "killall failed: \(hup.stderr)")
        }
    }
}

/// Run a fixed absolute-path executable and capture its exit status + stderr.
/// A hung child is terminated after 30s so it can't leak a worker thread forever.
private func runFixed(_ path: String, _ args: [String]) -> (status: Int32, stderr: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let err = Pipe()
    p.standardOutput = FileHandle.nullDevice
    p.standardError = err
    do { try p.run() } catch {
        return (-1, "\(error.localizedDescription)")
    }
    let watchdog = DispatchSource.makeTimerSource(queue: .global())
    watchdog.schedule(deadline: .now() + 30)
    watchdog.setEventHandler { p.terminate() }
    watchdog.resume()
    let data = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    watchdog.cancel()
    let msg = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (p.terminationStatus, msg)
}

/// Only accept XPC connections from a process signed with our own identifier
/// AND whose executable is the Rebes.app binary in /Applications or inside the
/// connecting user's own home directory.
///
/// The path policy is the teeth: on ad-hoc-signed builds another local user
/// (e.g. guest) could re-sign a copy with our identifier, but they cannot
/// write to /Applications or into the owner's home — so they cannot drive
/// this root daemon. A process running AS THE SAME USER could still place a
/// re-signed copy in that home; that residual surface is bounded by the
/// HelperWhitelist (fan targets clamped to hardware bounds, charge values to
/// their documented safe sets, discharge floor 20%). For a fully hardened
/// install, sign with your own Developer ID and tighten the requirement to
/// `anchor apple generic and certificate leaf[subject.OU] = "<team id>"`.
/// (Swift exposes no audit_token on NSXPCConnection; identity is PID-based,
/// with the path policy as the primary barrier.)
func connectionIsTrusted(_ connection: NSXPCConnection) -> Bool {
    let pid = connection.processIdentifier
    let attrs = [kSecGuestAttributePid: pid] as CFDictionary
    var code: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
          let secCode = code else { return false }

    let req = "identifier \"com.lqmnah.rebes\"" as CFString
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(req, [], &requirement) == errSecSuccess,
          let requirement,
          SecCodeCheckValidity(secCode, [], requirement) == errSecSuccess else { return false }

    // Peer executable must be the app binary inside a Rebes.app bundle, in
    // /Applications or the connecting user's own home.
    var pathBuf = [CChar](repeating: 0, count: 4 * 1024)
    guard proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 else { return false }
    let path = String(decoding: pathBuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)

    // Peer's home directory from its uid (root's home would be useless here).
    var home = ""
    var info = proc_bsdshortinfo()
    let n = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdshortinfo>.stride))
    if n > 0, let pw = getpwuid(info.pbsi_uid), let dir = pw.pointee.pw_dir {
        home = String(cString: dir)
    }

    let inApplications = path == "/Applications/Rebes.app/Contents/MacOS/Rebes"
    let inUserHome = !home.isEmpty && home != "/" &&
        path.hasPrefix(home + "/") && path.hasSuffix("/Rebes.app/Contents/MacOS/Rebes")
    return inApplications || inUserHome
}

/// Runs the temperature→fan-speed curve entirely inside the root daemon so it
/// keeps working with the app closed. Reads the hottest CPU sensor, maps it
/// through the curve, and drives every fan — with the SAME whitelist bounds
/// validation the per-call XPC path uses. All state and SMC writes run on one
/// serial queue so start/stop can never interleave with a tick.
final class FanCurveEngine: @unchecked Sendable {
    static let shared = FanCurveEngine()

    // Single serial queue owns curve/timer/isRunning AND every SMC write —
    // a tick and a stop() can never overlap.
    private let queue = DispatchQueue(label: "com.lqmnah.rebes.fancurve")
    private let stateLock = NSLock()          // guards the fields the XPC thread reads
    private var timer: DispatchSourceTimer?
    private var curve: [FanCurvePoint] = []
    private var _isRunning = false
    private var _lastStatus = "idle"

    // If a temperature read fails, don't leave fans stuck at a stale low RPM:
    // after this many consecutive failures, hand control back to the firmware.
    private var failedReads = 0
    private let maxFailedReads = 3

    private let tempKeys = ["Tp01", "Tp05", "Tp09", "TC10", "Tp0D"]

    // Cancellation flag for the SIGTERM path: set from OUTSIDE the serial
    // queue (a queued write would sit behind the in-flight tick it needs to
    // interrupt), checked inside SMC retry loops so a stop() can never be
    // starved past launchd's ExitTimeOut.
    private let cancelLock = NSLock()
    private var _cancelRequested = false
    /// Internal (not private) so RPC fan writes can also honor a pending shutdown.
    var cancelRequested: Bool { cancelLock.lock(); defer { cancelLock.unlock() }; return _cancelRequested }
    private func setCancelRequested(_ v: Bool) { cancelLock.lock(); _cancelRequested = v; cancelLock.unlock() }

    // Restore-automatic self-heal: a transient SMC failure at stop() must not
    // leave fans forced while status reports "stopped".
    private var restoreRetry: DispatchSourceTimer?
    private var restoreAttempts = 0

    var isRunning: Bool { stateLock.lock(); defer { stateLock.unlock() }; return _isRunning }
    var lastStatus: String { stateLock.lock(); defer { stateLock.unlock() }; return _lastStatus }

    private func setState(running: Bool? = nil, status: String? = nil) {
        stateLock.lock(); defer { stateLock.unlock() }
        if let running { _isRunning = running }
        if let status { _lastStatus = status }
    }

    /// Run a manual fan operation on the engine queue — the single-writer rule:
    /// a manual SMC write must never interleave with a curve tick.
    func serialize(_ work: @escaping () -> Void) { queue.async(execute: work) }

    func start(curve: [FanCurvePoint]) {
        queue.async {
            self.restoreRetry?.cancel()
            self.restoreRetry = nil
            self.curve = curve
            self.failedReads = 0
            if self.timer == nil {
                let t = DispatchSource.makeTimerSource(queue: self.queue)
                t.schedule(deadline: .now(), repeating: 3.0)
                t.setEventHandler { [weak self] in self?.tick() }
                t.resume()
                self.timer = t
            }
            self.setState(running: true, status: "starting")
        }
    }

    /// Stop the curve and restore automatic control. Runs synchronously on the
    /// engine queue so it cannot race an in-flight tick; the cancel flag makes
    /// any in-flight tick's SMC retry loops bail fast so the stop can't be
    /// starved past launchd's ExitTimeOut.
    func stop() {
        setCancelRequested(true)
        queue.sync {
            self.timer?.cancel()
            self.timer = nil
            self.setState(running: false, status: "stopped")
            self.restoreAutomatic()
        }
        setCancelRequested(false)
    }

    private func restoreAutomatic() {
        if attemptRestore() {
            restoreRetry?.cancel()
            restoreRetry = nil
            restoreAttempts = 0
        } else {
            scheduleRestoreRetry()
        }
    }

    private func attemptRestore() -> Bool {
        let smc = SMC.shared
        let fNum = Int(smc.getValue("FNum") ?? 0)
        var ok = true
        for i in 0..<fNum { ok = smc.setFanMode(i, mode: .automatic) && ok }
        #if arch(arm64)
        ok = smc.resetFanControl() && ok
        #endif
        return ok
    }

    /// Retry the automatic-mode restore every 5s (max 6 attempts) until the
    /// hardware agrees — same self-heal pattern the charge engine uses.
    /// Runs on `queue`.
    private func scheduleRestoreRetry() {
        guard restoreRetry == nil else { return }
        restoreAttempts = 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5.0)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.restoreAttempts += 1
            if self.attemptRestore() {
                self.restoreRetry?.cancel()
                self.restoreRetry = nil
                self.restoreAttempts = 0
                self.setState(status: "stopped")
            } else if self.restoreAttempts >= 6 {
                self.restoreRetry?.cancel()
                self.restoreRetry = nil
                self.setState(status: "WARNING: restore automatic failed — fans may still be forced")
            }
        }
        t.resume()
        restoreRetry = t
    }

    private func tick() {
        // Runs on `queue`; timer is cancelled synchronously in stop(), so if we
        // are here the engine is still meant to be running.
        let smc = SMC.shared
        guard let temp = tempKeys.compactMap({ smc.getValue($0) }).max(), temp > 0 else {
            failedReads += 1
            if failedReads >= maxFailedReads {
                setState(status: "temp sensor unavailable — restored automatic")
                restoreAutomatic()
            } else {
                setState(status: "temp read failed (\(failedReads)/\(maxFailedReads))")
            }
            return
        }
        failedReads = 0

        let pct = AppSettings.percent(for: temp, curve: curve)   // already clamped 0...100
        let fNum = Int(smc.getValue("FNum") ?? 0)
        var applied: [String] = []
        for i in 0..<fNum {
            guard let mn = smc.getValueAllowingZero("F\(i)Mn"),
                  let mx = smc.getValue("F\(i)Mx"), mx > mn else { continue }
            let rpm = Float(mn + (mx - mn) * (pct / 100))
            // Same whitelist the per-call path uses — never write out-of-bounds.
            guard rpm.isFinite,
                  HelperWhitelist.validateFanTarget(key: "F\(i)Tg", target: rpm, fNum: fNum,
                                                    getBounds: { _ in (Float(mn), Float(mx)) }) else { continue }
            if smc.setFanSpeed(i, speed: Int(rpm), shouldAbort: { [weak self] in self?.cancelRequested ?? true }) { applied.append("\(Int(rpm))") }
        }
        setState(status: String(format: "%.0f°C → %.0f%% → %@ rpm", temp, pct, applied.joined(separator: "/")))
    }
}

// MARK: - Charge control engine

/// Runs AlDente-parity charge control entirely inside the root daemon,
/// copying FanCurveEngine's safety pattern exactly:
///   • ONE serial queue owns ALL state mutation and EVERY charge-related SMC
///     write (bfF0/bfD0/bfE0/CHTE/CH0B/CH0C/CHIE/CH0J/CH0I/ACLC) — a tick,
///     an apply and a stop can never interleave (single-writer rule).
///   • NSLock guards only the status snapshot the XPC thread reads.
///   • 3-strikes failsafe: consecutive sensor-read failures restore a safe
///     state (adapter on, gates open, LED system) and keep retrying — a
///     failed read can never leave the adapter off or a gate closed.
/// Battery %, isCharging and ExternalConnected are read daemon-side via
/// BatteryReader (ioreg — proven root-compatible, no GUI session needed).
final class ChargeLoopEngine: @unchecked Sendable {
    static let shared = ChargeLoopEngine()

    static let helperVersion = "rebes-helper 2.0"
    static let stateDir = "/Library/Application Support/com.lqmnah.rebes.helper"
    static let configPath = stateDir + "/charge.json"
    /// Marker: the currently active firmware band was written by Rebes.
    /// macOS's native Charge Limit uses the SAME keys — we must never
    /// deactivate a band we did not write (that would silently disable the
    /// user's System Settings limit).
    static let bandOwnedPath = stateDir + "/band-owned"

    // Single serial queue: owns all fields below AND every charge SMC write.
    private let queue = DispatchQueue(label: "com.lqmnah.rebes.chargeloop")
    // Guards ONLY the snapshot the XPC thread reads.
    private let stateLock = NSLock()
    private var _status = ChargeStatus(helperVersion: ChargeLoopEngine.helperVersion)

    private var timer: DispatchSourceTimer?
    private var probed = false
    private var mode: ChargeControlMode = .unsupported
    private var dischargeKey: String?
    private var ledSupported = false
    private var config = ChargeConfig()
    private var phase: ChargePhase = .idle

    // Failsafe (FanCurveEngine's 3-strikes restore-automatic, charge flavor).
    private var consecutiveFailures = 0
    private let maxFailures = 3
    private var failsafe = false
    private var lastError: String?

    // Heat protection (2 °C + 5-minute flip hysteresis).
    private var heatPaused = false
    private var lastHeatFlip = Date.distantPast

    // Gate modes: last commanded gate state + missed-tick (sleep) guard.
    private var gateOpen = true
    private var lastTickAt: Date?

    // Side effects that must be undone on stop/failsafe.
    private var adapterDisabled = false
    private var ledWritten: UInt8?
    private var sleepAssertion: IOPMAssertionID = 0

    // Calibration hold timing.
    private var holdStart: Date?

    // A completed Top Up intentionally sits above the limit — suppress
    // Automatic Discharge until the battery has drifted back down on its own,
    // otherwise auto-discharge would immediately undo the top-up.
    private var suppressAutoDischarge = false

    private init() {}

    var currentStatus: ChargeStatus {
        stateLock.lock(); defer { stateLock.unlock() }
        return _status
    }

    private var tickPeriod: Double { mode == .firmware ? 10.0 : 5.0 }

    // MARK: lifecycle

    /// Called once at daemon start: probe capabilities, re-arm from the
    /// persisted config (so the loop survives reboots), start the loop.
    func bootstrap() {
        queue.async {
            self.probeIfNeeded()
            if let persisted = ChargeLoopEngine.loadPersistedConfig() {
                self.config = persisted.sanitized()
                // .maintain on an unsupported machine would be a phantom status
                // (the timer refuses to start) — stay .idle.
                if self.config.enabled, self.mode != .unsupported { self.phase = .maintain }
            }
            self.reconcileHardwareAfterRestart()
            self.startTimerLocked()
            self.tick()
        }
    }

    /// A fresh daemon start is never legitimately mid-phase (phases are not
    /// persisted), yet the PREVIOUS daemon may have died uncleanly (kill -9,
    /// crash) with the adapter disabled or a gate closed. Undo anything a
    /// dead predecessor could have left behind BEFORE the loop starts —
    /// otherwise a plugged-in Mac can sit draining to 0% forever.
    private func reconcileHardwareAfterRestart() {
        if let key = dischargeKey,
           let raw = SMC.shared.readRaw(key), (raw.bytes.first ?? 0) != 0x00,
           HelperWhitelist.validateWrite(key: key, bytes: [0x00]) {
            _ = SMC.shared.writeUInt8(key, 0x00)
        }
        // Gate modes: open the gate; the first tick closes it again if the
        // limit demands it. (Open is the safe direction — the band logic
        // re-inhibits within one tick.)
        if mode == .tahoeGate || mode == .legacyGate {
            _ = writeGate(allowCharging: true)
        }
    }

    /// Apply a full config (the ONLY write path — per-call RPCs are shims).
    func apply(_ newConfig: ChargeConfig, completion: @escaping (Bool, String) -> Void) {
        queue.async {
            self.applyOnQueue(newConfig, completion: completion)
        }
    }

    /// setChargeLimit wire-compat shim target: flip `enabled` on the current config.
    func setEnabled(_ enabled: Bool, completion: @escaping (Bool, String) -> Void) {
        queue.async {
            var cfg = self.config
            cfg.enabled = enabled
            self.applyOnQueue(cfg, completion: completion)
        }
    }

    /// Apply body — must already be on `queue`.
    private func applyOnQueue(_ newConfig: ChargeConfig, completion: (Bool, String) -> Void) {
        probeIfNeeded()
        guard mode != .unsupported else {
            completion(false, "charge control not supported on this firmware — use System Settings → Battery")
            return
        }
        let cfg = newConfig.sanitized()
        let wasEnabled = config.enabled
        config = cfg
        ChargeLoopEngine.persist(cfg)
        if wasEnabled && !cfg.enabled {
            // User turned control off: undo side effects and release the band.
            abortPhaseSideEffects()
            deactivateBand()
            if mode != .firmware { _ = writeGate(allowCharging: true) }
            phase = .idle
        } else if cfg.enabled, !phase.isOneShot {
            phase = .maintain
        }
        startTimerLocked()
        tick()
        completion(true, "OK")
    }

    /// Stop the loop and restore a safe state. Runs synchronously on the
    /// engine queue so it can never race an in-flight tick (FanCurve pattern).
    func stop() {
        queue.sync {
            self.timer?.cancel()
            self.timer = nil
            self.restoreSafeState()
            self.publishStatus(nil)
        }
    }

    // MARK: one-shot phases

    func startTopUp(completion: @escaping (Bool, String) -> Void) {
        queue.async {
            self.probeIfNeeded()
            guard self.mode != .unsupported else {
                completion(false, "charge control not supported on this firmware")
                return
            }
            // Refuse up front instead of silently self-cancelling on the next
            // tick — "nothing happened" reads as a broken button.
            guard BatteryReader.read()?.isPluggedIn == true else {
                completion(false, "plug in the charger first — Top Up needs AC power")
                return
            }
            self.abortPhaseSideEffects()
            self.phase = .topUp
            self.startTimerLocked()
            self.tick()
            completion(true, "topping up to full")
        }
    }

    func startDischarge(to percent: Int, completion: @escaping (Bool, String) -> Void) {
        queue.async {
            self.probeIfNeeded()
            guard self.dischargeKey != nil else {
                completion(false, "no adapter-disable key on this firmware — discharge unavailable")
                return
            }
            guard BatteryReader.read()?.isPluggedIn == true else {
                completion(false, "plug in the charger first — Discharge turns the adapter input off")
                return
            }
            // Hard floor 20%: the RPC surface must not be able to run the
            // battery low even if a malicious/buggy caller asks for it.
            // (Calibration's internal 15% step doesn't go through this path.)
            let target = min(100, max(20, percent))
            self.abortPhaseSideEffects()
            self.phase = .discharge(target: target)
            self.startTimerLocked()
            self.tick()
            completion(true, "discharging to \(target)%")
        }
    }

    func startCalibration(completion: @escaping (Bool, String) -> Void) {
        queue.async {
            self.probeIfNeeded()
            guard self.dischargeKey != nil else {
                completion(false, "calibration needs adapter control (discharge) — unavailable on this firmware")
                return
            }
            guard BatteryReader.read()?.isPluggedIn == true else {
                completion(false, "plug in the charger first — calibration runs on AC power")
                return
            }
            self.abortPhaseSideEffects()
            self.phase = .calibration(step: .chargeToFull)
            self.startTimerLocked()
            self.tick()
            completion(true, "calibration started")
        }
    }

    func cancelPhase(completion: @escaping (Bool, String) -> Void) {
        queue.async {
            self.abortPhaseSideEffects()
            self.phase = self.config.enabled ? .maintain : .idle
            self.tick()
            completion(true, "phase cancelled")
        }
    }

    // MARK: persistence (root-owned, daemon-writable)

    /// The state dir lives under /Library/Application Support, which is
    /// group-admin writable. It must be root-owned, a real directory (not a
    /// symlink) and 0700 — otherwise any admin-group process could pre-seed
    /// `band-owned` (tricking the daemon into deactivating the user's NATIVE
    /// charge limit) or spoof the persisted config.
    @discardableResult
    static func secureStateDir() -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        var st = stat()
        guard lstat(stateDir, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == 0 else {
            NSLog("rebes-helper: state dir failed security check (owner/symlink)")
            return false
        }
        _ = chmod(stateDir, 0o700)   // tighten dirs created by older builds
        return true
    }

    static func persist(_ config: ChargeConfig) {
        guard secureStateDir() else { return }
        let fm = FileManager.default
        guard let data = try? JSONEncoder().encode(config) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)
        } catch {
            // A failed persist loses re-arm-after-reboot while the UI shows
            // the limit enabled — never fail silently.
            NSLog("rebes-helper: failed to persist charge config: \(error.localizedDescription)")
        }
    }

    static func loadPersistedConfig() -> ChargeConfig? {
        guard secureStateDir() else { return nil }
        guard let data = FileManager.default.contents(atPath: configPath) else { return nil }
        return try? JSONDecoder().decode(ChargeConfig.self, from: data)
    }

    static func bandOwned() -> Bool {
        FileManager.default.fileExists(atPath: bandOwnedPath)
    }

    static func setBandOwned(_ owned: Bool) {
        let fm = FileManager.default
        if owned {
            guard secureStateDir() else { return }
            fm.createFile(atPath: bandOwnedPath, contents: Data())
        } else {
            try? fm.removeItem(atPath: bandOwnedPath)
        }
    }

    // MARK: probe (once, on `queue`)

    private func probeIfNeeded() {
        guard !probed else { return }
        probed = true
        let smc = SMC.shared
        // Key presence decides, never the macOS version. bfF0 takes
        // precedence (older macOS can carry newer firmware).
        if smc.readRaw("bfF0") != nil, smc.readRaw("bfD0") != nil, smc.readRaw("bfE0") != nil {
            mode = .firmware
        } else if smc.readRaw("CHTE") != nil {
            mode = .tahoeGate
        } else if smc.readRaw("CH0B") != nil, smc.readRaw("CH0C") != nil {
            mode = .legacyGate
        } else {
            mode = .unsupported
        }
        dischargeKey = ["CHIE", "CH0J", "CH0I"].first { smc.readRaw($0) != nil }
        ledSupported = smc.readRaw("ACLC") != nil
        publishStatus(nil)
    }

    private func startTimerLocked() {
        guard timer == nil, mode != .unsupported else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + tickPeriod, repeating: tickPeriod)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    // MARK: main loop

    private func tick() {
        // Runs on `queue`; the timer is cancelled synchronously in stop().
        let now = Date()

        // Missed-tick guard (gate modes only): if we slept through >3 periods
        // with charging left ENABLED, inhibit immediately and let the next
        // clean tick re-decide — prevents overcharge during undetected sleep.
        // Firmware mode doesn't need this: the firmware enforces the band in sleep.
        if config.enabled, mode == .tahoeGate || mode == .legacyGate,
           let last = lastTickAt, now.timeIntervalSince(last) > tickPeriod * 3, gateOpen {
            _ = writeGate(allowCharging: false)
        }
        lastTickAt = now

        // Sensor reads — NEVER silently no-op on failure.
        guard let battery = BatteryReader.read() else {
            registerFailure("battery read failed (ioreg)")
            return
        }
        if mode == .firmware, SMC.shared.readRaw("bfF0") == nil {
            registerFailure("SMC bfF0 read failed")
            return
        }
        consecutiveFailures = 0
        if failsafe {
            failsafe = false
            lastError = nil
            if config.enabled { phase = .maintain }
        }

        // Self-healing: if a previous adapter re-enable write failed, the
        // "will retry" promise is honored HERE — every tick re-attempts until
        // the hardware agrees. Never rely on a one-shot undo for safe state.
        var dischargingPhase = false
        if case .discharge = phase { dischargingPhase = true }
        if case .calibration(step: .dischargeToLow) = phase { dischargingPhase = true }
        if adapterDisabled, !dischargingPhase, let key = dischargeKey,
           HelperWhitelist.validateWrite(key: key, bytes: [0x00]) {
            if SMC.shared.writeUInt8(key, 0x00) == kIOReturnSuccess {
                adapterDisabled = false
                lastError = nil
            } else {
                lastError = "failed to re-enable adapter (\(key)) — retrying every tick"
            }
        }

        if config.enabled || phase.isOneShot {
            switch phase {
            case .idle:
                break
            case .maintain:
                maintainTick(battery)
            case .topUp:
                topUpTick(battery)
            case .discharge(let target):
                dischargeTick(battery, target: target)
            case .calibration(let step):
                calibrationTick(battery, step: step)
            }
        }

        updateLED(battery)
        publishStatus(battery)
    }

    private func registerFailure(_ message: String) {
        consecutiveFailures += 1
        if consecutiveFailures >= maxFailures {
            // No latch: restoreSafeState() is idempotent, and its own writes
            // can fail during an SMC outage — keep re-attempting every failure
            // tick so a failed restore can never stick.
            restoreSafeState()
            failsafe = true
            lastError = "\(message) — failsafe active (safe state restored, retrying)"
        } else {
            lastError = "\(message) (\(consecutiveFailures)/\(maxFailures))"
        }
        publishStatus(nil)
        // Timer keeps running: the loop retries and recovers on any success.
    }

    // MARK: maintain (normal limit enforcement)

    private func maintainTick(_ b: BatteryInfo) {
        // Heat protection (suspended during one-shot phases by design).
        if config.heatProtect.enabled {
            if let t = SMC.shared.getValue("TB0T") {
                let now = Date()
                if !heatPaused, t >= config.heatProtect.thresholdC {
                    heatPaused = true
                    lastHeatFlip = now
                } else if heatPaused, t < config.heatProtect.thresholdC - 2,
                          now.timeIntervalSince(lastHeatFlip) >= 300 {
                    heatPaused = false
                    lastHeatFlip = now
                }
            }
            // A TB0T read failure leaves the pause state unchanged — heat
            // protection is auxiliary; the battery/band failsafe still guards
            // the loop itself.
        } else {
            heatPaused = false
        }

        if heatPaused {
            pauseCharging(b)
            return
        }

        // Automatic Discharge: drift >3% above the limit → discharge back down.
        if suppressAutoDischarge, b.currentChargePercent <= config.limitPercent {
            suppressAutoDischarge = false
        }
        if config.autoDischarge, !suppressAutoDischarge, dischargeKey != nil, b.isPluggedIn,
           b.currentChargePercent > config.limitPercent + 3, config.limitPercent < 100 {
            phase = .discharge(target: config.limitPercent)
            return
        }

        reconcile(b)
    }

    /// Firmware mode: reconcile, don't toggle — rewrite the band only when the
    /// read-back differs from desired. Gate modes: classic software hysteresis.
    private func reconcile(_ b: BatteryInfo) {
        switch mode {
        case .firmware:
            guard config.enabled, config.limitPercent < 100 else {
                deactivateBand()
                return
            }
            let band = ChargeConfig.band(limitPercent: config.limitPercent,
                                         sailingDelta: config.sailingDelta)
            let smc = SMC.shared
            let active = (smc.readRaw("bfF0")?.bytes.first ?? 0) == 0x02
            let curUpper = smc.readUInt32LE("bfD0")
            let curLower = smc.readUInt32LE("bfE0")
            if !active || curUpper != band.upper || curLower != band.lower {
                _ = writeBand(upper: band.upper, lower: band.lower)
            }
        case .tahoeGate, .legacyGate:
            guard config.enabled, config.limitPercent < 100 else {
                _ = writeGate(allowCharging: true)
                return
            }
            // sailingDelta ≥ 2 (sanitized) → there is ALWAYS a hysteresis band;
            // never enable and disable at the same threshold.
            let pct = b.currentChargePercent
            if pct >= config.limitPercent {
                _ = writeGate(allowCharging: false)
            } else if pct < config.limitPercent - config.sailingDelta {
                _ = writeGate(allowCharging: true)
            }
            // in between: leave as-is
        case .unsupported:
            break
        }
    }

    /// Pause charging for heat protection.
    /// Firmware mode note: the spec text says "bfF0 ← 0x00", but deactivating
    /// the band REMOVES the cap (the battery would charge to 100% while hot).
    /// To actually pause, we cap the band at the current percentage instead;
    /// resume rewrites the configured band (per spec).
    private func pauseCharging(_ b: BatteryInfo) {
        switch mode {
        case .firmware:
            let upper = UInt32(max(10, min(min(config.limitPercent, b.currentChargePercent), 100)))
            let lower = UInt32(max(10, Int(upper) - config.sailingDelta))
            let smc = SMC.shared
            let active = (smc.readRaw("bfF0")?.bytes.first ?? 0) == 0x02
            let curUpper = smc.readUInt32LE("bfD0") ?? 0
            // Only tighten (never chase the percent downward as firmware sails).
            if !active || curUpper > upper {
                _ = writeBand(upper: upper, lower: lower)
            }
        case .tahoeGate, .legacyGate:
            _ = writeGate(allowCharging: false)
        case .unsupported:
            break
        }
    }

    // MARK: one-shot phase ticks

    private func topUpTick(_ b: BatteryInfo) {
        // Unplugging cancels a top-up (AlDente behavior).
        guard b.isPluggedIn else { endPhase(); return }
        switch mode {
        case .firmware:
            deactivateBand()
        case .tahoeGate, .legacyGate:
            _ = writeGate(allowCharging: true)
        case .unsupported:
            endPhase()
            return
        }
        if b.currentChargePercent >= 99 {
            suppressAutoDischarge = true   // don't let auto-discharge undo the top-up
            endPhase()
        }
    }

    private func dischargeTick(_ b: BatteryInfo, target: Int) {
        guard dischargeKey != nil else { endPhase(); return }
        // Note: with the adapter input disabled, ExternalConnected reads false,
        // so target percent is the primary exit condition.
        if b.currentChargePercent <= target {
            endPhase()
            return
        }
        if !adapterDisabled {
            // Don't START a discharge unplugged.
            guard b.isPluggedIn else { endPhase(); return }
            startAdapterOff()
        }
    }

    private func calibrationTick(_ b: BatteryInfo, step: CalibrationStep) {
        // Heat protection and sailing are suspended during calibration (spec).
        switch step {
        case .chargeToFull:
            guard b.isPluggedIn else { endPhase(); return }
            if mode == .firmware { deactivateBand() } else { _ = writeGate(allowCharging: true) }
            if b.currentChargePercent >= 99 {
                phase = .calibration(step: .holdAtFull)
                holdStart = Date()
            }
        case .holdAtFull:
            guard b.isPluggedIn else { endPhase(); return }
            if let s = holdStart, Date().timeIntervalSince(s) >= 3600 {
                holdStart = nil
                phase = .calibration(step: .dischargeToLow)
            }
        case .dischargeToLow:
            guard dischargeKey != nil else { endPhase(); return }
            if b.currentChargePercent <= 15 {
                abortPhaseSideEffects()   // adapter back on, assertion released
                phase = .calibration(step: .rechargeToFull)
                return
            }
            if !adapterDisabled { startAdapterOff() }
        case .rechargeToFull:
            guard b.isPluggedIn else { endPhase(); return }
            if mode == .firmware { deactivateBand() } else { _ = writeGate(allowCharging: true) }
            if b.currentChargePercent >= 99 {
                phase = .calibration(step: .finalHold)
                holdStart = Date()
            }
        case .finalHold:
            guard b.isPluggedIn else { endPhase(); return }
            if let s = holdStart, Date().timeIntervalSince(s) >= 3600 {
                endPhase()   // restores the band via the next maintain tick
            }
        }
    }

    /// Leave any one-shot phase: undo its side effects and return to
    /// maintain (or idle when control is disabled). The next tick reconciles
    /// the band/gate back to the configured limit.
    private func endPhase() {
        abortPhaseSideEffects()
        phase = config.enabled ? .maintain : .idle
    }

    /// Undo one-shot side effects: adapter back on, sleep assertion released.
    private func abortPhaseSideEffects() {
        if adapterDisabled, let key = dischargeKey {
            if HelperWhitelist.validateWrite(key: key, bytes: [0x00]) {
                if SMC.shared.writeUInt8(key, 0x00) == kIOReturnSuccess {
                    adapterDisabled = false
                } else {
                    lastError = "failed to re-enable adapter (\(key)) — will retry"
                }
            }
        } else {
            adapterDisabled = false
        }
        releaseSleepAssertion()
        holdStart = nil
    }

    /// Disable the AC adapter input (discharge) + prevent idle sleep while
    /// discharging (AlDente likewise disables sleep during discharge).
    private func startAdapterOff() {
        guard let key = dischargeKey else { return }
        let off: UInt8 = (key == "CHIE") ? 0x08 : 0x01
        guard HelperWhitelist.validateWrite(key: key, bytes: [off]) else {
            lastError = "refused: \(key) discharge value not whitelisted"
            endPhase()
            return
        }
        if SMC.shared.writeUInt8(key, off) == kIOReturnSuccess {
            adapterDisabled = true
            takeSleepAssertion()
        } else {
            lastError = "SMC \(key) write failed — discharge aborted"
            endPhase()
        }
    }

    // MARK: SMC write primitives (every write validated at THIS call site)

    /// Strict firmware-required order: deactivate → upper → lower → activate,
    /// then verify the read-back LE-decodes to exactly the percents written
    /// (runtime guard against any residual encoding doubt).
    @discardableResult
    private func writeBand(upper: UInt32, lower: UInt32) -> Bool {
        let smc = SMC.shared
        let upperBytes = ChargeConfig.leBytes(upper)
        let lowerBytes = ChargeConfig.leBytes(lower)
        guard HelperWhitelist.validateWrite(key: "bfF0", bytes: [0x00]),
              HelperWhitelist.validateWriteBytes(key: "bfD0", bytes: upperBytes),
              HelperWhitelist.validateWriteBytes(key: "bfE0", bytes: lowerBytes),
              HelperWhitelist.validateWrite(key: "bfF0", bytes: [0x02]),
              lower <= upper else {
            lastError = "refused: band \(upper)/\(lower) outside whitelist bounds"
            return false
        }
        guard smc.writeUInt8("bfF0", 0x00) == kIOReturnSuccess,
              smc.writeBytes("bfD0", upperBytes) == kIOReturnSuccess,
              smc.writeBytes("bfE0", lowerBytes) == kIOReturnSuccess,
              smc.writeUInt8("bfF0", 0x02) == kIOReturnSuccess else {
            lastError = "SMC band write failed"
            return false
        }
        guard smc.readUInt32LE("bfD0") == upper, smc.readUInt32LE("bfE0") == lower else {
            lastError = "band read-back mismatch (\(upper)/\(lower)) — deactivated"
            _ = smc.writeUInt8("bfF0", 0x00)   // validated above
            return false
        }
        ChargeLoopEngine.setBandOwned(true)
        lastError = nil
        return true
    }

    /// Deactivate the firmware limit (bfF0 ← 0x00). Idempotent.
    /// ONLY releases a band Rebes itself wrote — the native macOS Charge
    /// Limit shares these keys, and a foreign band must be left alone.
    private func deactivateBand() {
        guard mode == .firmware, ChargeLoopEngine.bandOwned() else { return }
        let current = SMC.shared.readRaw("bfF0")?.bytes.first ?? 0
        if current == 0x00 {
            ChargeLoopEngine.setBandOwned(false)
            return
        }
        if HelperWhitelist.validateWrite(key: "bfF0", bytes: [0x00]) {
            if SMC.shared.writeUInt8("bfF0", 0x00) == kIOReturnSuccess {
                ChargeLoopEngine.setBandOwned(false)
            } else {
                lastError = "SMC bfF0 deactivate failed"
            }
        }
    }

    /// Gate modes: open/close the charging gate. Legacy mode always writes
    /// BOTH CH0B and CH0C (CH0B alone can re-trigger charging during sleep).
    @discardableResult
    private func writeGate(allowCharging: Bool) -> Bool {
        let smc = SMC.shared
        switch mode {
        case .tahoeGate:
            let bytes: [UInt8] = allowCharging ? [0, 0, 0, 0] : [1, 0, 0, 0]
            guard HelperWhitelist.validateWriteBytes(key: "CHTE", bytes: bytes) else { return false }
            guard smc.writeBytes("CHTE", bytes) == kIOReturnSuccess else {
                lastError = "SMC CHTE write failed"
                return false
            }
        case .legacyGate:
            let v: UInt8 = allowCharging ? 0x00 : 0x02
            guard HelperWhitelist.validateWrite(key: "CH0B", bytes: [v]),
                  HelperWhitelist.validateWrite(key: "CH0C", bytes: [v]) else { return false }
            let r1 = smc.writeUInt8("CH0B", v)
            let r2 = smc.writeUInt8("CH0C", v)
            guard r1 == kIOReturnSuccess, r2 == kIOReturnSuccess else {
                lastError = "SMC CH0B/CH0C write failed"
                return false
            }
        case .firmware, .unsupported:
            return false
        }
        gateOpen = allowCharging
        return true
    }

    // MARK: MagSafe LED (cosmetic — never a failure path)

    private func updateLED(_ b: BatteryInfo) {
        guard ledSupported else { return }
        var desired: UInt8 = 0x00
        if config.enabled {
            switch config.ledMode {
            case .system:
                desired = 0x00
            case .off:
                desired = 0x01
            case .greenAtLimit:
                desired = (b.currentChargePercent >= config.limitPercent && !b.isCharging) ? 0x03 : 0x00
            case .orangeCharging:
                var discharging = false
                if case .discharge = phase { discharging = true }
                if case .calibration(step: .dischargeToLow) = phase { discharging = true }
                desired = (b.isCharging || discharging) ? 0x04 : 0x00
            }
        }
        // Never touch ACLC until the user opts out of system control.
        if ledWritten == nil && desired == 0x00 { return }
        if ledWritten == desired { return }
        guard HelperWhitelist.validateWrite(key: "ACLC", bytes: [desired]) else { return }
        if SMC.shared.writeUInt8("ACLC", desired) == kIOReturnSuccess {
            ledWritten = desired
        }
    }

    // MARK: safe state

    /// Charge analogue of FanCurveEngine.restoreAutomatic():
    ///   adapter re-enabled, LED back to system, gates opened. The firmware
    ///   band is left in place when persistOnExit is on (the limit surviving
    ///   daemon exit/reboot/sleep is the feature's main advantage), otherwise
    ///   deactivated.
    private func restoreSafeState() {
        abortPhaseSideEffects()
        if let lw = ledWritten, lw != 0x00,
           HelperWhitelist.validateWrite(key: "ACLC", bytes: [0x00]) {
            if SMC.shared.writeUInt8("ACLC", 0x00) == kIOReturnSuccess { ledWritten = 0x00 }
        }
        switch mode {
        case .tahoeGate, .legacyGate:
            _ = writeGate(allowCharging: true)
        case .firmware:
            if !config.persistOnExit { deactivateBand() }
        case .unsupported:
            break
        }
        phase = config.enabled ? .maintain : .idle
    }

    // MARK: sleep assertion (root daemon side, discharge only)

    private func takeSleepAssertion() {
        guard sleepAssertion == 0 else { return }
        var id = IOPMAssertionID(0)
        if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                       IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                       "Rebes charge control — discharging" as CFString,
                                       &id) == kIOReturnSuccess {
            sleepAssertion = id
        }
    }

    private func releaseSleepAssertion() {
        if sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }

    // MARK: status snapshot

    private func publishStatus(_ b: BatteryInfo?) {
        var st = ChargeStatus(helperVersion: ChargeLoopEngine.helperVersion)
        st.mode = mode
        st.dischargeSupported = dischargeKey != nil
        st.ledSupported = ledSupported
        st.phase = phase
        if mode == .firmware {
            let smc = SMC.shared
            st.bandActive = (smc.readRaw("bfF0")?.bytes.first ?? 0) == 0x02
            st.bandUpper = smc.readUInt32LE("bfD0").map(Int.init)
            st.bandLower = smc.readUInt32LE("bfE0").map(Int.init)
        } else if mode == .tahoeGate || mode == .legacyGate {
            st.bandActive = !gateOpen
        }
        if let b {
            st.batteryPercent = b.currentChargePercent
            st.isCharging = b.isCharging
            st.externalConnected = b.isPluggedIn
        } else {
            let prev = currentStatus
            st.batteryPercent = prev.batteryPercent
            st.isCharging = prev.isCharging
            st.externalConnected = prev.externalConnected
        }
        st.heatPaused = heatPaused
        st.failsafe = failsafe
        st.lastError = lastError
        st.config = config
        stateLock.lock()
        _status = st
        stateLock.unlock()
    }
}

final class DaemonDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard connectionIsTrusted(newConnection) else { return false }
        newConnection.exportedInterface = NSXPCInterface(with: RebesHelperProtocol.self)
        newConnection.exportedObject = HelperService()
        newConnection.resume()
        return true
    }
}

/// Retains the signal sources for the process lifetime (final class = safe as a
/// single-writer holder set once during runDaemon).
final class SignalHolder: @unchecked Sendable {
    static let shared = SignalHolder()
    var sources: [DispatchSourceSignal] = []
}

func runDaemon() -> Never {
    // On termination (launchctl bootout / reboot) restore fans to automatic so
    // they never stay forced. Use a DISPATCH signal source, not a C handler —
    // the handler runs on a normal queue where SMC/dispatch calls are safe
    // (a C signal handler making those calls is async-signal-unsafe).
    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)   // ignore default disposition; dispatch source handles it
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        src.setEventHandler {
            FanCurveEngine.shared.stop()     // restores automatic fan control
            ChargeLoopEngine.shared.stop()   // adapter on, LED system, gates open / band per persistOnExit
            exit(0)
        }
        src.resume()
        SignalHolder.shared.sources.append(src)
    }

    // Re-arm charge control from the persisted config so the loop survives
    // reboots and daemon restarts.
    ChargeLoopEngine.shared.bootstrap()

    let delegate = DaemonDelegate()
    let listener = NSXPCListener(machServiceName: kHelperMachServiceName)
    listener.delegate = delegate
    listener.resume()
    RunLoop.main.run()
    exit(0)
}
