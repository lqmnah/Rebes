import Foundation
import RebesCore

func assertAllowed(_ path: String, _ expected: Bool, line: Int = #line) {
    let cleaner = SafeCleaner.shared
    let actual = cleaner.isAllowed(path: path)
    if actual != expected {
        print("FAIL (line \(line)): expected \(expected) for \(path), got \(actual)")
        exit(1)
    }
}

func assertMatch(_ itemName: String, _ appName: String, _ bundleId: String, _ expected: LeftoverMatchKind, line: Int = #line) {
    let actual = leftoverMatch(itemName: itemName, appName: appName, appBundleId: bundleId)
    if actual != expected {
        print("FAIL (line \(line)): expected \(expected) for \(itemName) / \(appName) / \(bundleId), got \(actual)")
        exit(1)
    }
}

func testSafeCleaner() {
    let home = SafeCleaner.shared.homeDir
    
    assertAllowed(home, false)
    assertAllowed("\(home)/Library", false)
    assertAllowed("/System", false)
    assertAllowed("/Applications", false)
    
    assertAllowed("/System/Library", false)
    
    assertAllowed("/usr/local/bin", false)
    assertAllowed("/tmp/somefile", false)
    
    assertAllowed("\(home)/.ssh", false)
    assertAllowed("\(home)/.ssh/id_rsa", false)
    assertAllowed("\(home)/.gnupg", false)
    assertAllowed("\(home)/.aws", false)
    assertAllowed("\(home)/Library/Keychains", false)
    assertAllowed("\(home)/Library/Keychains/x", false)
    
    assertAllowed("\(home)/Library/Caches", false)
    assertAllowed("\(home)/.cache", false)
    
    assertAllowed("\(home)/Library/Caches/com.apple.Safari", true)
    assertAllowed("\(home)/.cache/somefile", true)
    
    assertAllowed("\(home)/Downloads/file.zip", true)
    assertAllowed("\(home)/Movies/x.mp4", true)
    
    assertAllowed("\(home)/Library/SomeOther/File", false)
    
    assertAllowed("/Applications/Safari.app", true)
    assertAllowed("/Applications/Safari.app/Contents/MacOS", false)
}

func testLeftoversMatcher() {
    // bundleId match — pre-selected
    assertMatch("com.apple.Safari", "Safari", "com.apple.Safari", .bundleId)
    // exact name (with or without extension) — pre-selected
    assertMatch("Numbers", "Numbers", "com.apple.Numbers2", .exactName)
    assertMatch("Numbers.plist", "Numbers", "com.apple.Numbers2", .exactName)
    // substring of ANOTHER app's folder — listed but never pre-selected
    let sub = leftoverMatch(itemName: "Notion Calendar", appName: "Notion", appBundleId: "notion.id")
    if sub != .nameSubstring || sub.preselect {
        print("FAIL: 'Notion Calendar' must be nameSubstring without preselect, got \(sub)")
        exit(1)
    }
    // short generic names never match by name alone
    assertMatch("Mail-cache", "Mail", "com.apple.mail2", .none)
}

func assertBool(_ actual: Bool, _ expected: Bool, line: Int = #line) {
    if actual != expected {
        print("FAIL (line \(line)): expected \(expected), got \(actual)")
        exit(1)
    }
}

