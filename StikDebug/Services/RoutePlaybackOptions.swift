import Foundation

enum RouteTravelMode: String, CaseIterable, Identifiable {
    case walking
    case driving

    var id: String { rawValue }
    var defaultSpeedKilometersPerHour: Double { self == .walking ? 5 : 48.24 }
}

enum RoutePlaybackTiming {
    static func metersPerSecond(kilometersPerHour: Double) -> Double {
        let speed = kilometersPerHour.isFinite ? kilometersPerHour : 5
        return min(200, max(0.5, speed)) / 3.6
    }

    struct Step {
        let sampleIndex: Int
        let delay: TimeInterval
    }

    // Each delay belongs to the segment ending at that sample. On the return
    // leg, reuse the same segment's delay and omit the shared endpoint.
    static func steps(delays: [TimeInterval], returning: Bool) -> [Step] {
        guard delays.count > 1 else { return [] }
        if returning {
            return stride(from: delays.count - 2, through: 0, by: -1).map {
                Step(sampleIndex: $0, delay: delays[$0 + 1])
            }
        }
        return delays.indices.dropFirst().map { Step(sampleIndex: $0, delay: delays[$0]) }
    }
}

enum RouteTrafficBehavior {
    // MKRoute's time is ideal; calculateETA includes expected traffic. Apply
    // only a slowdown, never an acceleration above the user's chosen speed.
    static func slowdown(idealTime: Double, trafficTime: Double) -> Double {
        guard idealTime.isFinite, trafficTime.isFinite,
              idealTime > 0, trafficTime > 0 else { return 1 }
        return max(1, trafficTime / idealTime)
    }

    static func signalStopDuration(chanceRoll: Double, durationRoll: Double, maximum: Double) -> Double {
        guard chanceRoll.isFinite, durationRoll.isFinite, maximum.isFinite,
              chanceRoll >= 0, chanceRoll < 0.6 else { return 0 }
        let upper = min(90, max(5, maximum))
        return 5 + min(1, max(0, durationRoll)) * (upper - 5)
    }
}
