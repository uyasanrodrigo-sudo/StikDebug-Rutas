import Foundation
import CoreLocation
import Combine

final class LocationSimulationSession: ObservableObject {
    static let shared = LocationSimulationSession()

    @Published private(set) var isActive = false
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var routeCoordinates: [CLLocationCoordinate2D]?
    private var resendTimer: Timer?
    private var routeID: UUID?
    var currentRouteID: UUID? { routeID }
    let commandGeneration = LocationCommandGeneration()
    @Published private(set) var connectionState: RouteConnectionState = .stopped
    @Published private(set) var lastSuccessfulUpdate: Date?
    @Published private(set) var lastFailure: String?
    @Published private(set) var gpsRestorationMessage: String?
    @Published private(set) var gpsRestorationConfirmed: Bool?
    @Published private(set) var isPaused = false
    @Published private(set) var currentSpeedKilometersPerHour = 0.0
    @Published private(set) var remainingDistance = 0.0
    @Published private(set) var remainingTime = 0.0
    @Published private(set) var legProgress = 0.0
    @Published private(set) var completedRoundTrips = 0
    @Published private(set) var returning = false
    @Published private(set) var reconnectRequested = false
    @Published private(set) var stopTitle = ""
    @Published private(set) var stopSecondsRemaining = 0.0
    @Published private(set) var isReplacingRoute = false
    private(set) var isHoldingForReplacement = false
    private var playbackTask: Task<Void, Never>?

    private init() {}

    func start(at coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        if !isActive {
            isActive = true
            BackgroundAudioManager.shared.requestStart()
            BackgroundLocationManager.shared.requestStart()
        }
        connectionState = isPaused ? .paused : .simulating
        lastSuccessfulUpdate = Date()
        lastFailure = nil
        gpsRestorationMessage = nil
        gpsRestorationConfirmed = nil
    }

    func startResending(at coordinate: CLLocationCoordinate2D, _ operation: @escaping () -> Int32) {
        startTimer(at: coordinate, radius: 0) { _ in operation() }
    }

    func startWandering(at coordinate: CLLocationCoordinate2D, radius: Double,
                        _ operation: @escaping (CLLocationCoordinate2D) -> Int32) {
        startTimer(at: coordinate, radius: min(100, max(10, radius)), operation)
    }

