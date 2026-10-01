import Foundation

public struct PowerSample: Identifiable, Sendable {
    public let id = UUID()
    public let date: Date
    public let watts: Double
}

/// Bound memory even if the user repeatedly requests refreshes or changes time.
public struct PowerHistory: Sendable {
    public private(set) var samples: [PowerSample] = []
    public init() {}
    public mutating func reset() { samples.removeAll(keepingCapacity: true) }
    public mutating func append(watts: Double, at date: Date) {
        guard watts.isFinite, watts >= 0 else { return }
        if let last = samples.last, date <= last.date { reset() }
        samples.removeAll { $0.date < date.addingTimeInterval(-120) }
        samples.append(PowerSample(date: date, watts: watts))
        if samples.count > 240 { samples.removeFirst(samples.count - 240) }
    }
}
