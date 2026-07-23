//
//  SMC.swift
//  RebesCore
//
//  Apple SMC (System Management Controller) access layer.
//
//  Adapted from exelban/stats — SMC/smc.swift (MIT License,
//  Copyright © 2021 Serhiy Mytrovtsiy). See docs/THIRD-PARTY.md.
//  Local additions: isConnected(), readRaw(_:), writeUInt8(_:_:).
//

import Foundation
import IOKit

internal enum SMCDataType: String {
    case UI8 = "ui8 "
    case UI16 = "ui16"
    case UI32 = "ui32"
    case SP1E = "sp1e"
    case SP3C = "sp3c"
    case SP4B = "sp4b"
    case SP5A = "sp5a"
    case SPA5 = "spa5"
    case SP69 = "sp69"
    case SP78 = "sp78"
    case SP87 = "sp87"
    case SP96 = "sp96"
    case SPB4 = "spb4"
    case SPF0 = "spf0"
    case FLT = "flt "
    case FPE2 = "fpe2"
    case FP2E = "fp2e"
    case FDS = "{fds"
}

internal enum SMCKeys: UInt8 {
    case kernelIndex = 2
    case readBytes = 5
    case writeBytes = 6
    case readIndex = 8
    case readKeyInfo = 9
    case readPLimit = 11
    case readVers = 12
}

public enum FanMode: Int, Codable {
    case automatic = 0
    case forced = 1
    case auto3 = 3

    public var isAutomatic: Bool {
        self == .automatic || self == .auto3
    }
}

internal struct SMCKeyData_t {
    typealias SMCBytes_t = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8)

    struct vers_t {
        var major: CUnsignedChar = 0
        var minor: CUnsignedChar = 0
        var build: CUnsignedChar = 0
        var reserved: CUnsignedChar = 0
        var release: CUnsignedShort = 0
    }

    struct LimitData_t {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct keyInfo_t {
        var dataSize: IOByteCount32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = vers_t()
    var pLimitData = LimitData_t()
    var keyInfo = keyInfo_t()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes_t = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0))
}

internal struct SMCVal_t {
    var key: String
    var dataSize: UInt32 = 0
    var dataType: String = ""
    var bytes: [UInt8] = Array(repeating: 0, count: 32)

    init(_ key: String) {
        self.key = key
    }
}

extension FourCharCode {
    init(fromString str: String) {
        precondition(str.count == 4)

        self = str.utf8.reduce(0) { sum, character in
            return sum << 8 | UInt32(character)
        }
    }

    func toString() -> String {
        return String(describing: UnicodeScalar(self >> 24 & 0xff)!) +
               String(describing: UnicodeScalar(self >> 16 & 0xff)!) +
               String(describing: UnicodeScalar(self >> 8  & 0xff)!) +
               String(describing: UnicodeScalar(self       & 0xff)!)
    }
}

extension UInt16 {
    init(bytes: (UInt8, UInt8)) {
        self = UInt16(bytes.0) << 8 | UInt16(bytes.1)
    }
}

extension UInt32 {
    init(bytes: (UInt8, UInt8, UInt8, UInt8)) {
        self = UInt32(bytes.0) << 24 | UInt32(bytes.1) << 16 | UInt32(bytes.2) << 8 | UInt32(bytes.3)
    }
}

extension Int {
    init(fromFPE2 bytes: (UInt8, UInt8)) {
        self = (Int(bytes.0) << 6) + (Int(bytes.1) >> 2)
    }
}

extension Float {
    init?(_ bytes: [UInt8]) {
        guard bytes.count >= 4 else { return nil }
        self = bytes.withUnsafeBytes {
            // Unaligned load: Array<UInt8> storage doesn't guarantee 4-byte alignment.
            return $0.loadUnaligned(fromByteOffset: 0, as: Self.self)
        }
    }

    var bytes: [UInt8] {
        withUnsafeBytes(of: self, Array.init)
    }
}

