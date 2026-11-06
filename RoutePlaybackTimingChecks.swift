import Foundation
import CoreLocation

#if ROUTE_SESSION_CHECKS
final class BackgroundAudioManager {
    static let shared = BackgroundAudioManager()
    var activities = 0
    func requestStart() { precondition(Thread.isMainThread); activities += 1 }
    func requestStop() { precondition(Thread.isMainThread); activities -= 1; precondition(activities >= 0) }
}
final class BackgroundLocationManager {
    static let shared = BackgroundLocationManager()
    var activities = 0
    func requestStart() { precondition(Thread.isMainThread); activities += 1 }
    func requestStop() { precondition(Thread.isMainThread); activities -= 1; precondition(activities >= 0) }
}
enum LocationSimulationCommandQueue {
    static let shared = DispatchQueue(label: "route-check.location-commands")
}
func locationSimulationErrorMessage(for code: Int32) -> String { "Simulated transport failure \(code)" }
#endif

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
        // Socket latency below one tick should not accumulate across a route.
        var deadline = 0.0
        var elapsed = 0.0
        for _ in 0..<20 {
            deadline = RoutePlaybackTiming.nextDeadline(previous: deadline, interval: 0.5, elapsed: elapsed)
            elapsed = deadline + 0.12
        }
        near(deadline, 10)
        let stalled = RoutePlaybackTiming.nextDeadline(previous: 1, interval: 0.5, elapsed: 10)
        near(stalled, 10)
        near(RoutePlaybackTiming.nextDeadline(previous: stalled, interval: 0.5, elapsed: 10.1), 10.5)
        near(Duration.milliseconds(250).timeInterval, 0.25)

        // Old timer work already enqueued must be rejected after Stop, while
        // work for the replacement location remains valid on the same queue.
        let generation = LocationCommandGeneration()
        let oldToken = generation.current()
        let queue = DispatchQueue(label: "route-check.queued-stop")
        queue.suspend()
        queue.async { precondition(!generation.isCurrent(oldToken), "Stale location survived Stop") }
        generation.invalidate()
        let replacementToken = generation.current()
        queue.async { precondition(generation.isCurrent(replacementToken), "New location was discarded") }
        queue.resume()
        queue.sync {}

        let pair = CoordinateText.parse(" 4.6, -74.1 ")!
        near(pair.latitude, 4.6)
        near(pair.longitude, -74.1)
        for invalid in ["Calle 26 # 10-30", "26, Bogota", "91,0", "0,-181", "nan,0", "4,5,6", ""] {
            precondition(CoordinateText.parse(invalid) == nil)
        }
        let link = WazeDestinationLink.url(latitude: 4.6, longitude: -74.1)!
        let components = URLComponents(url: link, resolvingAgainstBaseURL: false)!
        precondition(components.scheme == "https" && components.host == "waze.com")
        precondition(components.queryItems?.first(where: { $0.name == "ll" })?.value == "4.6,-74.1")
        precondition(components.queryItems?.first(where: { $0.name == "navigate" })?.value == "yes")
        precondition(WazeDestinationLink.url(latitude: .nan, longitude: 0) == nil)
        let vertices = [RouteMotionPoint(latitude: 0, longitude: 0),
            RouteMotionPoint(latitude: 0, longitude: 0.001), RouteMotionPoint(latitude: 0.001, longitude: 0.001)]
        let path = RouteStreamPath(points: vertices, distances: [100, 100], speeds: [20, 20], signalIndices: [1])!
        near(path.length, 200)
        near(path.remainingTime(at: 0, slowdown: 2), 20)
        near(path.remainingTime(at: 150, slowdown: 1), 2.5)
        precondition(path.point(at: 200) == vertices[2])
        near(path.point(at: 50).longitude, 0.0005)
        let reverse = path.reversed()
        precondition(reverse.points.first == path.points.last && reverse.points.last == path.points.first)
        near(reverse.remainingTime(at: 0, slowdown: 1), 10)

        var motion = RouteMotionState()
        var sawBraking = false
        var previousSpeed = 0.0
        for _ in 0..<1000 {
            let next = path.advance(motion, elapsed: 0.5, slowdown: 1, stopAt: 150, driving: true)
            precondition(next.distance >= motion.distance && next.distance <= 150)
            precondition(next.speed <= previousSpeed + 0.9 + 0.000001)
            if next.speed < previousSpeed { sawBraking = true }
            motion = next
            previousSpeed = next.speed
            if motion.distance == 150 { break }
        }
        near(motion.distance, 150)
        near(motion.speed, 0)
        precondition(sawBraking)
        let start = path.advance(RouteMotionState(), elapsed: 0.5, slowdown: 1, stopAt: 200, driving: true)
        near(start.speed, 0.9)
        near(start.distance, 0.225)
        let stalledMotion = path.advance(RouteMotionState(), elapsed: 120, slowdown: 1, stopAt: 200, driving: true)
        precondition(stalledMotion.distance < 1, "A stalled socket caused a jump")
        precondition(RouteStreamPath(points: vertices, distances: [100, .nan], speeds: [20, 20], signalIndices: []) == nil)

        let longPoints = (0...10_000).map { RouteMotionPoint(latitude: 0, longitude: Double($0) / 10000) }
        let slowPath = RouteStreamPath(points: longPoints, distances: Array(repeating: 10, count: 10_000),
            speeds: Array(repeating: 0.5 / 3.6, count: 10_000), signalIndices: [])!
        precondition(slowPath.points.count == 10_001, "Geometry storage depends on playback tick count")
        near(slowPath.remainingTime(at: 0, slowdown: 1), 720_000)
        precondition(RouteRoadMatching.score(distance: 1, alignment: 0, sameWay: false) == nil)
        precondition(RouteRoadMatching.score(distance: 41, alignment: 1, sameWay: true) == nil)
        precondition(RouteRoadMatching.score(distance: 2, alignment: 1, sameWay: true)! <
            RouteRoadMatching.score(distance: 1, alignment: 1, sameWay: false)!)
        near(RouteRoadMatching.speed(generic: 10, forward: 20, backward: 5, alignment: 1)!, 20)
        near(RouteRoadMatching.speed(generic: 10, forward: 20, backward: 5, alignment: -1)!, 5)
        precondition(RouteRoadMatching.speed(generic: .nan, forward: nil, backward: nil, alignment: 1) == nil)
        let visits = RouteSignalVisits.clustered([(2, 20, 3), (3, 25, 5), (40, 400, 2), (41, 410, 8)])
        precondition(visits == [2, 40], "A second visit to the same junction was removed")

        precondition(RouteStopSchedule.maximumWaypoints == 5)
        precondition(RouteStopSchedule.validDuration(0) && RouteStopSchedule.validDuration(86_400))
        precondition(!RouteStopSchedule.validDuration(.nan) && !RouteStopSchedule.validDuration(-1))
        let planned = [RouteScheduledStop(distance: 50, duration: 60, title: "A"),
            RouteScheduledStop(distance: 150, duration: 300, title: "B")]
        let scheduled = RouteStopSchedule.ordered(planned, signals: [RouteScheduledStop(distance: 50.1, duration: 30, title: "Signal")], length: 200)
        precondition(scheduled.count == 2)
        near(scheduled[0].duration, 60)
        near(scheduled.reduce(0) { $0 + $1.duration }, 360)
        let reverseStops = RouteStopSchedule.reversed(planned, length: 200)
        precondition(reverseStops.map(\.title) == ["B", "A"])
        near(reverseStops[0].distance, 50)
        near(reverseStops[1].distance, 150)
        near(RouteStopSchedule.remaining(60, elapsed: 1, paused: true), 60)
        near(RouteStopSchedule.remaining(60, elapsed: 0.5, paused: false), 59.5)
        near(RouteStopSchedule.remaining(0.2, elapsed: 0.5, paused: false), 0)

