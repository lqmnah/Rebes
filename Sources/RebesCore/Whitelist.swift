import Foundation

public enum HelperError: Error {
    case invalidUsage
    case invalidKey
    case validationFailed
    case smcError(String)
}

public struct HelperWhitelist {
    /// Single-byte SMC writes. Exhaustive per-key value whitelist — anything
    /// not listed here is refused at BOTH privileged call sites.
    public static func validateWrite(key: String, bytes: [UInt8]) -> Bool {
        guard bytes.count == 1 else { return false }
        let v = bytes[0]
        switch key {
        case "CHWA":         // legacy 80%-cap flag
            return v == 0x00 || v == 0x01
        case "bfF0":         // firmware charge-limit activation flag
            return v == 0x00 || v == 0x02
        case "CHIE":         // adapter enable(0x00)/disable(0x08) — discharge
            return v == 0x00 || v == 0x08
        case "CH0I", "CH0J": // adapter enable(0x00)/disable(0x01) — discharge
            return v == 0x00 || v == 0x01
        case "CH0B", "CH0C": // legacy charging gates: charge(0x00)/inhibit(0x02)
            return v == 0x00 || v == 0x02
        case "ACLC":         // MagSafe LED: system/off/green/orange
            return v == 0x00 || v == 0x01 || v == 0x03 || v == 0x04
        default:
            if key.hasPrefix("F") && key.hasSuffix("Md") && key.count == 4 {
                return v == 0x00 || v == 0x01
            }
            return false
        }
    }

    /// Multi-byte SMC writes (firmware charge band + Tahoe gate).
    /// bfD0/bfE0 must be exactly 4 bytes whose LITTLE-ENDIAN decode is a
    /// percent in 10...100. Everything else is refused.
    public static func validateWriteBytes(key: String, bytes: [UInt8]) -> Bool {
        switch key {
        case "bfD0", "bfE0":
            guard bytes.count == 4 else { return false }
            let v = UInt32(bytes[0])
                | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16
                | UInt32(bytes[3]) << 24
            return v >= 10 && v <= 100
        case "CHTE":
            return bytes == [0, 0, 0, 0] || bytes == [1, 0, 0, 0]
        default:
            return false
        }
    }
    
    public static func validateFanTarget(key: String, target: Float, fNum: Int, getBounds: (Int) -> (min: Float, max: Float)?) -> Bool {
        if key.hasPrefix("F") && key.hasSuffix("Tg") && key.count == 4 {
            let idxChar = key[key.index(key.startIndex, offsetBy: 1)]
            if let idx = idxChar.wholeNumberValue, idx >= 0 && idx < fNum {
                if let bounds = getBounds(idx) {
                    if target >= bounds.min && target <= bounds.max {
                        return true
                    }
                }
            }
        }
        return false
    }
}