func testWhitelistHelper() {
    assertBool(HelperWhitelist.validateWrite(key: "CHWA", bytes: [0]), true)
    assertBool(HelperWhitelist.validateWrite(key: "CHWA", bytes: [1]), true)
    assertBool(HelperWhitelist.validateWrite(key: "CHWA", bytes: [2]), false)
    assertBool(HelperWhitelist.validateWrite(key: "CHWA", bytes: [0, 0]), false)
    assertBool(HelperWhitelist.validateWrite(key: "TC0P", bytes: [1]), false)
    
    let fNum = 2
    let getBounds: (Int) -> (min: Float, max: Float)? = { i in
        if i == 0 { return (1500, 4000) }
        if i == 1 { return (2000, 5000) }
        return nil
    }
    
    assertBool(HelperWhitelist.validateFanTarget(key: "F0Tg", target: 3000, fNum: fNum, getBounds: getBounds), true)
    assertBool(HelperWhitelist.validateFanTarget(key: "F1Tg", target: 5000, fNum: fNum, getBounds: getBounds), true)
    assertBool(HelperWhitelist.validateFanTarget(key: "F2Tg", target: 3000, fNum: fNum, getBounds: getBounds), false)
    // out of bounds, NaN, and infinite targets must all be refused
    assertBool(HelperWhitelist.validateFanTarget(key: "F0Tg", target: 100, fNum: fNum, getBounds: getBounds), false)
    assertBool(HelperWhitelist.validateFanTarget(key: "F0Tg", target: 9999, fNum: fNum, getBounds: getBounds), false)
    assertBool(HelperWhitelist.validateFanTarget(key: "F0Tg", target: Float.nan, fNum: fNum, getBounds: getBounds), false)
    assertBool(HelperWhitelist.validateFanTarget(key: "F0Tg", target: .infinity, fNum: fNum, getBounds: getBounds), false)
}

func testChargeWhitelist() {
    // bfF0 — firmware limit activation flag: 0x00 (off) / 0x02 (on) only
    assertBool(HelperWhitelist.validateWrite(key: "bfF0", bytes: [0x00]), true)
    assertBool(HelperWhitelist.validateWrite(key: "bfF0", bytes: [0x02]), true)
    assertBool(HelperWhitelist.validateWrite(key: "bfF0", bytes: [0x01]), false)
    assertBool(HelperWhitelist.validateWrite(key: "bfF0", bytes: [0x03]), false)
    assertBool(HelperWhitelist.validateWrite(key: "bfF0", bytes: [0x00, 0x00]), false)

    // CHIE — adapter enable/disable: 0x00 / 0x08 only
    assertBool(HelperWhitelist.validateWrite(key: "CHIE", bytes: [0x00]), true)
    assertBool(HelperWhitelist.validateWrite(key: "CHIE", bytes: [0x08]), true)
    assertBool(HelperWhitelist.validateWrite(key: "CHIE", bytes: [0x01]), false)

    // CH0I/CH0J — adapter enable/disable: 0x00 / 0x01 only
    assertBool(HelperWhitelist.validateWrite(key: "CH0J", bytes: [0x00]), true)
    assertBool(HelperWhitelist.validateWrite(key: "CH0J", bytes: [0x01]), true)
    assertBool(HelperWhitelist.validateWrite(key: "CH0J", bytes: [0x02]), false)
    assertBool(HelperWhitelist.validateWrite(key: "CH0I", bytes: [0x01]), true)
    assertBool(HelperWhitelist.validateWrite(key: "CH0I", bytes: [0x08]), false)

    // CH0B/CH0C — legacy gates: 0x00 / 0x02 only
    assertBool(HelperWhitelist.validateWrite(key: "CH0B", bytes: [0x00]), true)
    assertBool(HelperWhitelist.validateWrite(key: "CH0B", bytes: [0x02]), true)
    assertBool(HelperWhitelist.validateWrite(key: "CH0B", bytes: [0x01]), false)
    assertBool(HelperWhitelist.validateWrite(key: "CH0C", bytes: [0x02]), true)

    // ACLC — MagSafe LED: {0, 1, 3, 4} only
    for v in [UInt8(0), 1, 3, 4] {
        assertBool(HelperWhitelist.validateWrite(key: "ACLC", bytes: [v]), true)
    }
    assertBool(HelperWhitelist.validateWrite(key: "ACLC", bytes: [2]), false)
    assertBool(HelperWhitelist.validateWrite(key: "ACLC", bytes: [5]), false)

    // Multi-byte writes must NOT slip through the single-byte validator…
    assertBool(HelperWhitelist.validateWrite(key: "bfD0", bytes: [80]), false)
    assertBool(HelperWhitelist.validateWrite(key: "CHTE", bytes: [0]), false)
    // …and unknown keys must never pass either validator.
    assertBool(HelperWhitelist.validateWrite(key: "CHLS", bytes: [0]), false)
    assertBool(HelperWhitelist.validateWriteBytes(key: "CHWA", bytes: [1, 0, 0, 0]), false)
    assertBool(HelperWhitelist.validateWriteBytes(key: "TC0P", bytes: [0, 0, 0, 0]), false)

    // bfD0/bfE0 — exactly 4 bytes, LITTLE-ENDIAN decode in 10...100
    assertBool(HelperWhitelist.validateWriteBytes(key: "bfD0", bytes: [10, 0, 0, 0]), true)     // 10 = floor
    assertBool(HelperWhitelist.validateWriteBytes(key: "bfD0", bytes: [9, 0, 0, 0]), false)     // below floor
    assertBool(HelperWhitelist.validateWriteBytes(key: "bfD0", bytes: [100, 0, 0, 0]), true)    // 100 = ceiling
    assertBool(HelperWhitelist.validateWriteBytes(key: "bfD0", bytes: [101, 0, 0, 0]), false)   // above ceiling
    assertBool(HelperWhitelist.validateWriteBytes(key: "bfD0", bytes: [0x50, 0, 0, 0]), true)   // 80% (LE 50 00 00 00)
    assertBool(HelperWhitelist.validateWriteBytes(key: "bfD0", bytes: [0, 80, 0, 0]), false)    // 80 in the WRONG byte = 20480
    assertBool(HelperWhitelist.validateWriteBytes(key: "bfD0", bytes: [0, 0, 0, 80]), false)    // big-endian 80 → huge LE value
    assertBool(HelperWhitelist.validateWriteBytes(key: "bfD0", bytes: [80, 0, 0]), false)       // 3 bytes
    assertBool(HelperWhitelist.validateWriteBytes(key: "bfD0", bytes: [80, 0, 0, 0, 0]), false) // 5 bytes
    assertBool(HelperWhitelist.validateWriteBytes(key: "bfE0", bytes: [0x4B, 0, 0, 0]), true)   // 75% lower bound
    assertBool(HelperWhitelist.validateWriteBytes(key: "bfE0", bytes: [0, 1, 0, 0]), false)     // LE 256

    // CHTE — exactly [0,0,0,0] (allow) or [1,0,0,0] (inhibit)
    assertBool(HelperWhitelist.validateWriteBytes(key: "CHTE", bytes: [0, 0, 0, 0]), true)
    assertBool(HelperWhitelist.validateWriteBytes(key: "CHTE", bytes: [1, 0, 0, 0]), true)
    assertBool(HelperWhitelist.validateWriteBytes(key: "CHTE", bytes: [2, 0, 0, 0]), false)
    assertBool(HelperWhitelist.validateWriteBytes(key: "CHTE", bytes: [0, 0, 0, 1]), false)
    assertBool(HelperWhitelist.validateWriteBytes(key: "CHTE", bytes: [1, 0, 0]), false)
}