#if ROUTE_SESSION_CHECKS
        let session = LocationSimulationSession.shared
        let coordinate = CLLocationCoordinate2D(latitude: 4.6, longitude: -74.1)
        session.start(at: coordinate)
        precondition(session.isActive && session.lastSuccessfulUpdate != nil)
        session.recordFailure("Lost tunnel")
        precondition(!session.isActive && session.connectionState == .disconnected)
        precondition(BackgroundAudioManager.shared.activities == 0)
        session.stop()
        session.confirmGPSRestoration(false)
        precondition(!session.isActive && session.connectionState == .stopped && session.gpsRestorationConfirmed == false)
        session.stop()
        precondition(BackgroundLocationManager.shared.activities == 0)

        let routeID = session.startRoute(at: coordinate, coordinates: [coordinate, coordinate])
        let routeTask = Task { try? await Task.sleep(for: .seconds(30)) }
        // The engine is owned by the session, independently of a map view.
        let cancellable = Task<Void, Never> { _ = await routeTask.value }
        session.attachPlaybackTask(cancellable, routeID: routeID)
        session.togglePause()
        precondition(session.isPaused && session.connectionState == .paused)
        session.recordFailure("Lost tunnel while paused")
        session.requestReconnect()
        precondition(session.reconnectRequested && session.connectionState == .connecting)
        session.recordSuccessfulUpdate(coordinate)
        session.finishReconnect()
        precondition(session.isPaused && session.connectionState == .paused)
        session.togglePause()
        precondition(!session.isPaused && session.connectionState == .simulating)
        session.updateStop(title: "Test stop", remaining: 60)
        session.stop()
        precondition(session.stopSecondsRemaining == 0 && session.stopTitle.isEmpty)
        precondition(cancellable.isCancelled && !session.isCurrentRoute(routeID))
        routeTask.cancel()

        // A real resend timer must report errors instead of silently staying active.
        session.startResending(at: coordinate) { 11 }
        RunLoop.main.run(until: Date().addingTimeInterval(4.3))
        precondition(session.connectionState == .disconnected && !session.isActive)
        precondition(session.lastFailure != nil && BackgroundAudioManager.shared.activities == 0)

        // A timer callback queued before Stop cannot send after the reset.
        LocationSimulationCommandQueue.shared.suspend()
        session.startResending(at: coordinate) { preconditionFailure("Queued resend survived Stop") }
        RunLoop.main.run(until: Date().addingTimeInterval(4.1))
        session.stop()
        LocationSimulationCommandQueue.shared.resume()
        LocationSimulationCommandQueue.shared.sync {}
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(session.connectionState == .stopped && BackgroundLocationManager.shared.activities == 0)
#endif
        print("Streaming geometry, braking, repeated signal visits, session Stop, pause/reconnect and queued cancellation checks passed")
    }
}
