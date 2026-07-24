import Foundation
import IOKit

public struct BatteryInfo {
    public var currentChargePercent: Int
    public var isCharging: Bool
    public var cycleCount: Int
    /// Battery health in percent, one decimal (measured FCC / design).
    public var healthPercent: Double
    /// Design cycle count (e.g. 1000); 0 when the firmware doesn't publish it.
    public var designCycleCount: Int = 0
    public var temperatureC: Double
    public var adapterWattage: Int?
    /// Instantaneous battery power in watts (negative = discharging).
    public var watts: Double = 0
    public var voltage: Double = 0
    public var amperage: Double = 0
    // Detailed specs (AlDente-style)
    public var designCapacityMah: Int = 0
    /// Measured full-charge capacity in mAh (the value macOS/AlDente report).
    public var maxCapacityMah: Int = 0
    public var currentCapacityMah: Int = 0
    public var timeRemainingMin: Int = 0     // to empty (discharging) or to full (charging)
    public var isPluggedIn: Bool = false
    public var lowPowerMode: Bool = false
    public var condition: String = "Normal"
    public var adapterDescription: String = ""
    public var adapterVoltage: Double = 0
    public var adapterAmperage: Double = 0
    /// Battery serial number from the ioreg dict ("Serial"); nil when absent.
    public var serialNumber: String? = nil
    /// The gauge's smoothed estimate (NominalChargeCapacity) — reads optimistic.
    public var nominalCapacityMah: Int = 0
    /// Raw measured full-charge capacity; 0 when the firmware doesn't publish it.
    public var fullChargeCapacityMah: Int = 0
    /// True when health had to fall back to the (optimistic) nominal estimate.
    public var healthEstimated: Bool = false
}

public class BatteryReader {
    public static func read() -> BatteryInfo? {
        guard let dict = readBatteryDict() else { return nil }

        let bd = dict["BatteryData"] as? [String: Any]
        let isCharging = dict["IsCharging"] as? Bool ?? false
        let cycleCount = dict["CycleCount"] as? Int ?? 0
        let currentCapacity = dict["CurrentCapacity"] as? Int ?? 0
        let maxCapacity = dict["MaxCapacity"] as? Int ?? 0

        let chargePercent = maxCapacity > 0 ? Int((Double(currentCapacity) / Double(maxCapacity)) * 100) : 0

        let nominal = dict["NominalChargeCapacity"] as? Int ?? bd?["NominalChargeCapacity"] as? Int ?? 0
        let design = dict["DesignCapacity"] as? Int ?? bd?["DesignCapacity"] as? Int ?? 0
        // Health = measured FullChargeCapacity / design — the number macOS
        // System Settings, AlDente and coconutBattery all report.
        // NominalChargeCapacity is the gauge's smoothed estimate and reads
        // optimistic (98% vs the real 95% on the same pack).
        let fcc = dict["AppleRawMaxCapacity"] as? Int ?? bd?["FullChargeCapacity"] as? Int ?? 0
        let healthEstimated = fcc <= 0
        let measured = fcc > 0 ? fcc : nominal
        // One decimal, rounded — matches how macOS/AlDente display health.
        let health = design > 0 && measured > 0
            ? ((Double(measured) / Double(design)) * 1000).rounded() / 10
            : 0

        var tempC: Double = 0
        if let t = dict["Temperature"] as? Int ?? bd?["Temperature"] as? Int {
            tempC = (Double(t) / 100.0) - 273.15
        } else if let t = dict["Temperature"] as? Double {
            tempC = (t / 100.0) - 273.15   // same centi-Kelvin convention as the Int branch
        }

        let adapter = dict["AdapterDetails"] as? [String: Any]

        var wattage: Int? = nil
        if let w = adapter?["Watts"] as? Int { wattage = w }

        // Instantaneous power: Amperage (mA, signed) × Voltage (mV).
        // Prefer InstantAmperage (true instantaneous) over the averaged Amperage.
        let amperage = Double(dict["InstantAmperage"] as? Int ?? dict["Amperage"] as? Int ?? bd?["Amperage"] as? Int ?? 0)  // mA
        let voltage = Double(dict["Voltage"] as? Int ?? 0)                                                                // mV
        let watts = (amperage / 1000.0) * (voltage / 1000.0)                                                              // W (signed)

        // Time remaining: charging → to full, discharging → to empty.
        let toEmpty = dict["TimeRemaining"] as? Int ?? dict["AvgTimeToEmpty"] as? Int ?? 0
        let toFull = dict["AvgTimeToFull"] as? Int ?? 0
        var timeRemaining = isCharging ? toFull : toEmpty
        if timeRemaining >= 65535 { timeRemaining = 0 }   // "calculating"

        var info = BatteryInfo(
            currentChargePercent: chargePercent,
            isCharging: isCharging,
            cycleCount: cycleCount,
            healthPercent: health,
            temperatureC: tempC,
            adapterWattage: wattage,
            watts: watts,
            voltage: voltage / 1000.0,
            amperage: amperage / 1000.0
        )
        info.designCapacityMah = design
        info.maxCapacityMah = measured
        // Raw keys are mAh; CurrentCapacity is a PERCENT — never mix the two.
        info.currentCapacityMah = dict["AppleRawCurrentCapacity"] as? Int ?? bd?["StateOfCharge"] as? Int ?? 0
        info.timeRemainingMin = timeRemaining
        info.isPluggedIn = dict["ExternalConnected"] as? Bool ?? false
        info.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        info.condition = (dict["PermanentFailureStatus"] as? Int ?? 0) == 0 ? "Normal" : "Service"
        info.adapterDescription = adapter?["Description"] as? String ?? adapter?["Name"] as? String ?? ""
        info.adapterVoltage = Double(adapter?["AdapterVoltage"] as? Int ?? 0) / 1000.0
        info.adapterAmperage = Double(adapter?["Current"] as? Int ?? 0) / 1000.0
        info.serialNumber = dict["Serial"] as? String ?? bd?["Serial"] as? String
        info.nominalCapacityMah = nominal
        info.fullChargeCapacityMah = fcc
        info.healthEstimated = healthEstimated
        info.designCycleCount = dict["DesignCycleCount9C"] as? Int ?? bd?["DesignCycleCount9C"] as? Int ?? 0
        return info
    }

    /// Read the AppleSmartBattery property dictionary. Fast path = IOKit
    /// registry direct (no process spawn per poll); fallback = ioreg.
    private static func readBatteryDict() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
               let dict = props?.takeRetainedValue() as? [String: Any] {
                return dict
            }
        }
        return readBatteryDictViaIoreg()
    }

    private static func readBatteryDictViaIoreg() -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-arn", "AppleSmartBattery"]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard let plistList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[String: Any]],
                  let dict = plistList.first else {
                return nil
            }
            return dict
        } catch {
            return nil
        }
    }
}
