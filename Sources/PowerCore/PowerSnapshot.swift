import Foundation
import CoreFoundation
import IOKit

public struct PowerSnapshot: Sendable {
    public let date: Date
    public let connected: Bool
    public let charging: Bool
    public let percentage: Double?
    public let inputWatts: Double?
    public let systemWatts: Double?
    /// Positive is charging; negative is discharging.
    public let batteryWatts: Double?
    public let adapterWatts: Double?
    public let inputVolts: Double?
    public let inputAmps: Double?

    public var status: String {
        if charging { return "正在充电" }
        if connected { return (percentage ?? 0) >= 99.5 ? "电池已充满" : "已接电源 · 未充电" }
        return "正在使用电池"
    }

    public var primaryWatts: Double? {
        connected ? inputWatts : batteryWatts.map { max(0, -$0) }
    }

    public init(properties: [String: Any], date: Date = Date()) {
        self.date = date
        connected = properties["ExternalConnected"] as? Bool ?? false
        charging = properties["IsCharging"] as? Bool ?? false
        let telemetry = properties["PowerTelemetryData"] as? [String: Any] ?? [:]
        let adapter = properties["AdapterDetails"] as? [String: Any] ?? [:]
        if let capacity = Self.number(properties["CurrentCapacity"]),
           let maximum = Self.number(properties["MaxCapacity"]), maximum > 0 {
            percentage = min(100, max(0, capacity / maximum * 100))
        } else {
            percentage = nil
        }
        let current = Self.signedNumber(properties["InstantAmperage"])
            ?? Self.signedNumber(properties["Amperage"])
        let batteryEstimate = current.flatMap { current in
            Self.number(properties["Voltage"]).map { current * $0 / 1_000_000 }
        }
        // Adapter telemetry can remain cached after unplugging.
        inputWatts = connected ? Self.number(telemetry["SystemPowerIn"]).map { $0 / 1000 } : 0
        systemWatts = connected ? Self.number(telemetry["SystemLoad"]).map { $0 / 1000 } : nil
        batteryWatts = connected
            ? (Self.signedNumber(telemetry["BatteryPower"]).map { $0 / 1000 } ?? batteryEstimate)
            : batteryEstimate
        adapterWatts = connected ? Self.number(adapter["Watts"]) : nil
        inputVolts = connected ? Self.number(telemetry["SystemVoltageIn"]).map { $0 / 1000 } : nil
        inputAmps = connected ? Self.number(telemetry["SystemCurrentIn"]).map { $0 / 1000 } : nil
    }

    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }

    private static func signedNumber(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, let value = number(n) else { return nil }
        // ioreg may expose a negative signed 64-bit value as an unsigned integer.
        return value >= 9_223_372_036_854_775_808 ? Double(n.int64Value) : value
    }
}

public enum PowerReader {
    public static func read() throws -> PowerSnapshot {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { throw ReadError.noBattery }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS, let properties else { throw ReadError.unavailable }
        guard let dictionary = properties.takeRetainedValue() as NSDictionary as? [String: Any] else {
            throw ReadError.unavailable
        }
        return PowerSnapshot(properties: dictionary)
    }

    public enum ReadError: LocalizedError {
        case noBattery, unavailable
        public var errorDescription: String? {
            switch self {
            case .noBattery: return "未找到内置电池，请在 Mac 笔记本上使用。"
            case .unavailable: return "暂时无法读取电源信息，请稍后重试。"
            }
        }
    }
}
