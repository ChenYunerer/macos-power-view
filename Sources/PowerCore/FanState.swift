import Foundation
import ThermalSensors

public struct FanState: Sendable {
    public let actualRPM: Double?
    public let minimum: Double
    public let maximum: Double
    public let target: Double?
    public let manual: Bool
    public let controllable: Bool

    public static func read() -> FanState {
        let value = PVReadFanStatus()
        return FanState(minimum: value.minimum, maximum: value.maximum,
            target: value.target.isFinite ? value.target : nil,
            manual: value.mode == 1, controllable: value.controllable == 1, actualRPM: value.actual)
    }

    public init(minimum: Double = 0, maximum: Double = 0, target: Double? = nil, manual: Bool = false, controllable: Bool = false, actualRPM: Double? = nil) {
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
