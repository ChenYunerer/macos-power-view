import Foundation
import ThermalSensors

public struct FanState: Identifiable, Sendable {
    public let id: Int
    public let name: String?
    public var displayName: String { name.map { "\($0) (\(id + 1))" } ?? "风扇 \(id + 1)" }
    public let actualRPM: Double?
    public let minimum: Double
    public let maximum: Double
    public let target: Double?
    public let manual: Bool
    public let controllable: Bool

    public static func readAll() -> [FanState] {
        var values = [PVFanStatus](repeating: PVFanStatus(), count: Int(PV_MAX_FANS))
        let count = PVReadFanStatuses(&values, Int32(values.count))
        return values.prefix(Int(count)).map { value in
            var rawName = value.name
            let name = withUnsafeBytes(of: &rawName) { String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) }
            return FanState(id: Int(value.id), name: name, minimum: value.minimum, maximum: value.maximum,
                target: value.target.isFinite ? value.target : nil,
                manual: value.mode == 1, controllable: value.controllable == 1, actualRPM: value.actual)
        }
    }

    public init(id: Int = 0, name: String? = nil, minimum: Double = 0, maximum: Double = 0, target: Double? = nil, manual: Bool = false, controllable: Bool = false, actualRPM: Double? = nil) {
        self.id = id
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmedName.flatMap { $0.isEmpty ? nil : $0 }
        self.actualRPM = actualRPM.flatMap { $0.isFinite && $0 >= 0 && $0 <= 50000 ? $0 : nil }
        self.minimum = minimum
        self.maximum = maximum
        self.target = target
        self.manual = manual
        self.controllable = controllable && minimum.isFinite && maximum.isFinite
            && minimum >= 500 && maximum <= 20000 && maximum > minimum
    }

    public func accepts(_ rpm: Double) -> Bool {
        controllable && rpm.isFinite && rpm.rounded() == rpm && rpm >= minimum && rpm <= maximum
    }
}

/// The helper reports ownership on both success and failure, including a
/// pending global cleanup after the last fan has returned to automatic mode.
public struct FanControlReply: Sendable {
    public let code: Int
    public let controlledFans: Set<Int>
    public let needsRestore: Bool

    public init?(_ response: String) {
        let status = response.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let fields = status.split(separator: " ")
        let success = fields.first == "OK"
        let offset = success ? 1 : 2
        guard fields.count == offset + 2, success || fields.first == "ERR",
              let code = success ? 0 : Int(fields[1]), (0...7).contains(code), success || code > 0,
              let mask = UInt32(fields[offset]), mask <= 65535,
              let active = Int(fields[offset + 1]), active == 0 || active == 1,
              active == 1 || mask == 0 else { return nil }
        self.code = code
        controlledFans = Set((0..<16).filter { mask & (1 << $0) != 0 })
        needsRestore = active == 1
    }
}
