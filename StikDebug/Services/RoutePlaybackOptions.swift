import Foundation

extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

enum CoordinateText {
    // Require a complete pair, so an address containing street numbers is
    // never mistaken for latitude/longitude.
    static func parse(_ text: String) -> (latitude: Double, longitude: Double)? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let latitude = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let longitude = Double(parts[1].trimmingCharacters(in: .whitespaces)),
              latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return (latitude, longitude)
    }
}

enum RouteTravelMode: String, CaseIterable, Identifiable {
    case walking
    case driving

    var id: String { rawValue }
    var defaultSpeedKilometersPerHour: Double { self == .walking ? 5 : 48.24 }
}

enum RoutePlaybackTiming {
    // Compensate for ordinary socket latency without bursting through points
    // after a stalled connection. Times are measured on a monotonic clock.
    static func nextDeadline(previous: TimeInterval, interval: TimeInterval, elapsed: TimeInterval) -> TimeInterval {
        max(previous + max(0, interval), elapsed)
    }

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

// Invalidates work already waiting on the serial device command queue. A
// command already executing finishes before the queued clear/new location.
final class LocationCommandGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value = UUID()

    func current() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        value = UUID()
    }

    func isCurrent(_ token: UUID) -> Bool { current() == token }
}

enum WazeDestinationLink {
    static func url(latitude: Double, longitude: Double) -> URL? {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        var components = URLComponents(string: "https://waze.com/ul")!
        components.queryItems = [
            URLQueryItem(name: "ll", value: "\(latitude),\(longitude)"),
            URLQueryItem(name: "navigate", value: "yes"),
            URLQueryItem(name: "utm_source", value: "StikDebug-Rutas")
        ]
        return components.url
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