// @unchecked Sendable: all kernel calls funnel through call() under `lock`,
// and _fanModeKeyIsLower is only mutated inside fanModeKey() under the same lock.
public final class SMC: @unchecked Sendable {
    public static let shared = SMC()
    private var conn: io_connect_t = 0
    private var _fanModeKeyIsLower: Bool?
    private let lock = NSRecursiveLock()

    public init() {
        var result: kern_return_t
        var iterator: io_iterator_t = 0
        let device: io_object_t

        let matchingDictionary: CFMutableDictionary = IOServiceMatching("AppleSMC")
        result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary, &iterator)
        if result != kIOReturnSuccess {
            print("Error IOServiceGetMatchingServices(): " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
            return
        }

        device = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        if device == 0 {
            print("Error IOIteratorNext(): no AppleSMC service")
            return
        }

        result = IOServiceOpen(device, mach_task_self_, 0, &conn)
        IOObjectRelease(device)
        if result != kIOReturnSuccess {
            print("Error IOServiceOpen(): " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
            return
        }
    }

    deinit {
        if conn != 0 {
            let result = self.close()
            if result != kIOReturnSuccess {
                print("error close smc connection: " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
            }
        }
    }

    public func close() -> kern_return_t {
        return IOServiceClose(conn)
    }

    public func isConnected() -> Bool {
        return conn != 0
    }

    /// Silent raw read: (dataType, bytes truncated to dataSize), or nil. Safe for key enumeration.
    public func readRaw(_ key: String) -> (type: String, bytes: [UInt8])? {
        guard key.count == 4 else { return nil }
        var val = SMCVal_t(key)
        guard read(&val) == kIOReturnSuccess, val.dataSize > 0 else { return nil }
        return (val.dataType, Array(val.bytes.prefix(Int(val.dataSize))))
    }

    public func getValue(_ key: String) -> Double? {
        guard key.count == 4 else { return nil }   // FourCharCode precondition would trap
        var val: SMCVal_t = SMCVal_t(key)
        guard read(&val) == kIOReturnSuccess, val.dataSize > 0 else { return nil }
        // All-zero payloads usually mean "no sensor" — except keys where 0 is meaningful.
        if val.bytes.first(where: { $0 != 0 }) == nil && val.key != "FS! " && val.key != "F0Md" && val.key != "F1Md" && val.key != "F0md" && val.key != "F1md" {
            return nil
        }
        return decode(val)
    }

    /// Like getValue, but an all-zero payload decodes to 0 instead of nil.
    /// Needed for keys where zero is a legitimate value (e.g. a fan's minimum RPM).
    public func getValueAllowingZero(_ key: String) -> Double? {
        guard key.count == 4 else { return nil }   // FourCharCode precondition would trap
        var val: SMCVal_t = SMCVal_t(key)
        guard read(&val) == kIOReturnSuccess, val.dataSize > 0 else { return nil }
        return decode(val)
    }

    /// Signed 16-bit fixed-point decode (sp78/sp87/sp96/spb4/spf0): sign-extend
    /// before scaling so sub-zero sensors read negative instead of ~255.
    private static func signedFixed(_ hi: UInt8, _ lo: UInt8, _ divisor: Double) -> Double {
        Double(Int16(bitPattern: UInt16(hi) * 256 + UInt16(lo))) / divisor
    }

    private func decode(_ val: SMCVal_t) -> Double? {
        if val.dataSize > 0 {
            switch val.dataType {
            case SMCDataType.UI8.rawValue:
                return Double(val.bytes[0])
            case SMCDataType.UI16.rawValue:
                return Double(UInt16(bytes: (val.bytes[0], val.bytes[1])))
            case SMCDataType.UI32.rawValue:
                return Double(UInt32(bytes: (val.bytes[0], val.bytes[1], val.bytes[2], val.bytes[3])))
            case SMCDataType.SP1E.rawValue:
                return Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1])) / 16384
            case SMCDataType.SP3C.rawValue:
                return Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1])) / 4096
            case SMCDataType.SP4B.rawValue:
                return Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1])) / 2048
            case SMCDataType.SP5A.rawValue:
                return Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1])) / 1024
            case SMCDataType.SP69.rawValue:
                return Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1])) / 512
            case SMCDataType.SP78.rawValue:
                return Self.signedFixed(val.bytes[0], val.bytes[1], 256)
            case SMCDataType.SP87.rawValue:
                return Self.signedFixed(val.bytes[0], val.bytes[1], 128)
            case SMCDataType.SP96.rawValue:
                return Self.signedFixed(val.bytes[0], val.bytes[1], 64)
            case SMCDataType.SPA5.rawValue:
                return Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1])) / 32
            case SMCDataType.SPB4.rawValue:
                return Self.signedFixed(val.bytes[0], val.bytes[1], 16)
            case SMCDataType.SPF0.rawValue:
                return Self.signedFixed(val.bytes[0], val.bytes[1], 1)
            case SMCDataType.FLT.rawValue:
                if let value = Float(val.bytes) {
                    return Double(value)
                }
                return nil
            case SMCDataType.FPE2.rawValue:
                return Double(Int(fromFPE2: (val.bytes[0], val.bytes[1])))
            default:
                return nil
            }
        }

        return nil
    }

    public func getAllKeys() -> [String] {
        var list: [String] = []

        guard let keysNum = self.getValue("#KEY") else {
            return list
        }

        var result: kern_return_t = 0
        var input: SMCKeyData_t = SMCKeyData_t()
        var output: SMCKeyData_t = SMCKeyData_t()

        for i in 0..<Int(keysNum) {
            input = SMCKeyData_t()
            output = SMCKeyData_t()

            input.data8 = SMCKeys.readIndex.rawValue
            input.data32 = UInt32(i)

            result = call(SMCKeys.kernelIndex.rawValue, input: &input, output: &output)
            if result != kIOReturnSuccess {
                continue
            }

            list.append(output.key.toString())
        }

        return list
    }

    /// Write a single-byte (ui8) key, e.g. CHWA. Reads the key first and
    /// refuses if the firmware-reported size is not exactly 1 byte.
    public func writeUInt8(_ key: String, _ newValue: UInt8) -> kern_return_t {
        var val = SMCVal_t(key)
        let readResult = read(&val)
        guard readResult == kIOReturnSuccess else { return readResult }
        guard val.dataSize == 1 else { return kIOReturnBadArgument }
        val.bytes = [UInt8](repeating: 0, count: 32)
        val.bytes[0] = newValue
        #if arch(arm64)
        return writeWithRetry(val) ? kIOReturnSuccess : kIOReturnError
        #else
        return write(val)
        #endif
    }

    /// Write raw bytes to an SMC key. Reads the key first and refuses unless
    /// the firmware-reported dataSize is exactly `bytes.count` — same shape
    /// as writeUInt8, generalized for multi-byte keys (bfD0/bfE0/CHTE).
    public func writeBytes(_ key: String, _ bytes: [UInt8]) -> kern_return_t {
        guard !bytes.isEmpty, bytes.count <= 32 else { return kIOReturnBadArgument }
        var val = SMCVal_t(key)
        let readResult = read(&val)
        guard readResult == kIOReturnSuccess else { return readResult }
        guard Int(val.dataSize) == bytes.count else { return kIOReturnBadArgument }
        val.bytes = [UInt8](repeating: 0, count: 32)
        for (i, b) in bytes.enumerated() { val.bytes[i] = b }
        #if arch(arm64)
        return writeWithRetry(val) ? kIOReturnSuccess : kIOReturnError
        #else
        return write(val)
        #endif
    }

    /// Write a UInt32 encoded little-endian. bfD0/bfE0 store their percent
    /// byte-reversed vs the conventional big-endian SMC ui32 encoding
    /// (batt applies bits.ReverseBytes32 on read and write).
    public func writeUInt32LE(_ key: String, _ value: UInt32) -> kern_return_t {
        writeBytes(key, [UInt8(value & 0xff),
                         UInt8((value >> 8) & 0xff),
                         UInt8((value >> 16) & 0xff),
                         UInt8((value >> 24) & 0xff)])
    }

    /// Read helper mirroring the little-endian decode for bfD0/bfE0.
    public func readUInt32LE(_ key: String) -> UInt32? {
        guard let raw = readRaw(key), raw.bytes.count >= 4 else { return nil }
        return UInt32(raw.bytes[0])
            | UInt32(raw.bytes[1]) << 8
            | UInt32(raw.bytes[2]) << 16
            | UInt32(raw.bytes[3]) << 24
    }

    // MARK: - fans

    public func fanModeKey(_ id: Int) -> String {
        #if arch(arm64)
        lock.lock()
        defer { lock.unlock() }
        if _fanModeKeyIsLower == nil {
            var probe = SMCVal_t("F0md")
            _fanModeKeyIsLower = read(&probe) == kIOReturnSuccess && probe.dataSize > 0
        }
        return _fanModeKeyIsLower! ? "F\(id)md" : "F\(id)Md"
        #else
        return "F\(id)Md"
        #endif
    }

    @discardableResult
    public func setFanMode(_ id: Int, mode: FanMode) -> Bool {
        #if arch(arm64)
        if mode == .forced {
            return unlockFanControl(fanId: id)
        } else {
            let modeKey = fanModeKey(id)
            let targetKey = "F\(id)Tg"

            if self.getValue(modeKey) != nil {
                var modeVal = SMCVal_t(modeKey)
                let readResult = read(&modeVal)
                guard readResult == kIOReturnSuccess else {
                    print(smcError("read", key: modeKey, result: readResult))
                    return false
                }
                if modeVal.bytes[0] != 0 {
                    modeVal.bytes[0] = 0
                    if !writeWithRetry(modeVal) { return false }
                }
            }

            var targetValue = SMCVal_t(targetKey)
            let result = read(&targetValue)
            guard result == kIOReturnSuccess else {
                print(smcError("read", key: targetKey, result: result))
                return false
            }

            let bytes = Float(0).bytes
            targetValue.bytes[0] = bytes[0]
            targetValue.bytes[1] = bytes[1]
            targetValue.bytes[2] = bytes[2]
            targetValue.bytes[3] = bytes[3]

            return writeWithRetry(targetValue)
        }
        #else
        if self.getValue("F\(id)Md") != nil {
            var result: kern_return_t = 0
            var value = SMCVal_t("F\(id)Md")

            result = read(&value)
            if result != kIOReturnSuccess {
                print("Error read fan mode: " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
                return false
            }

            value.bytes = [UInt8(mode.rawValue)] + [UInt8](repeating: 0, count: 31)

            result = write(value)
            if result != kIOReturnSuccess {
                print("Error write: " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
                return false
            }
        }

        let fansMode = Int(self.getValue("FS! ") ?? 0)
        var newMode: UInt8 = 0

        if fansMode == 0 && id == 0 && mode == .forced {
            newMode = 1
        } else if fansMode == 0 && id == 1 && mode == .forced {
            newMode = 2
        } else if fansMode == 1 && id == 0 && mode == .automatic {
            newMode = 0
        } else if fansMode == 1 && id == 1 && mode == .forced {
            newMode = 3
        } else if fansMode == 2 && id == 1 && mode == .automatic {
            newMode = 0
        } else if fansMode == 2 && id == 0 && mode == .forced {
            newMode = 3
        } else if fansMode == 3 && id == 0 && mode == .automatic {
            newMode = 2
        } else if fansMode == 3 && id == 1 && mode == .automatic {
            newMode = 1
        }

        if fansMode == newMode {
            return true
        }

        var result: kern_return_t = 0
        var value = SMCVal_t("FS! ")

        result = read(&value)
        if result != kIOReturnSuccess {
            print("Error read fan mode: " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
            return false
        }

        value.bytes = [0, newMode] + [UInt8](repeating: 0, count: 30)

        result = write(value)
        if result != kIOReturnSuccess {
            print("Error write: " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
            return false
        }
        return true
        #endif
    }

    @discardableResult
    public func setFanSpeed(_ id: Int, speed: Int, shouldAbort: () -> Bool = { false }) -> Bool {
        if let maxSpeed = self.getValue("F\(id)Mx"),
           speed > Int(maxSpeed) {
            return setFanSpeed(id, speed: Int(maxSpeed), shouldAbort: shouldAbort)
        }

        #if arch(arm64)
        var modeVal = SMCVal_t(fanModeKey(id))
        let modeResult = read(&modeVal)
        guard modeResult == kIOReturnSuccess else {
            print(smcError("read", key: fanModeKey(id), result: modeResult))
            return false
        }
        if modeVal.bytes[0] != 1 {
            if !unlockFanControl(fanId: id, shouldAbort: shouldAbort) { return false }
        }
        #endif

        var result: kern_return_t = 0
        var value = SMCVal_t("F\(id)Tg")

        result = read(&value)
        if result != kIOReturnSuccess {
            print(smcError("read", key: value.key, result: result))
            return false
        }

        if value.dataType == SMCDataType.FLT.rawValue {
            let bytes = Float(speed).bytes
            value.bytes[0] = bytes[0]
            value.bytes[1] = bytes[1]
            value.bytes[2] = bytes[2]
            value.bytes[3] = bytes[3]
        } else if value.dataType == SMCDataType.FPE2.rawValue {
            value.bytes[0] = UInt8(speed >> 6)
            value.bytes[1] = UInt8((speed << 2) ^ ((speed >> 6) << 8))
            value.bytes[2] = UInt8(0)
            value.bytes[3] = UInt8(0)
        }

        #if arch(arm64)
        return writeWithRetry(value)
        #else
        result = write(value)
        if result != kIOReturnSuccess {
            print("Error write: " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
            return false
        }
        return true
        #endif
    }

    // MARK: - Apple Silicon fan control

    private func smcError(_ operation: String, key: String, result: kern_return_t) -> String {
        let errorDesc = String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"
        return "[\(key)] \(operation) failed: \(errorDesc) (0x\(String(result, radix: 16)))"
    }

    #if arch(arm64)
    private func writeWithRetry(_ value: SMCVal_t, maxAttempts: Int = 10, delayMicros: UInt32 = 50_000, shouldAbort: () -> Bool = { false }) -> Bool {
        let mutableValue = value
        var lastResult: kern_return_t = kIOReturnSuccess
        for attempt in 0..<maxAttempts {
            if shouldAbort() { return false }   // daemon shutting down — bail fast
            lastResult = write(mutableValue)
            if lastResult == kIOReturnSuccess {
                return true
            }
            if attempt < maxAttempts - 1 {
                usleep(delayMicros)
            }
        }
        print(smcError("write", key: value.key, result: lastResult))
        return false
    }

    private func unlockFanControl(fanId: Int, shouldAbort: () -> Bool = { false }) -> Bool {
        // Try direct mode write first (works on M5+ without Ftst)
        let modeKey = fanModeKey(fanId)
        var modeVal = SMCVal_t(modeKey)
        let modeRead = read(&modeVal)
        guard modeRead == kIOReturnSuccess else {
            print(smcError("read", key: modeKey, result: modeRead))
            return false
        }
        modeVal.bytes[0] = 1
        if write(modeVal) == kIOReturnSuccess {
            return true
        }

        // Direct failed; try Ftst unlock (M1-M4)
        var ftstVal = SMCVal_t("Ftst")
        let ftstResult = read(&ftstVal)
        guard ftstResult == kIOReturnSuccess, ftstVal.dataSize > 0 else {
            return false
        }

        if ftstVal.bytes[0] == 1 {
            return retryModeWrite(fanId: fanId, maxAttempts: 20, shouldAbort: shouldAbort)
        }

        ftstVal.bytes[0] = 1
        if !writeWithRetry(ftstVal, maxAttempts: 100, shouldAbort: shouldAbort) {
            return false
        }

        // Wait for thermalmonitord to yield control — in 100ms slices so a
        // pending daemon shutdown can abort the wait instead of blocking
        // ~3s past launchd's ExitTimeOut.
        for _ in 0..<30 {
            if shouldAbort() { return false }
            usleep(100_000)
        }

        return retryModeWrite(fanId: fanId, maxAttempts: 300, shouldAbort: shouldAbort)
    }

    private func retryModeWrite(fanId: Int, maxAttempts: Int, shouldAbort: () -> Bool = { false }) -> Bool {
        let modeKey = fanModeKey(fanId)
        var modeVal = SMCVal_t(modeKey)
        let result = read(&modeVal)
        guard result == kIOReturnSuccess else {
            print(smcError("read", key: modeKey, result: result))
            return false
        }
        modeVal.bytes[0] = 1
        return writeWithRetry(modeVal, maxAttempts: maxAttempts, delayMicros: 100_000, shouldAbort: shouldAbort)
    }

    public func resetFanControl() -> Bool {
        var value = SMCVal_t("Ftst")
        let result = read(&value)
        if result == kIOReturnSuccess && value.dataSize > 0 {
            if value.bytes[0] == 0 { return true }
            value.bytes[0] = 0
            return writeWithRetry(value)
        }

        // Ftst absent (M5+): reset fan modes directly
        guard let count = getValue("FNum") else { return false }
        var success = true
        for i in 0..<Int(count) {
            let modeKey = fanModeKey(i)
            var modeVal = SMCVal_t(modeKey)
            let readResult = read(&modeVal)
            guard readResult == kIOReturnSuccess else { continue }
            if modeVal.bytes[0] == 0 { continue }
            modeVal.bytes[0] = 0
            if !writeWithRetry(modeVal) { success = false }
        }
        return success
    }
    #endif

    // MARK: - internal

    private func read(_ value: UnsafeMutablePointer<SMCVal_t>) -> kern_return_t {
        var result: kern_return_t = 0
        var input = SMCKeyData_t()
        var output = SMCKeyData_t()

        input.key = FourCharCode(fromString: value.pointee.key)
        input.data8 = SMCKeys.readKeyInfo.rawValue

        result = call(SMCKeys.kernelIndex.rawValue, input: &input, output: &output)
        if result != kIOReturnSuccess {
            return result
        }

        value.pointee.dataSize = UInt32(output.keyInfo.dataSize)
        value.pointee.dataType = output.keyInfo.dataType.toString()
        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.data8 = SMCKeys.readBytes.rawValue

        result = call(SMCKeys.kernelIndex.rawValue, input: &input, output: &output)
        if result != kIOReturnSuccess {
            return result
        }

        memcpy(&value.pointee.bytes, &output.bytes, min(Int(value.pointee.dataSize), value.pointee.bytes.count))

        return kIOReturnSuccess
    }

    private func write(_ value: SMCVal_t) -> kern_return_t {
        var input = SMCKeyData_t()
        var output = SMCKeyData_t()

        input.key = FourCharCode(fromString: value.key)
        input.data8 = SMCKeys.writeBytes.rawValue
        input.keyInfo.dataSize = IOByteCount32(value.dataSize)
        input.bytes = (value.bytes[0], value.bytes[1], value.bytes[2], value.bytes[3], value.bytes[4], value.bytes[5],
                       value.bytes[6], value.bytes[7], value.bytes[8], value.bytes[9], value.bytes[10], value.bytes[11],
                       value.bytes[12], value.bytes[13], value.bytes[14], value.bytes[15], value.bytes[16], value.bytes[17],
                       value.bytes[18], value.bytes[19], value.bytes[20], value.bytes[21], value.bytes[22], value.bytes[23],
                       value.bytes[24], value.bytes[25], value.bytes[26], value.bytes[27], value.bytes[28], value.bytes[29],
                       value.bytes[30], value.bytes[31])

        let result = self.call(SMCKeys.kernelIndex.rawValue, input: &input, output: &output)
        if result != kIOReturnSuccess {
            return result
        }

        // IOKit can return success while SMC firmware still rejects the write.
        if output.result != 0x00 {
            return kIOReturnError
        }

        return kIOReturnSuccess
    }

    private func call(_ index: UInt8, input: inout SMCKeyData_t, output: inout SMCKeyData_t) -> kern_return_t {
        lock.lock()
        defer { lock.unlock() }
        let inputSize = MemoryLayout<SMCKeyData_t>.stride
        var outputSize = MemoryLayout<SMCKeyData_t>.stride

        return IOConnectCallStructMethod(conn, UInt32(index), &input, inputSize, &output, &outputSize)
    }
}