func testChargeConfigRoundTrip() {
    let cfg = ChargeConfig(enabled: true, limitPercent: 72, sailingDelta: 4,
                           heatProtect: HeatProtect(enabled: true, thresholdC: 36),
                           ledMode: .greenAtLimit, persistOnExit: false,
                           autoDischarge: true, disableSleepUntilLimit: true)
    guard let data = try? JSONEncoder().encode(cfg),
          let back = try? JSONDecoder().decode(ChargeConfig.self, from: data) else {
        print("FAIL: ChargeConfig did not encode/decode")
        exit(1)
    }
    if back != cfg {
        print("FAIL: ChargeConfig JSON round-trip mismatch: \(back) != \(cfg)")
        exit(1)
    }

    // Phase with associated values must round-trip inside ChargeStatus too.
    var status = ChargeStatus(helperVersion: "test")
    status.phase = .calibration(step: .dischargeToLow)
    status.bandUpper = 80
    status.bandLower = 75
    status.config = cfg
    guard let sData = try? JSONEncoder().encode(status),
          let sBack = try? JSONDecoder().decode(ChargeStatus.self, from: sData) else {
        print("FAIL: ChargeStatus did not encode/decode")
        exit(1)
    }
    if sBack.phase != status.phase || sBack.bandUpper != 80 || sBack.config != cfg {
        print("FAIL: ChargeStatus JSON round-trip mismatch")
        exit(1)
    }

    // Defaults per spec: sailing 5, persistOnExit ON, autoDischarge OFF.
    let d = ChargeConfig()
    assertBool(d.enabled, false)
    assertBool(d.limitPercent == 80, true)
    assertBool(d.sailingDelta == 5, true)
    assertBool(d.persistOnExit, true)
    assertBool(d.autoDischarge, false)
    assertBool(d.disableSleepUntilLimit, false)
    assertBool(d.heatProtect.thresholdC == 35, true)
}

