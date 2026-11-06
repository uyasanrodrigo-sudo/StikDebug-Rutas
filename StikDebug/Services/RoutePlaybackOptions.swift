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

enum MobileDataConnectionGuide {
    static let instructions = "Connect LocalDevVPN with Mobile Data on. Temporarily turn off only Mobile Data, keeping the VPN active. Connect or simulate in StikDebug, then turn Mobile Data back on after the connection succeeds."
    static let limitation = "This sequence worked on the tested iPhone. It may need repeating after losing the session. Do not use Airplane Mode for this sequence."
}

enum RouteConnectionState: String {
    case stopped = "Stopped"
    case connecting = "Connecting"
    case simulating = "Simulating"
    case paused = "Paused"
    case disconnected = "Connection lost"
}

enum RouteRoadMatching {
    // Reject perpendicular roads and prefer continuity when two nearby roads
    // have comparable geometry. The sign retains forward/backward semantics.
    static func score(distance: Double, alignment: Double, sameWay: Bool) -> Double? {
        guard distance.isFinite, alignment.isFinite, distance <= 40,
              abs(alignment) >= 0.75 else { return nil }
        return distance + (1 - min(1, abs(alignment))) * 20 + (sameWay ? 0 : 4)
    }

    static func speed(generic: Double?, forward: Double?, backward: Double?, alignment: Double) -> Double? {
        let candidate = (alignment >= 0 ? forward : backward) ?? generic
        guard let candidate, candidate.isFinite, candidate > 0 else { return nil }
        return min(200 / 3.6, max(0.5 / 3.6, candidate))
    }
}

struct RouteMotionPoint: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
}

struct RouteMotionState: Sendable {
    var distance = 0.0
    var speed = 0.0
}

// Stores route geometry only. Its size does not grow when speed is reduced;
// individual GPS positions are interpolated on demand during playback.
struct RouteStreamPath: Sendable {
    let points: [RouteMotionPoint]
    let distances: [Double]
    let speeds: [Double]
    let cumulative: [Double]
    let remainingTimes: [Double]
    let signalIndices: [Int]
    let cornerSpeeds: [Double]

    init?(points: [RouteMotionPoint], distances: [Double], speeds: [Double], signalIndices: [Int]) {
        guard points.count > 1, points.count <= 100_000,
              distances.count == points.count - 1, speeds.count == distances.count,
              distances.allSatisfy({ $0.isFinite && $0 > 0 }),
              speeds.allSatisfy({ $0.isFinite && $0 > 0 }),
              points.allSatisfy({ $0.latitude.isFinite && $0.longitude.isFinite &&
                  (-90...90).contains($0.latitude) && (-180...180).contains($0.longitude) }) else { return nil }
        self.points = points
        self.distances = distances
        self.speeds = speeds.map { min(200 / 3.6, max(0.5 / 3.6, $0)) }
        var cumulative = [0.0]
        for distance in distances { cumulative.append(cumulative.last! + distance) }
        self.cumulative = cumulative
        var remaining = [Double](repeating: 0, count: points.count)
        for index in distances.indices.reversed() {
            remaining[index] = remaining[index + 1] + distances[index] / self.speeds[index]
        }
        remainingTimes = remaining
        self.signalIndices = Array(Set(signalIndices.filter { $0 > 0 && $0 < points.count - 1 })).sorted()
        var corners = [Double](repeating: .infinity, count: points.count)
        if points.count > 2 {
            for index in 1..<(points.count - 1) {
                let a = points[index - 1], b = points[index], c = points[index + 1]
                let longitudeScale = cos(b.latitude * .pi / 180)
                let x1 = (b.longitude - a.longitude) * longitudeScale, y1 = b.latitude - a.latitude
                let x2 = (c.longitude - b.longitude) * longitudeScale, y2 = c.latitude - b.latitude
                let divisor = hypot(x1, y1) * hypot(x2, y2)
                guard divisor > 0 else { continue }
                let angle = acos(min(1, max(-1, (x1 * x2 + y1 * y2) / divisor))) * 180 / .pi
                if angle > 120 { corners[index] = 2.8 }
                else if angle > 65 { corners[index] = 4.2 }
                else if angle > 30 { corners[index] = 8 }
            }
        }
        cornerSpeeds = corners
    }

    var length: Double { cumulative.last ?? 0 }

    func segment(at distance: Double) -> Int {
        var low = 0, high = distances.count - 1
        while low < high {
            let middle = (low + high) / 2
            if cumulative[middle + 1] <= distance { low = middle + 1 } else { high = middle }
        }
        return low
    }

