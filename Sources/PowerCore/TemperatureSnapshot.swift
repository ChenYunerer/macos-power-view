import Foundation
import ThermalSensors

public struct TemperatureReading: Sendable {
    public let name: String
    public let celsius: Double

    public init(name: String, celsius: Double) {
        self.name = name
        self.celsius = celsius
    }
}

public struct TemperatureSnapshot: Sendable {
    public let cpu: Double?
    public let gpu: Double?
    public let ssd: Double?
    public let battery: Double?

    static func component(for name: String) -> Int? {
        if name.hasPrefix("eACC MTR Temp Sensor") || name.hasPrefix("pACC MTR Temp Sensor") { return 0 }
        if name.hasPrefix("GPU MTR Temp Sensor") { return 1 }
        if name.hasPrefix("NAND CH") && name.hasSuffix(" temp") { return 2 }
        if name == "gas gauge battery" { return 3 }
        return nil
    }

    // Display the hottest valid current measurement for each component.
    // Sensor labels identify measurement locations, not individual core counts.
    public init(readings: [TemperatureReading] = []) {
        var values = [Double?](repeating: nil, count: 4)
        for reading in readings {
            guard reading.celsius.isFinite, reading.celsius > 0, reading.celsius <= 125,
                  let index = Self.component(for: reading.name) else { continue }
            values[index] = max(values[index] ?? reading.celsius, reading.celsius)
        }
        cpu = values[0]; gpu = values[1]; ssd = values[2]; battery = values[3]
    }
}

public enum TemperatureReader {
    public static func read() -> TemperatureSnapshot {
        var readings: [TemperatureReading] = []
        withUnsafeMutablePointer(to: &readings) { pointer in
            PVReadTemperatureSensorsMatching({ name in
                guard let name else { return 0 }
                return TemperatureSnapshot.component(for: String(cString: name)) == nil ? 0 : 1
            }, { name, celsius, context in
                guard let name, let context else { return }
                let readings = context.assumingMemoryBound(to: [TemperatureReading].self)
                readings.pointee.append(TemperatureReading(name: String(cString: name), celsius: celsius))
            }, pointer)
        }
        return TemperatureSnapshot(readings: readings)
    }
}

public enum FanReader {
    public static func rpm() -> Double? {
        let value = PVReadFanRPM()
        return value.isFinite && value >= 0 ? value : nil
    }
}
