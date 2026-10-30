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
    let commandGeneration = LocationCommandGeneration()

    private init() {}

    func start(at coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        if !isActive {
            isActive = true
            BackgroundAudioManager.shared.requestStart()
            BackgroundLocationManager.shared.requestStart()
        }
    }

    func startResending(at coordinate: CLLocationCoordinate2D, _ operation: @escaping () -> Void) {
        pauseResending()
        start(at: coordinate)
        let generation = commandGeneration
        let token = generation.current()
        let timer = Timer(timeInterval: 4, repeats: true) { _ in
            LocationSimulationCommandQueue.shared.async {
                guard generation.isCurrent(token) else { return }
                operation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        resendTimer = timer
    }

    func startRoute(at coordinate: CLLocationCoordinate2D, coordinates: [CLLocationCoordinate2D]) -> UUID {
        pauseResending()
        let routeID = UUID()
        self.routeID = routeID
        routeCoordinates = coordinates
        start(at: coordinate)
        return routeID
    }

    func isCurrentRoute(_ routeID: UUID) -> Bool {
        self.routeID == routeID
    }

    func clearRoute() {
        commandGeneration.invalidate()
        routeID = nil
        routeCoordinates = nil
    }

    func pauseResending() {
        commandGeneration.invalidate()
        resendTimer?.invalidate()
        resendTimer = nil
    }

    func updateCoordinate(_ coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
    }

    func stop() {
        pauseResending()
        clearRoute()
        guard isActive else { return }
        isActive = false
        coordinate = nil
        BackgroundAudioManager.shared.requestStop()
        BackgroundLocationManager.shared.requestStop()
    }
}
