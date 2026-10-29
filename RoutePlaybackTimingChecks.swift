import Foundation

@main
struct RoutePlaybackTimingChecks {
    static func main() {
        func near(_ actual: Double, _ expected: Double) {
            precondition(abs(actual - expected) < 0.000001, "Expected \(expected), got \(actual)")
        }

        near(RoutePlaybackTiming.metersPerSecond(kilometersPerHour: 3.6), 1)
        near(RoutePlaybackTiming.metersPerSecond(kilometersPerHour: 0.5), 0.5 / 3.6)
        near(RoutePlaybackTiming.metersPerSecond(kilometersPerHour: -10), 0.5 / 3.6)
        near(RoutePlaybackTiming.metersPerSecond(kilometersPerHour: 999), 200 / 3.6)
        near(RoutePlaybackTiming.metersPerSecond(kilometersPerHour: .nan), 5 / 3.6)
        near(RoutePlaybackTiming.metersPerSecond(kilometersPerHour: .infinity), 5 / 3.6)
        near(RouteTravelMode.walking.defaultSpeedKilometersPerHour, 5)

        let delays = [0.0, 0.2, 0.5, 0.1]
        let outward = RoutePlaybackTiming.steps(delays: delays, returning: false)
        let inward = RoutePlaybackTiming.steps(delays: delays, returning: true)
        precondition(outward.map(\.sampleIndex) == [1, 2, 3])
        precondition(inward.map(\.sampleIndex) == [2, 1, 0])
        precondition(inward.map(\.delay) == [0.1, 0.5, 0.2])
        near(outward.reduce(0) { $0 + $1.delay }, inward.reduce(0) { $0 + $1.delay })

        // Multiple cycles meet at an endpoint, without jumping to the start.
        let cycle = [0] + outward.map(\.sampleIndex) + inward.map(\.sampleIndex) + outward.map(\.sampleIndex)
        precondition(zip(cycle, cycle.dropFirst()).allSatisfy { pair in abs(pair.0 - pair.1) == 1 })
        for count in 0...1 {
            let emptyLeg = [Double](repeating: 0, count: count)
            precondition(RoutePlaybackTiming.steps(delays: emptyLeg, returning: false).isEmpty)
            precondition(RoutePlaybackTiming.steps(delays: emptyLeg, returning: true).isEmpty)
        }
        let shortReturn = RoutePlaybackTiming.steps(delays: [0, 0.4], returning: true)
        precondition(shortReturn.count == 1 && shortReturn[0].sampleIndex == 0)
        near(shortReturn[0].delay, 0.4)
        near(RouteTrafficBehavior.slowdown(idealTime: 100, trafficTime: 150), 1.5)
        near(RouteTrafficBehavior.slowdown(idealTime: 100, trafficTime: 80), 1)
        near(RouteTrafficBehavior.slowdown(idealTime: 0, trafficTime: 80), 1)
        near(RouteTrafficBehavior.slowdown(idealTime: .nan, trafficTime: 80), 1)
        near(RouteTrafficBehavior.slowdown(idealTime: 100, trafficTime: .infinity), 1)
        near(RouteTrafficBehavior.signalStopDuration(chanceRoll: 0.9, durationRoll: 0.5, maximum: 45), 0)
        near(RouteTrafficBehavior.signalStopDuration(chanceRoll: 0.6, durationRoll: 0.5, maximum: 45), 0)
        near(RouteTrafficBehavior.signalStopDuration(chanceRoll: 0.2, durationRoll: 0, maximum: 45), 5)
        near(RouteTrafficBehavior.signalStopDuration(chanceRoll: 0.2, durationRoll: 1, maximum: 45), 45)
        near(RouteTrafficBehavior.signalStopDuration(chanceRoll: 0.2, durationRoll: 0.5, maximum: 45), 25)
        near(RouteTrafficBehavior.signalStopDuration(chanceRoll: 0.2, durationRoll: 1, maximum: 500), 90)
        print("Route timing checks passed")
    }
}