func assertBand(_ limit: Int, _ delta: Int, _ expectedUpper: UInt32, _ expectedLower: UInt32, line: Int = #line) {
    let band = ChargeConfig.band(limitPercent: limit, sailingDelta: delta)
    if band.upper != expectedUpper || band.lower != expectedLower {
        print("FAIL (line \(line)): band(\(limit), \(delta)) = \(band), expected (\(expectedUpper), \(expectedLower))")
        exit(1)
    }
}

func testBandComputation() {
    assertBand(80, 5, 80, 75)     // the canonical AlDente default
    assertBand(100, 2, 100, 98)
    assertBand(20, 10, 20, 10)    // lower hits the 10% whitelist floor
    assertBand(20, 5, 20, 15)
    assertBand(15, 5, 20, 15)     // limit clamped up to the 20% UI floor
    assertBand(120, 5, 100, 95)   // limit clamped down to 100
    assertBand(50, 1, 50, 48)     // delta clamped up to 2 → band always exists
    assertBand(50, 0, 50, 48)
    assertBand(50, 99, 50, 40)    // delta clamped down to 10

    // Every computed band must pass the whitelist (upper AND lower).
    for limit in stride(from: 20, through: 100, by: 1) {
        for delta in [2, 5, 10] {
            let band = ChargeConfig.band(limitPercent: limit, sailingDelta: delta)
            assertBool(HelperWhitelist.validateWriteBytes(key: "bfD0", bytes: ChargeConfig.leBytes(band.upper)), true)
            assertBool(HelperWhitelist.validateWriteBytes(key: "bfE0", bytes: ChargeConfig.leBytes(band.lower)), true)
            assertBool(band.lower <= band.upper, true)
            assertBool(band.upper - band.lower >= 2 || band.lower == 10, true)
        }
    }

    // LE encoding: 80% must serialize as 50 00 00 00.
    assertBool(ChargeConfig.leBytes(80) == [0x50, 0x00, 0x00, 0x00], true)
    assertBool(ChargeConfig.leBytes(75) == [0x4B, 0x00, 0x00, 0x00], true)

    // sanitized() clamps everything the whitelist depends on.
    var wild = ChargeConfig()
    wild.limitPercent = 5
    wild.sailingDelta = 50
    wild.heatProtect.thresholdC = 99
    let s = wild.sanitized()
    assertBool(s.limitPercent == 20, true)
    assertBool(s.sailingDelta == 10, true)
    assertBool(s.heatProtect.thresholdC == 40, true)
}

func testDirectorySize() throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    
    defer { try? FileManager.default.removeItem(at: tempDir) }
    
    let f1 = tempDir.appendingPathComponent("f1")
    try "12345".write(to: f1, atomically: true, encoding: .utf8)
    
    let f2 = tempDir.appendingPathComponent("f2")
    try "123".write(to: f2, atomically: true, encoding: .utf8)
    
    let size = SafeCleaner.shared.directorySize(url: tempDir)
    
    if size != 8 {
        print("FAIL: expected directory size 8, got \(size)")
        exit(1)
    }
}

do {
    testSafeCleaner()
    testLeftoversMatcher()
    testWhitelistHelper()
    testChargeWhitelist()
    testChargeConfigRoundTrip()
    testBandComputation()
    try testDirectorySize()
    print("PASS")
    exit(0)
} catch {
    print("FAIL: threw error \(error)")
    exit(1)
}