    func point(at distance: Double) -> RouteMotionPoint {
        if distance >= length { return points.last! }
        let index = segment(at: max(0, distance))
        let fraction = min(1, max(0, (distance - cumulative[index]) / distances[index]))
        let start = points[index], end = points[index + 1]
        return RouteMotionPoint(latitude: start.latitude + (end.latitude - start.latitude) * fraction,
            longitude: start.longitude + (end.longitude - start.longitude) * fraction)
    }

    func reversed() -> RouteStreamPath {
        RouteStreamPath(points: Array(points.reversed()), distances: Array(distances.reversed()),
            speeds: Array(speeds.reversed()), signalIndices: signalIndices.map { points.count - 1 - $0 })!
    }

    func remainingTime(at distance: Double, slowdown: Double) -> Double {
        guard distance < length else { return 0 }
        let index = segment(at: distance)
        return ((cumulative[index + 1] - max(0, distance)) / speeds[index] + remainingTimes[index + 1]) * max(1, slowdown)
    }

    func advance(_ state: RouteMotionState, elapsed: Double, slowdown: Double, stopAt: Double, driving: Bool) -> RouteMotionState {
        let dt = min(1, max(0, elapsed.isFinite ? elapsed : 0))
        let stop = min(length, max(state.distance, stopAt))
        let remaining = stop - state.distance
        if remaining <= 0.15 { return RouteMotionState(distance: stop, speed: 0) }
        let index = segment(at: state.distance)
        var target = speeds[index] / max(1, slowdown)
        if driving {
            let braking = 2.5
            target = min(target, sqrt(2 * braking * remaining))
            let lookAhead = max(40, state.speed * state.speed / (2 * braking) + 20)
            var vertex = index + 1
            while vertex < points.count && cumulative[vertex] - state.distance <= lookAhead {
                let ahead = max(0, cumulative[vertex] - state.distance)
                let nextLimit = vertex < speeds.count ? speeds[vertex] / max(1, slowdown) : 0
                let cap = min(cornerSpeeds[vertex], nextLimit)
                target = min(target, sqrt(cap * cap + 2 * braking * ahead))
                vertex += 1
            }
        }
        let speed = driving
            ? max(0, min(state.speed + 1.8 * dt, max(target, state.speed - 2.5 * dt)))
            : target
        let travel = (driving ? (state.speed + speed) / 2 : speed) * dt
        let distance = min(stop, state.distance + travel)
        return RouteMotionState(distance: distance, speed: distance >= stop ? 0 : speed)
    }
}

enum RouteSignalVisits {
    // Cluster by distance along the path, rather than geographic position.
    // A later visit to the same intersection remains a separate opportunity.
    static func clustered(_ candidates: [(index: Int, offset: Double, separation: Double)]) -> [Int] {
        let sorted = candidates.sorted { $0.offset < $1.offset }
        var groups: [[(index: Int, offset: Double, separation: Double)]] = []
        for candidate in sorted {
            if let previous = groups.last?.first, candidate.offset - previous.offset < 35 {
                groups[groups.count - 1].append(candidate)
            } else { groups.append([candidate]) }
        }
        return groups.compactMap { $0.min(by: { $0.separation < $1.separation })?.index }
    }
}


struct RouteScheduledStop: Sendable, Equatable {
    var distance: Double
    var duration: Double
    var title: String
}

enum RouteStopSchedule {
    static let maximumWaypoints = 5
    static func validDuration(_ value: Double) -> Bool { value.isFinite && (0...86_400).contains(value) }
    static func ordered(_ planned: [RouteScheduledStop], signals: [RouteScheduledStop], length: Double) -> [RouteScheduledStop] {
        let sorted = (planned + signals).filter {
            $0.distance.isFinite && $0.distance >= 0 && $0.distance <= length && validDuration($0.duration) && $0.duration > 0
        }.sorted { $0.distance < $1.distance }
        var result: [RouteScheduledStop] = []
        for stop in sorted {
            if let last = result.last, abs(last.distance - stop.distance) < 0.5 {
                let index = result.count - 1
                result[index].duration = max(last.duration, stop.duration)
                result[index].title = last.title + " / " + stop.title
            } else { result.append(stop) }
        }
        return result
    }
    static func reversed(_ stops: [RouteScheduledStop], length: Double) -> [RouteScheduledStop] {
        stops.reversed().map { RouteScheduledStop(distance: max(0, length - $0.distance), duration: $0.duration, title: $0.title) }
    }
    static func remaining(_ value: Double, elapsed: Double, paused: Bool) -> Double {
        paused ? value : max(0, value - min(1, max(0, elapsed.isFinite ? elapsed : 0)))
    }
}
