import Foundation

public struct BatteryInfo {
    public var currentChargePercent: Int
    public var isCharging: Bool
    public var cycleCount: Int
    public var healthPercent: Int
    public var temperatureC: Double
    public var adapterWattage: Int?
    /// Instantaneous battery power in watts (negative = discharging).
    public var watts: Double = 0
    public var voltage: Double = 0
    public var amperage: Double = 0
    // Detailed specs (AlDente-style)
    public var designCapacityMah: Int = 0
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
}

public class BatteryReader {
    public static func read() -> BatteryInfo? {
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
            
            let isCharging = dict["IsCharging"] as? Bool ?? false
            let cycleCount = dict["CycleCount"] as? Int ?? 0
            let currentCapacity = dict["CurrentCapacity"] as? Int ?? 0
            let maxCapacity = dict["MaxCapacity"] as? Int ?? 0
            
            let chargePercent = maxCapacity > 0 ? Int((Double(currentCapacity) / Double(maxCapacity)) * 100) : 0
            
            let nominal = dict["NominalChargeCapacity"] as? Int ?? (dict["BatteryData"] as? [String: Any])?["NominalChargeCapacity"] as? Int ?? 0
            let design = dict["DesignCapacity"] as? Int ?? (dict["BatteryData"] as? [String: Any])?["DesignCapacity"] as? Int ?? 0
            let health = design > 0 ? Int((Double(nominal) / Double(design)) * 100) : 0
            
            var tempC: Double = 0
            if let t = dict["Temperature"] as? Int ?? (dict["BatteryData"] as? [String: Any])?["Temperature"] as? Int {
                tempC = (Double(t) / 100.0) - 273.15
            } else if let t = dict["Temperature"] as? Double {
                tempC = t
            }
            
            let bd = dict["BatteryData"] as? [String: Any]
            let adapter = dict["AdapterDetails"] as? [String: Any]

            var wattage: Int? = nil
            if let w = adapter?["Watts"] as? Int { wattage = w }

            // Instantaneous power: Amperage (mA, signed) × Voltage (mV).
            let amperage = Double(dict["Amperage"] as? Int ?? bd?["Amperage"] as? Int ?? 0)  // mA
            let voltage = Double(dict["Voltage"] as? Int ?? 0)                                // mV
            let watts = (amperage / 1000.0) * (voltage / 1000.0)                              // W (signed)

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
            info.maxCapacityMah = nominal
            info.currentCapacityMah = dict["AppleRawCurrentCapacity"] as? Int ?? bd?["StateOfCharge"] as? Int ?? currentCapacity
            info.timeRemainingMin = timeRemaining
            info.isPluggedIn = dict["ExternalConnected"] as? Bool ?? false
            info.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            info.condition = (dict["PermanentFailureStatus"] as? Int ?? 0) == 0 ? "Normal" : "Service"
            info.adapterDescription = adapter?["Description"] as? String ?? adapter?["Name"] as? String ?? ""
            info.adapterVoltage = Double(adapter?["AdapterVoltage"] as? Int ?? 0) / 1000.0
            info.adapterAmperage = Double(adapter?["Current"] as? Int ?? 0) / 1000.0
            info.serialNumber = dict["Serial"] as? String ?? bd?["Serial"] as? String
            return info
            
        } catch {
            return nil
        }
    }
}