    private func startTimer(at coordinate: CLLocationCoordinate2D, radius: Double,
                            _ operation: @escaping (CLLocationCoordinate2D) -> Int32) {
        pauseResending()
        start(at: coordinate)
        let generation = commandGeneration
        let token = generation.current()
        var motion = StaticWanderMotion()
        var previousTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 4, repeats: true) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - previousTick
            previousTick = now
            var next = coordinate
            if radius > 0 {
                motion.advance(elapsed: elapsed, radius: radius, angleRoll: Double.random(in: 0...1),
                    radiusRoll: Double.random(in: 0...1), pauseRoll: Double.random(in: 0...1))
                // At most one metre of GPS variation; the walk reserves three
                // metres at the boundary. Use a spherical destination at poles.
                let jitter = Double.random(in: 0...(2 * Double.pi))
                let east = motion.east + cos(jitter), north = motion.north + sin(jitter)
                let angle = hypot(east, north) / 6_371_000
                let bearing = atan2(east, north)
                let latitude = coordinate.latitude * .pi / 180
                let longitude = coordinate.longitude * .pi / 180
                let lat = asin(sin(latitude) * cos(angle) + cos(latitude) * sin(angle) * cos(bearing))
                let lon = longitude + atan2(sin(bearing) * sin(angle) * cos(latitude), cos(angle) - sin(latitude) * sin(lat))
                next = CLLocationCoordinate2D(latitude: lat * 180 / .pi,
                    longitude: (lon * 180 / .pi + 540).truncatingRemainder(dividingBy: 360) - 180)
            }
            let destination = next
            LocationSimulationCommandQueue.shared.async {
                guard generation.isCurrent(token) else { return }
                let code = operation(destination)
                DispatchQueue.main.async {
                    guard generation.isCurrent(token) else { return }
                    if code == 0 { self.recordSuccessfulUpdate(destination) }
                    else { self.recordFailure(locationSimulationErrorMessage(for: code)) }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        resendTimer = timer
    }

    func startRoute(at coordinate: CLLocationCoordinate2D, coordinates: [CLLocationCoordinate2D]) -> UUID {
        pauseResending()
        endRouteReplacement()
        playbackTask?.cancel()
        playbackTask = nil
        updateStop(title: "", remaining: 0)
        let routeID = UUID()
        self.routeID = routeID
        routeCoordinates = coordinates
        isPaused = false
        completedRoundTrips = 0
        returning = false
        reconnectRequested = false
        updateProgress(distance: 0, length: 0, speed: 0, eta: 0, returning: false)
        start(at: coordinate)
        return routeID
    }

    func isCurrentRoute(_ routeID: UUID) -> Bool {
        self.routeID == routeID
    }

    func beginRouteReplacement(routeID: UUID) -> Bool {
        guard isCurrentRoute(routeID), !isReplacingRoute,
              connectionState == .simulating || connectionState == .paused else { return false }
        isHoldingForReplacement = false
        isReplacingRoute = true
        return true
    }

    func acknowledgeRouteReplacement() {
        isHoldingForReplacement = isReplacingRoute
    }

    func endRouteReplacement() {
        isReplacingRoute = false
        isHoldingForReplacement = false
    }

    func clearRoute() {
        endRouteReplacement()
        commandGeneration.invalidate()
        playbackTask?.cancel()
        playbackTask = nil
        routeID = nil
        routeCoordinates = nil
        updateStop(title: "", remaining: 0)
        isPaused = false
        reconnectRequested = false
    }

    func pauseResending() {
        commandGeneration.invalidate()
        resendTimer?.invalidate()
        resendTimer = nil
    }

    func updateCoordinate(_ coordinate: CLLocationCoordinate2D) {
        recordSuccessfulUpdate(coordinate)
    }

    func stop() {
        pauseResending()
        clearRoute()
        releaseBackgroundActivity()
        coordinate = nil
        connectionState = .stopped
        currentSpeedKilometersPerHour = 0
        remainingDistance = 0
        remainingTime = 0
        legProgress = 0
        lastFailure = nil
        gpsRestorationMessage = "GPS restoration not confirmed yet."
        gpsRestorationConfirmed = nil
    }

    func markConnecting() {
        connectionState = .connecting
        lastFailure = nil
        gpsRestorationMessage = nil
        gpsRestorationConfirmed = nil
    }

    func recordSuccessfulUpdate(_ coordinate: CLLocationCoordinate2D) {
        start(at: coordinate)
    }

    func recordFailure(_ message: String) {
        pauseResending()
        releaseBackgroundActivity()
        connectionState = .disconnected
        lastFailure = message
        currentSpeedKilometersPerHour = 0
        if routeID != nil { isPaused = true }
        reconnectRequested = false
    }

    func confirmGPSRestoration(_ confirmed: Bool) {
        gpsRestorationConfirmed = confirmed
        gpsRestorationMessage = confirmed ? "GPS restoration confirmed." :
            "Local simulation stopped. GPS restoration could not be confirmed; reconnect the VPN and retry Stop."
    }

    func attachPlaybackTask(_ task: Task<Void, Never>, routeID: UUID) {
        guard isCurrentRoute(routeID) else { task.cancel(); return }
        playbackTask = task
    }

    func togglePause() {
        guard routeID != nil, connectionState != .disconnected, connectionState != .connecting else { return }
        isPaused.toggle()
        currentSpeedKilometersPerHour = 0
        connectionState = isPaused ? .paused : .simulating
    }

    func requestReconnect() {
        guard connectionState == .disconnected else { return }
        reconnectRequested = true
        connectionState = .connecting
    }

    func finishReconnect() {
        reconnectRequested = false
        connectionState = isPaused ? .paused : .simulating
    }

    func updateProgress(distance: Double, length: Double, speed: Double, eta: Double, returning: Bool) {
        remainingDistance = max(0, length - distance)
        remainingTime = max(0, eta)
        legProgress = length > 0 ? min(1, max(0, distance / length)) : 0
        currentSpeedKilometersPerHour = isPaused ? 0 : max(0, speed * 3.6)
        self.returning = returning
    }

    func updateStop(title: String, remaining: Double) {
        stopTitle = title
        stopSecondsRemaining = max(0, remaining)
    }

    func completedReturn() { completedRoundTrips += 1 }

    private func releaseBackgroundActivity() {
        guard isActive else { return }
        isActive = false
        BackgroundAudioManager.shared.requestStop()
        BackgroundLocationManager.shared.requestStop()
    }
}
