import Foundation

public struct PowerSample: Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let watts: Double

    public init(date: Date, watts: Double, id: UUID = UUID()) {
        self.id = id
        self.date = date
        self.watts = watts
    }
}

/// Bound memory even if the user repeatedly requests refreshes or changes time.
public struct PowerHistory: Sendable {
    public static let duration: TimeInterval = 3600
    public static let sampleInterval: TimeInterval = 10
    public static let maximumSamples = 361
    public private(set) var samples: [PowerSample] = []
    public init() {}
    public mutating func reset() { samples.removeAll(keepingCapacity: true) }
    public mutating func append(watts: Double, at date: Date) {
        guard watts.isFinite, watts >= 0 else { return }
        if let last = samples.last, date < last.date { reset() }
        samples.removeAll { $0.date < date.addingTimeInterval(-Self.duration) }
        // Frequent manual refreshes update the latest ten-second bucket,
        // preserving a full hour without unbounded chart work.
        if let last = samples.last,
           floor(last.date.timeIntervalSince1970 / Self.sampleInterval) == floor(date.timeIntervalSince1970 / Self.sampleInterval) {
            samples[samples.count - 1] = PowerSample(date: date, watts: watts, id: last.id)
        } else {
            samples.append(PowerSample(date: date, watts: watts))
        }
        if samples.count > Self.maximumSamples { samples.removeFirst(samples.count - Self.maximumSamples) }
    }
}
