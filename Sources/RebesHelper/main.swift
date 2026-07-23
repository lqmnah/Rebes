//
//  main.swift
//  RebesHelper
//
//  Privileged helper CLI — the ONLY component of Rebes! allowed to write
//  to the SMC. Every write is validated against HelperWhitelist first.
//
//  Usage:
//    RebesHelper [--dry-run] chwa get
//    RebesHelper [--dry-run] chwa set <0|1>
//    RebesHelper [--dry-run] fan auto <idx>
//    RebesHelper [--dry-run] fan set <idx> <rpm>
//    RebesHelper probe                            (read-only diagnostics)
//    RebesHelper charge probe                     (read-only charge-key dump)
//    RebesHelper [--dry-run] charge set-config <base64-json>
//    RebesHelper [--dry-run] charge off           (deactivate firmware limit)
//
//  Exit codes: 0 = OK, 2 = refused/invalid usage, 3 = SMC failure.
//

import Foundation
import RebesCore

func fail(_ message: String, code: Int32) -> Never {
    print(message)
    exit(code)
}

/// The CLI must never write charge keys while the daemon's engine owns them —
/// two writers can interleave with the strict 4-write band sequence and the
/// daemon would silently revert a CLI change within one reconcile tick anyway.
func refuseIfDaemonRunning() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["print", "system/com.lqmnah.rebes.helper"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    // Fail CLOSED: if we can't determine daemon state, refuse to write charge
    // keys rather than risk two writers on the strict band sequence.
    guard (try? p.run()) != nil else {
        fail("could not determine daemon state — refusing to write charge keys", code: 2)
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    if p.terminationStatus == 0, text.contains("pid = ") {
        fail("the Rebes helper daemon is running — change charge settings in the Rebes app, or stop it first: sudo launchctl bootout system/com.lqmnah.rebes.helper", code: 2)
    }
}

func hexBytes(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}

/// Read-only dump of every charge-related key (probe order matters for docs).
func printChargeKeys() {
    for key in ["CHWA", "CH0B", "CH0C", "CHTE", "bfF0", "bfD0", "bfE0", "CHIE", "CH0J", "CH0I", "ACLC"] {
        if let raw = SMC.shared.readRaw(key) {
            print("\(key): present, type=\(raw.type), size=\(raw.bytes.count), bytes=[\(hexBytes(raw.bytes))]")
        } else {
            print("\(key): not supported")
        }
    }
}

func fanBounds(_ idx: Int) -> (min: Float, max: Float)? {
    // Mn may legitimately be 0 rpm; Mx of 0 would make the range meaningless.
    guard let mn = SMC.shared.getValueAllowingZero("F\(idx)Mn"),
          let mx = SMC.shared.getValue("F\(idx)Mx"),
          mx > mn else { return nil }
    return (Float(mn), Float(mx))
}

var args = Array(CommandLine.arguments.dropFirst())
var dryRun = false
if args.first == "--dry-run" {
    dryRun = true
    args.removeFirst()
}

guard !args.isEmpty else { fail("usage: chwa|fan|charge|probe (see header)", code: 2) }

let smc = SMC.shared
if !smc.isConnected() {
    fail("SMC not connected", code: 3)
}

switch args[0] {
case "daemon":
    // XPC daemon mode (launched by launchd as root).
    runDaemon()

case "probe":
    // Read-only diagnostics; never writes.
    let fNum = Int(smc.getValue("FNum") ?? 0)
    print("FNum: \(fNum)")
    for i in 0..<fNum {
        let ac = smc.getValueAllowingZero("F\(i)Ac").map { String(format: "%.0f", $0) } ?? "—"
        let mn = smc.getValueAllowingZero("F\(i)Mn").map { String(format: "%.0f", $0) } ?? "—"
        let mx = smc.getValue("F\(i)Mx").map { String(format: "%.0f", $0) } ?? "—"
        let tg = smc.getValueAllowingZero("F\(i)Tg").map { String(format: "%.0f", $0) } ?? "—"
        let md = smc.getValueAllowingZero(smc.fanModeKey(i)).map { String(format: "%.0f", $0) } ?? "—"
        print("Fan\(i): Ac=\(ac) Mn=\(mn) Mx=\(mx) Tg=\(tg) Md=\(md) (modeKey=\(smc.fanModeKey(i)))")
    }
    for key in ["Tp01", "Tp05", "TB0T", "Ts00", "Tg05"] {
        if let v = smc.getValue(key) {
            print("\(key): \(String(format: "%.1f", v))")
        } else {
            print("\(key): —")
        }
    }
    // Power telemetry (PSTR=system total, PDTR=DC input, PPBR=battery).
    // Zero is legitimate here (e.g. PDTR on battery) — only absence prints "—".
    for key in ["PSTR", "PDTR", "PPBR"] {
        if let v = smc.getValueAllowingZero(key) {
            print("\(key): \(String(format: "%.2f", v)) W")
        } else {
            print("\(key): —")
        }
    }
    printChargeKeys()
    exit(0)

case "charge":
    guard args.count >= 2 else { fail("usage: charge probe|set-config <base64-json>|off", code: 2) }
    switch args[1] {
    case "probe":
        // Read-only diagnostics; never writes.
        printChargeKeys()
        exit(0)

    case "off":
        // Deactivate the firmware charge limit (bfF0 ← 0x00).
        refuseIfDaemonRunning()
        guard smc.readRaw("bfF0") != nil else { fail("bfF0: not supported on this firmware", code: 2) }
        guard HelperWhitelist.validateWrite(key: "bfF0", bytes: [0x00]) else {
            fail("refused: bfF0 value not whitelisted", code: 2)
        }
        if dryRun {
            print("DRY-RUN: write bfF0 = 0x00 (deactivate firmware charge limit)")
            exit(0)
        }
        // Only release a band Rebes wrote — never the user's native
        // System Settings limit (same keys).
        if ChargeLoopEngine.bandOwned() {
            guard smc.writeUInt8("bfF0", 0x00) == kIOReturnSuccess else {
                fail("SMC write bfF0 failed", code: 3)
            }
            ChargeLoopEngine.setBandOwned(false)
        }
        // Record "off" so a daemon (re)start doesn't re-arm the band.
        if var persisted = ChargeLoopEngine.loadPersistedConfig() {
            persisted.enabled = false
            ChargeLoopEngine.persist(persisted)
        }
        print("OK")
        exit(0)

    case "set-config":
        // No-daemon fallback: apply the band ONCE from a base64 ChargeConfig.
        // (The reconcile loop, phases and heat protection need the daemon.)
        refuseIfDaemonRunning()
        guard args.count == 3,
              let jsonData = Data(base64Encoded: args[2]),
              let rawConfig = try? JSONDecoder().decode(ChargeConfig.self, from: jsonData) else {
            fail("usage: charge set-config <base64-json ChargeConfig>", code: 2)
        }
        let config = rawConfig.sanitized()
        guard smc.readRaw("bfF0") != nil, smc.readRaw("bfD0") != nil, smc.readRaw("bfE0") != nil else {
            fail("firmware charge-limit keys (bfF0/bfD0/bfE0) not supported on this machine", code: 2)
        }
        if !config.enabled || config.limitPercent >= 100 {
            guard HelperWhitelist.validateWrite(key: "bfF0", bytes: [0x00]) else {
                fail("refused: bfF0 value not whitelisted", code: 2)
            }
            if dryRun {
                print("DRY-RUN: write bfF0 = 0x00 (limit off)")
                exit(0)
            }
            // Only release a band Rebes wrote (never the native macOS limit).
            if ChargeLoopEngine.bandOwned() {
                guard smc.writeUInt8("bfF0", 0x00) == kIOReturnSuccess else {
                    fail("SMC write bfF0 failed", code: 3)
                }
                ChargeLoopEngine.setBandOwned(false)
            }
            ChargeLoopEngine.persist(config)
            print("OK (limit off)")
            exit(0)
        }
        let band = ChargeConfig.band(limitPercent: config.limitPercent, sailingDelta: config.sailingDelta)
        let upperBytes = ChargeConfig.leBytes(band.upper)
        let lowerBytes = ChargeConfig.leBytes(band.lower)
        // Whitelist-validate at THIS call site too (both-call-sites convention).
        guard HelperWhitelist.validateWrite(key: "bfF0", bytes: [0x00]),
              HelperWhitelist.validateWriteBytes(key: "bfD0", bytes: upperBytes),
              HelperWhitelist.validateWriteBytes(key: "bfE0", bytes: lowerBytes),
              HelperWhitelist.validateWrite(key: "bfF0", bytes: [0x02]) else {
            fail("refused: band \(band.upper)/\(band.lower) outside whitelist bounds", code: 2)
        }
        if dryRun {
            print("DRY-RUN: bfF0=0x00 → bfD0=\(band.upper) → bfE0=\(band.lower) → bfF0=0x02 (LE)")
            exit(0)
        }
        // Strict firmware-required order: deactivate → upper → lower → activate.
        guard smc.writeUInt8("bfF0", 0x00) == kIOReturnSuccess,
              smc.writeBytes("bfD0", upperBytes) == kIOReturnSuccess,
              smc.writeBytes("bfE0", lowerBytes) == kIOReturnSuccess,
              smc.writeUInt8("bfF0", 0x02) == kIOReturnSuccess else {
            fail("SMC band write failed", code: 3)
        }
        // Read-back guard: the values must LE-decode to exactly what we wrote.
        guard smc.readUInt32LE("bfD0") == band.upper, smc.readUInt32LE("bfE0") == band.lower else {
            _ = smc.writeUInt8("bfF0", 0x00)   // validated above
            fail("band read-back mismatch — limit deactivated", code: 3)
        }
        ChargeLoopEngine.setBandOwned(true)
        ChargeLoopEngine.persist(config)
        print("OK (band \(band.upper)/\(band.lower) active)")
        exit(0)

    default:
        fail("usage: charge probe|set-config <base64-json>|off", code: 2)
    }

case "chwa":
    guard args.count >= 2 else { fail("usage: chwa get|set <0|1>", code: 2) }
    if args[1] == "get" {
        guard let raw = smc.readRaw("CHWA") else { fail("CHWA: not supported", code: 2) }
        print(raw.bytes.first ?? 0)
        exit(0)
    }
    guard args.count == 3, args[1] == "set", let value = UInt8(args[2]) else {
        fail("usage: chwa set <0|1>", code: 2)
    }
    guard HelperWhitelist.validateWrite(key: "CHWA", bytes: [value]) else {
        fail("refused: CHWA value must be 0 or 1", code: 2)
    }
    if dryRun {
        print("DRY-RUN: write CHWA = \(value)")
        exit(0)
    }
    let result = smc.writeUInt8("CHWA", value)
    if result != kIOReturnSuccess {
        fail("SMC write CHWA failed (\(result))", code: 3)
    }
    print("OK")
    exit(0)

case "fan":
    guard args.count >= 3, let idx = Int(args[2]) else { fail("usage: fan auto|set <idx> [rpm]", code: 2) }
    let fNum = Int(smc.getValue("FNum") ?? 0)
    guard idx >= 0, idx < fNum else { fail("refused: fan index \(idx) out of range (FNum=\(fNum))", code: 2) }

    if args[1] == "auto" {
        if dryRun {
            print("DRY-RUN: set fan \(idx) mode to automatic (+ relock when all fans auto)")
            exit(0)
        }
        guard smc.setFanMode(idx, mode: .automatic) else {
            fail("SMC: failed to restore automatic mode for fan \(idx)", code: 3)
        }
        #if arch(arm64)
        // When every fan is back on automatic, hand control back to
        // thermalmonitord (relock Ftst on M1–M4).
        let allAuto = (0..<fNum).allSatisfy {
            Int(smc.getValueAllowingZero(smc.fanModeKey($0)) ?? 1) == 0
        }
        if allAuto && !smc.resetFanControl() {
            fail("SMC: fan \(idx) is automatic but relocking fan control failed", code: 3)
        }
        #endif
        print("OK")
        exit(0)
    }

    guard args.count == 4, args[1] == "set", let rpm = Float(args[3]), rpm.isFinite else {
        fail("usage: fan set <idx> <rpm>", code: 2)
    }
    guard HelperWhitelist.validateFanTarget(key: "F\(idx)Tg", target: rpm, fNum: fNum, getBounds: fanBounds) else {
        fail("refused: rpm \(rpm) outside hardware bounds for fan \(idx)", code: 2)
    }
    if dryRun {
        print("DRY-RUN: set fan \(idx) target to \(Int(rpm)) rpm (forced mode)")
        exit(0)
    }
    guard smc.setFanSpeed(idx, speed: Int(rpm)) else {
        fail("SMC: failed to set fan \(idx) target", code: 3)
    }
    print("OK")
    exit(0)

default:
    fail("unknown command: \(args[0])", code: 2)
}
