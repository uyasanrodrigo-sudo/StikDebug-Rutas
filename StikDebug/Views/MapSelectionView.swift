//
//  MapSelectionView.swift
//  StikDebug
//
//  Created by Stephen on 11/3/25.
//

import SwiftUI
import MapKit
import UIKit
import UniformTypeIdentifiers

private struct CoordinateSnapshot: Equatable {
    let latitude: Double
    let longitude: Double

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private struct RouteSearchSelection {
    let title: String
    let coordinate: CLLocationCoordinate2D
}

private enum RouteSearchField: String, Identifiable {
    case start
    case end
    var id: String { rawValue }
}

private struct RouteWaypoint: Identifiable {
    var id = UUID()
    var selection: RouteSearchSelection
    var duration: Double = 60
}

private struct RouteTrafficLeg {
    let start: CLLocationCoordinate2D
    let end: CLLocationCoordinate2D
    let distance: Double
    let idealTime: Double
}

private struct RouteSimulationPlan {
    let displayCoordinates: [CLLocationCoordinate2D]
    let distance: CLLocationDistance
    let expectedTravelTime: TimeInterval
    var name: String = "Imported route"
    var waypoints: [RouteWaypoint] = []
    var scheduledStops: [RouteScheduledStop] = []
    var trafficLegs: [RouteTrafficLeg] = []
}

private enum RouteSimulationDefaults {
    static let pathSamplingDistance: CLLocationDistance = 10
    static let playbackTickInterval: TimeInterval = 0.5
    static let minimumSpeedMetersPerSecond: CLLocationSpeed = 0.5 / 3.6
    static let importedRouteFallbackSpeedMetersPerSecond: CLLocationSpeed = 13.4
}

private struct RoutePlaybackSample {
    let coordinate: CLLocationCoordinate2D
    let delayFromPrevious: TimeInterval
    var isTrafficSignal: Bool = false
    var distanceFromPrevious: Double = 0
    var speedMetersPerSecond: Double = 5 / 3.6
}

private func streamingPath(_ samples: [RoutePlaybackSample]) -> RouteStreamPath? {
    RouteStreamPath(
        points: samples.map { RouteMotionPoint(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) },
        distances: samples.dropFirst().map(\.distanceFromPrevious),
        speeds: samples.dropFirst().map(\.speedMetersPerSecond),
        signalIndices: samples.indices.filter { samples[$0].isTrafficSignal }
    )
}

private func preparedSamples(
    for plan: RouteSimulationPlan?, chosenSpeed: Double?,
    useRoadSpeeds: Bool, includeSignals: Bool
) async -> [RoutePlaybackSample] {
    guard let plan else { return [] }
    let fallback = chosenSpeed ?? (plan.expectedTravelTime > 0
        ? plan.distance / plan.expectedTravelTime
        : RouteSimulationDefaults.importedRouteFallbackSpeedMetersPerSecond)
    return await prefetchRoutePlaybackSamples(
        displayCoordinates: plan.displayCoordinates,
        fallbackSpeedMetersPerSecond: fallback,
        useRoadSpeeds: useRoadSpeeds, includeSignals: includeSignals
    )
}

private func drivingReturnPlan(for plan: RouteSimulationPlan) async throws -> RouteSimulationPlan {
    guard let start = plan.displayCoordinates.last, let end = plan.displayCoordinates.first else {
        throw URLError(.badURL)
    }
    if !plan.waypoints.isEmpty {
        return try await multiStopPlan(start: start, end: end, waypoints: Array(plan.waypoints.reversed()), mode: .driving)
    }
    let request = MKDirections.Request()
    request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
    request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
    request.transportType = .automobile
    let directions = MKDirections(request: request)
    let timeout = Task {
        do { try await Task.sleep(for: .seconds(20)) } catch { return }
        directions.cancel()
    }
    defer { timeout.cancel() }
    let response = try await withTaskCancellationHandler {
        try await directions.calculate()
    } onCancel: { directions.cancel() }
    try Task.checkCancellation()
    guard let route = response.routes.first else { throw URLError(.resourceUnavailable) }
    var coordinates = sampledRouteCoordinates(from: route.polyline.coordinateArray,
        targetDistance: RouteSimulationDefaults.pathSamplingDistance)
    guard let first = coordinates.first, let last = coordinates.last,
          CLLocation(latitude: first.latitude, longitude: first.longitude)
            .distance(from: CLLocation(latitude: start.latitude, longitude: start.longitude)) <= 30,
          CLLocation(latitude: last.latitude, longitude: last.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude)) <= 30 else {
        throw NSError(domain: "RouteSimulation", code: -2,
            userInfo: [NSLocalizedDescriptionKey: "The return path does not meet the selected endpoints."])
    }
    // MapKit can snap endpoints to nearby lanes. Keep short connections at
    // either end to avoid teleporting between legs; reject larger gaps above.
    if CoordinateSnapshot(first) != CoordinateSnapshot(start) { coordinates.insert(start, at: 0) }
    if CoordinateSnapshot(last) != CoordinateSnapshot(end) { coordinates.append(end) }
    return RouteSimulationPlan(displayCoordinates: coordinates, distance: route.distance,
        expectedTravelTime: route.expectedTravelTime, name: route.name)
}

// Calculate each consecutive leg so every selected stop is part of the path.
// Short lane snaps are connected; larger mismatches fail instead of teleporting.
private func multiStopPlan(start: CLLocationCoordinate2D, end: CLLocationCoordinate2D,
                           waypoints: [RouteWaypoint], mode: RouteTravelMode) async throws -> RouteSimulationPlan {
    guard waypoints.count <= RouteStopSchedule.maximumWaypoints,
          waypoints.allSatisfy({ RouteStopSchedule.validDuration($0.duration) }) else { throw URLError(.badURL) }
    let endpoints = [start] + waypoints.map { $0.selection.coordinate } + [end]
    var coordinates: [CLLocationCoordinate2D] = []
    var stops: [RouteScheduledStop] = []
    var legs: [RouteTrafficLeg] = []
    var distance = 0.0, idealTime = 0.0, geometryDistance = 0.0
    for index in 0..<(endpoints.count - 1) {
        try Task.checkCancellation()
        let source = endpoints[index], destination = endpoints[index + 1]
        guard distanceAlong([source, destination]) >= 1 else {
            throw NSError(domain: "RouteSimulation", code: -3, userInfo: [NSLocalizedDescriptionKey:
                "Consecutive stops must be at least one metre apart. Edit or remove the duplicate point."])
        }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: source))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = mode == .walking ? .walking : .automobile
        let directions = MKDirections(request: request)
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            directions.cancel()
        }
        let response: MKDirections.Response
        do {
            response = try await withTaskCancellationHandler { try await directions.calculate() } onCancel: { directions.cancel() }
            timeout.cancel()
        } catch { timeout.cancel(); throw error }
        try Task.checkCancellation()
        guard let route = response.routes.first else { throw URLError(.resourceUnavailable) }
        var part = sampledRouteCoordinates(from: route.polyline.coordinateArray,
            targetDistance: RouteSimulationDefaults.pathSamplingDistance)
        guard let first = part.first, let last = part.last, part.count > 1,
              distanceAlong([source, first]) <= 30, distanceAlong([last, destination]) <= 30 else {
            throw NSError(domain: "RouteSimulation", code: -4, userInfo: [NSLocalizedDescriptionKey:
                "Apple Maps could not reach stop \(index + 1) within 30 metres. Move the point onto an accessible road or path."])
        }
        if CoordinateSnapshot(first) != CoordinateSnapshot(source) { part.insert(source, at: 0) }
        if CoordinateSnapshot(last) != CoordinateSnapshot(destination) { part.append(destination) }
        geometryDistance += distanceAlong(part)
        if coordinates.isEmpty { coordinates = part } else { coordinates.append(contentsOf: part.dropFirst()) }
        guard coordinates.count <= 100_000 else { throw CoordinateImportError.tooLarge }
        distance += route.distance
        idealTime += route.expectedTravelTime
        legs.append(RouteTrafficLeg(start: source, end: destination, distance: route.distance, idealTime: route.expectedTravelTime))
        if index < waypoints.count {
            stops.append(RouteScheduledStop(distance: geometryDistance, duration: waypoints[index].duration,
                title: "Stop \(index + 1): " + waypoints[index].selection.title))
        }
    }
    return RouteSimulationPlan(displayCoordinates: coordinates, distance: distance,
        expectedTravelTime: idealTime, name: "Route with \(waypoints.count) stops",
        waypoints: waypoints, scheduledStops: stops, trafficLegs: legs)
}

private struct RoadContext {
    var ways: [OpenStreetMapWay] = []
    var signals: [CLLocationCoordinate2D] = []
}

private struct OpenStreetMapWay {
    let id: Int64
    let geometry: [CLLocationCoordinate2D]
    let genericSpeed: Double?
    let forwardSpeed: Double?
    let backwardSpeed: Double?
}

private enum OpenStreetMapSpeedLimitService {
    static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
    static let copyrightURL = URL(string: "https://www.openstreetmap.org/copyright")!
    static let boundingBoxPaddingDegrees = 0.0015
    static let nearestWayThreshold: CLLocationDistance = 40
}

private struct OverpassResponse: Decodable {
    let elements: [Element]

    struct Element: Decodable {
        let id: Int64?
        let tags: [String: String]?
        let geometry: [Coordinate]?
        let lat: Double?
        let lon: Double?
    }

    struct Coordinate: Decodable {
        let lat: Double
        let lon: Double
    }
}

private extension MKPolyline {
    var coordinateArray: [CLLocationCoordinate2D] {
        var coordinates = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            count: pointCount
        )
        getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        return coordinates
    }
}

private func interpolateCoordinate(
    from start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D,
    fraction: Double
) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(
        latitude: start.latitude + ((end.latitude - start.latitude) * fraction),
        longitude: start.longitude + ((end.longitude - start.longitude) * fraction)
    )
}

private func sampledRouteCoordinates(
    from coordinates: [CLLocationCoordinate2D],
    targetDistance: CLLocationDistance
) -> [CLLocationCoordinate2D] {
    guard coordinates.count > 1 else { return coordinates }

    var sampled = [coordinates[0]]
    for (start, end) in zip(coordinates, coordinates.dropFirst()) {
        let distance = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        guard !Task.isCancelled, distance.isFinite else { return [] }
        let segmentCount = max(1, Int(ceil(distance / targetDistance)))
        guard sampled.count + segmentCount <= 100_000 else { return [] }
        for index in 1...segmentCount {
            let point = interpolateCoordinate(
                from: start,
                to: end,
                fraction: Double(index) / Double(segmentCount)
            )
            if sampled.last.map(CoordinateSnapshot.init) != CoordinateSnapshot(point) {
                sampled.append(point)
            }
        }
    }

    return sampled
}

private func midpointCoordinate(
    from start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D
) -> CLLocationCoordinate2D {
    interpolateCoordinate(from: start, to: end, fraction: 0.5)
}

private func distanceAlong(_ coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
    zip(coordinates, coordinates.dropFirst()).reduce(0) { total, pair in
        total + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
            .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
    }
}

private func distanceFromPoint(
    _ point: MKMapPoint,
    toSegmentFrom start: MKMapPoint,
    to end: MKMapPoint
) -> CLLocationDistance {
    let dx = end.x - start.x
    let dy = end.y - start.y

    guard dx != 0 || dy != 0 else {
        return point.distance(to: start)
    }

    let projection = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / ((dx * dx) + (dy * dy))))
    let projectedPoint = MKMapPoint(
        x: start.x + (dx * projection),
        y: start.y + (dy * projection)
    )
    return point.distance(to: projectedPoint)
}

private func parseSpeedLimitMetersPerSecond(from rawValue: String) -> CLLocationSpeed? {
    let normalized = rawValue
        .lowercased()
        .split(separator: ";")
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard !normalized.isEmpty else { return nil }
    guard normalized != "none",
          normalized != "signals",
          normalized != "implicit",
          normalized != "walk" else {
        return nil
    }

    let scanner = Scanner(string: normalized)
    guard let numericValue = scanner.scanDouble(), numericValue.isFinite, numericValue > 0 else { return nil }

    if normalized.contains("mph") {
        return numericValue * 0.44704
    }
    if normalized.contains("knot") {
        return numericValue * 0.514444
    }

    return numericValue / 3.6
}

private func overpassQuery(for coordinates: [CLLocationCoordinate2D]) -> String? {
    guard let first = coordinates.first else { return nil }

    var minLatitude = first.latitude
    var maxLatitude = first.latitude
    var minLongitude = first.longitude
    var maxLongitude = first.longitude

    for coordinate in coordinates.dropFirst() {
        minLatitude = min(minLatitude, coordinate.latitude)
        maxLatitude = max(maxLatitude, coordinate.latitude)
        minLongitude = min(minLongitude, coordinate.longitude)
        maxLongitude = max(maxLongitude, coordinate.longitude)
    }

    let padding = OpenStreetMapSpeedLimitService.boundingBoxPaddingDegrees
    let south = minLatitude - padding
    let west = minLongitude - padding
    let north = maxLatitude + padding
    let east = maxLongitude + padding

    let bbox = String(format: "%.6f,%.6f,%.6f,%.6f", south, west, north, east)

    return """
    [out:json][timeout:20];
    (
      way(\(bbox))[highway][maxspeed];
      way(\(bbox))[highway]["maxspeed:forward"];
      way(\(bbox))[highway]["maxspeed:backward"];
      node(\(bbox))[highway=traffic_signals];
    );
    out tags geom;
    """
}

private func fetchRoadContext(for coordinates: [CLLocationCoordinate2D]) async throws -> RoadContext {
    guard let query = overpassQuery(for: coordinates) else { return RoadContext() }

    var components = URLComponents(url: OpenStreetMapSpeedLimitService.endpoint, resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "data", value: query)]
    guard let url = components?.url else { return RoadContext() }

    let request = URLRequest(url: url, timeoutInterval: 20)
    let (data, response) = try await URLSession.shared.data(for: request)

    if let httpResponse = response as? HTTPURLResponse,
       !(200...299).contains(httpResponse.statusCode) {
        throw NSError(
            domain: "OpenStreetMapSpeedLimits",
            code: httpResponse.statusCode,
            userInfo: [NSLocalizedDescriptionKey: "Overpass returned HTTP \(httpResponse.statusCode)."]
        )
    }

    let decoded = try JSONDecoder().decode(OverpassResponse.self, from: data)
    let ways = decoded.elements.compactMap { element -> OpenStreetMapWay? in
        guard let tags = element.tags,
              let geometry = element.geometry?.map({ CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }),
              geometry.count > 1 else {
            return nil
        }

        return OpenStreetMapWay(
            id: element.id ?? 0, geometry: geometry,
            genericSpeed: tags["maxspeed"].flatMap(parseSpeedLimitMetersPerSecond),
            forwardSpeed: tags["maxspeed:forward"].flatMap(parseSpeedLimitMetersPerSecond),
            backwardSpeed: tags["maxspeed:backward"].flatMap(parseSpeedLimitMetersPerSecond)
        )
    }
    let signals = decoded.elements.compactMap { element -> CLLocationCoordinate2D? in
        guard element.tags?["highway"] == "traffic_signals",
              let latitude = element.lat, let longitude = element.lon else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    return RoadContext(ways: ways, signals: signals)
}

private func nearestSpeedLimit(
    forSegmentFrom start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D,
    using ways: [OpenStreetMapWay], previousWay: inout Int64?
) -> CLLocationSpeed? {
    let midpoint = MKMapPoint(midpointCoordinate(from: start, to: end))
    let from = MKMapPoint(start), to = MKMapPoint(end)
    let dx = to.x - from.x, dy = to.y - from.y
    var best: (speed: Double, score: Double, way: Int64)?
    for way in ways {
        guard !Task.isCancelled else { return nil }
        for (a, b) in zip(way.geometry, way.geometry.dropFirst()) {
            let a = MKMapPoint(a), b = MKMapPoint(b)
            let wx = b.x - a.x, wy = b.y - a.y
            let denominator = hypot(dx, dy) * hypot(wx, wy)
            guard denominator > 0 else { continue }
            let alignment = (dx * wx + dy * wy) / denominator
            let separation = distanceFromPoint(midpoint, toSegmentFrom: a, to: b)
            guard let score = RouteRoadMatching.score(distance: separation, alignment: alignment, sameWay: previousWay == way.id),
                  let speed = RouteRoadMatching.speed(generic: way.genericSpeed, forward: way.forwardSpeed,
                      backward: way.backwardSpeed, alignment: alignment) else { continue }
            if best == nil || score < best!.score { best = (speed, score, way.id) }
        }
    }
    if let best { previousWay = best.way }
    return best?.speed
}

private func buildPlaybackSamples(
    from displayCoordinates: [CLLocationCoordinate2D], speedWays: [OpenStreetMapWay],
    fallbackSpeedMetersPerSecond: CLLocationSpeed
) -> [RoutePlaybackSample] {
    guard let first = displayCoordinates.first, displayCoordinates.count <= 100_000 else { return [] }
    let fallback = fallbackSpeedMetersPerSecond.isFinite && fallbackSpeedMetersPerSecond > 0
        ? min(200 / 3.6, max(0.5 / 3.6, fallbackSpeedMetersPerSecond)) : 5 / 3.6
    var samples = [RoutePlaybackSample(coordinate: first, delayFromPrevious: 0, speedMetersPerSecond: fallback)]
    var previousWay: Int64?
    for (start, end) in zip(displayCoordinates, displayCoordinates.dropFirst()) {
        guard !Task.isCancelled else { return [] }
        let distance = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        guard distance.isFinite, distance > 0 else { continue }
        let speed = nearestSpeedLimit(forSegmentFrom: start, to: end, using: speedWays,
            previousWay: &previousWay) ?? fallback
        samples.append(RoutePlaybackSample(coordinate: end, delayFromPrevious: distance / speed,
            distanceFromPrevious: distance, speedMetersPerSecond: speed))
    }
    return samples
}

private func prefetchRoutePlaybackSamples(
    displayCoordinates: [CLLocationCoordinate2D],
    fallbackSpeedMetersPerSecond: CLLocationSpeed,
    useRoadSpeeds: Bool,
    includeSignals: Bool
) async -> [RoutePlaybackSample] {
    let context = (useRoadSpeeds || includeSignals)
        ? ((try? await fetchRoadContext(for: displayCoordinates)) ?? RoadContext())
        : RoadContext()
    var samples = buildPlaybackSamples(
        from: displayCoordinates,
        speedWays: useRoadSpeeds ? context.ways : [],
        fallbackSpeedMetersPerSecond: fallbackSpeedMetersPerSecond
    )
    guard includeSignals, samples.count > 2 else { return samples }

    var offsets = [0.0]
    for sample in samples.dropFirst() { offsets.append(offsets.last! + sample.distanceFromPrevious) }
    var candidates: [(index: Int, offset: Double, separation: Double)] = []
    for signal in context.signals {
        guard !Task.isCancelled else { return [] }
        let location = CLLocation(latitude: signal.latitude, longitude: signal.longitude)
        let separations = samples.map { location.distance(from: CLLocation(
            latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)) }
        for index in 1..<(samples.count - 1) {
            // Each local minimum can be a separate visit, even at a junction
            // already crossed earlier in this leg.
            if separations[index] < 20 && separations[index] <= separations[index - 1]
                && separations[index] < separations[index + 1] {
                candidates.append((index, offsets[index], separations[index]))
            }
        }
    }
    for index in RouteSignalVisits.clustered(candidates) { samples[index].isTrafficSignal = true }
    return samples
}

private enum CoordinateImportError: LocalizedError {
    case emptyFile
    case noCoordinates
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .tooLarge:
            return "This route is too large. Use a file under 20 MB and a path with at most 100,000 vertices."
        case .emptyFile:
            return "The selected file is empty."
        case .noCoordinates:
            return "No valid coordinates were found. Use GPX, GeoJSON, JSON, CSV, or plain text with latitude and longitude values."
        }
    }
}

private enum CoordinateImportParser {
    static let supportedContentTypes: [UTType] = [
        .plainText,
        .commaSeparatedText,
        .json,
        .xml,
        UTType(filenameExtension: "gpx", conformingTo: .xml) ?? .xml,
        UTType(filenameExtension: "kml", conformingTo: .xml) ?? .xml,
        UTType(filenameExtension: "geojson", conformingTo: .json) ?? .json
    ]

    private enum CoordinateOrder {
        case latitudeLongitude
        case longitudeLatitude
    }

    static func parse(url: URL) throws -> [CLLocationCoordinate2D] {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 20_000_000 {
            throw CoordinateImportError.tooLarge
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 20_000_000 else { throw CoordinateImportError.tooLarge }
        guard !data.isEmpty else { throw CoordinateImportError.emptyFile }

        let fileExtension = url.pathExtension.lowercased()
        if fileExtension == "json" || fileExtension == "geojson" {
            if let coordinates = try? parseJSONCoordinates(from: data),
               !coordinates.isEmpty {
                return coordinates
            }
        }

        if fileExtension == "gpx" || fileExtension == "kml" || fileExtension == "xml" {
            let coordinates = parseXMLCoordinates(from: data)
            if !coordinates.isEmpty {
                return coordinates
            }
        }

        if let text = decodedText(from: data) {
            let coordinates = parseInline(text)
            if !coordinates.isEmpty {
                return coordinates
            }
        }

        if let coordinates = try? parseJSONCoordinates(from: data),
           !coordinates.isEmpty {
            return coordinates
        }

        let coordinates = parseXMLCoordinates(from: data)
        if !coordinates.isEmpty {
            return coordinates
        }

        throw CoordinateImportError.noCoordinates
    }

    static func parseInline(_ text: String) -> [CLLocationCoordinate2D] {
        sanitized(parseTextCoordinates(from: text))
    }

    private static func decodedText(from data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .ascii)
    }

    private static func sanitized(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []
        for coordinate in coordinates where CLLocationCoordinate2DIsValid(coordinate) {
            if result.last.map(CoordinateSnapshot.init) == CoordinateSnapshot(coordinate) {
                continue
            }
            result.append(coordinate)
        }
        return result
    }

    private static func coordinate(
        first: Double,
        second: Double,
        order: CoordinateOrder
    ) -> CLLocationCoordinate2D? {
        let preferred: CLLocationCoordinate2D
        let fallback: CLLocationCoordinate2D

        switch order {
        case .latitudeLongitude:
            preferred = CLLocationCoordinate2D(latitude: first, longitude: second)
            fallback = CLLocationCoordinate2D(latitude: second, longitude: first)
        case .longitudeLatitude:
            preferred = CLLocationCoordinate2D(latitude: second, longitude: first)
            fallback = CLLocationCoordinate2D(latitude: first, longitude: second)
        }

        if CLLocationCoordinate2DIsValid(preferred) {
            return preferred
        }
        if CLLocationCoordinate2DIsValid(fallback) {
            return fallback
        }
        return nil
    }

    private static func parseJSONCoordinates(from data: Data) throws -> [CLLocationCoordinate2D] {
        let object = try JSONSerialization.jsonObject(with: data)
        return sanitized(coordinates(fromJSONObject: object, order: .latitudeLongitude))
    }

    private static func coordinates(
        fromJSONObject object: Any,
        order: CoordinateOrder
    ) -> [CLLocationCoordinate2D] {
        if let dictionary = object as? [String: Any] {
            if let latitude = numberValue(forAnyKey: ["latitude", "lat"], in: dictionary),
               let longitude = numberValue(forAnyKey: ["longitude", "lon", "lng"], in: dictionary),
               let coordinate = coordinate(first: latitude, second: longitude, order: .latitudeLongitude) {
                return [coordinate]
            }

            if let geometry = dictionary["geometry"] {
                return coordinates(fromJSONObject: geometry, order: order)
            }

            if let type = dictionary["type"] as? String {
                let loweredType = type.lowercased()
                if loweredType == "featurecollection",
                   let features = dictionary["features"] as? [Any] {
                    return features.flatMap { coordinates(fromJSONObject: $0, order: .longitudeLatitude) }
                }
                if loweredType == "geometrycollection",
                   let geometries = dictionary["geometries"] as? [Any] {
                    return geometries.flatMap { coordinates(fromJSONObject: $0, order: .longitudeLatitude) }
                }
                if let coordinateObject = dictionary["coordinates"] {
                    return coordinates(fromJSONObject: coordinateObject, order: .longitudeLatitude)
                }
            }

            return dictionary.values.flatMap { coordinates(fromJSONObject: $0, order: order) }
        }

        if let array = object as? [Any] {
            if array.count >= 2,
               let first = numericValue(array[0]),
               let second = numericValue(array[1]),
               let coordinate = coordinate(first: first, second: second, order: order) {
                return [coordinate]
            }

            return array.flatMap { coordinates(fromJSONObject: $0, order: order) }
        }

        return []
    }

    private static func numericValue(_ value: Any) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func numberValue(forAnyKey keys: [String], in dictionary: [String: Any]) -> Double? {
        let keyedValues = Dictionary(uniqueKeysWithValues: dictionary.map { ($0.key.lowercased(), $0.value) })
        for key in keys {
            if let value = keyedValues[key],
               let number = numericValue(value) {
                return number
            }
        }
        return nil
    }

    private static func parseXMLCoordinates(from data: Data) -> [CLLocationCoordinate2D] {
        let collector = XMLCoordinateCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else { return [] }
        return sanitized(collector.coordinates)
    }

    private final class XMLCoordinateCollector: NSObject, XMLParserDelegate {
        var coordinates: [CLLocationCoordinate2D] = []
        private var isCollectingKMLCoordinates = false
        private var kmlCoordinateBuffer = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let name = elementName.lowercased()
            if ["wpt", "trkpt", "rtept"].contains(name),
               let latitude = Double(attributeDict["lat"] ?? ""),
               let longitude = Double(attributeDict["lon"] ?? ""),
               let coordinate = CoordinateImportParser.coordinate(
                    first: latitude,
                    second: longitude,
                    order: .latitudeLongitude
               ) {
                coordinates.append(coordinate)
            } else if name == "coordinates" {
                isCollectingKMLCoordinates = true
                kmlCoordinateBuffer = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if isCollectingKMLCoordinates {
                kmlCoordinateBuffer += string
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard elementName.lowercased() == "coordinates" else { return }
            coordinates.append(contentsOf: CoordinateImportParser.parseKMLCoordinateText(kmlCoordinateBuffer))
            isCollectingKMLCoordinates = false
            kmlCoordinateBuffer = ""
        }
    }

    private static func parseKMLCoordinateText(_ text: String) -> [CLLocationCoordinate2D] {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { token -> CLLocationCoordinate2D? in
                let values = token
                    .split(separator: ",")
                    .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                guard values.count >= 2 else { return nil }
                return coordinate(first: values[0], second: values[1], order: .longitudeLatitude)
            }
    }

    private static func parseTextCoordinates(from text: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        var headerIndices: (latitude: Int, longitude: Int)?

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let fields = splitFields(trimmed)
            if headerIndices == nil,
               let detectedHeader = detectHeader(in: fields) {
                headerIndices = detectedHeader
                continue
            }

            if let headerIndices,
               fields.indices.contains(headerIndices.latitude),
               fields.indices.contains(headerIndices.longitude),
               let latitude = numbers(in: fields[headerIndices.latitude]).first,
               let longitude = numbers(in: fields[headerIndices.longitude]).first,
               let coordinate = coordinate(first: latitude, second: longitude, order: .latitudeLongitude) {
                coordinates.append(coordinate)
                continue
            }

            let values = numbers(in: trimmed)
            if values.count >= 2,
               let coordinate = coordinate(first: values[0], second: values[1], order: .latitudeLongitude) {
                coordinates.append(coordinate)
            }
        }

        return coordinates
    }

    private static func splitFields(_ line: String) -> [String] {
        line
            .split { character in
                character == "," ||
                character == ";" ||
                character == "\t"
            }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func detectHeader(in fields: [String]) -> (latitude: Int, longitude: Int)? {
        let lowered = fields.map { $0.lowercased() }
        guard let latitude = lowered.firstIndex(where: { $0 == "lat" || $0 == "latitude" }),
              let longitude = lowered.firstIndex(where: { $0 == "lon" || $0 == "lng" || $0 == "long" || $0 == "longitude" }) else {
            return nil
        }
        return (latitude, longitude)
    }

    private static func numbers(in text: String) -> [Double] {
        let pattern = #"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return Double(text[matchRange])
        }
    }
}

// MARK: - Bookmark Model

struct LocationBookmark: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Search Completer

@MainActor
final class LocationSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()
    var region: MKCoordinateRegion? {
        didSet { if let region { completer.region = region } }
    }

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            completer.queryFragment = ""
            return
        }
        completer.queryFragment = query
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in self.results = results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }
}

struct LocationSimulationView: View {
    @ObservedObject private var simulationSession = LocationSimulationSession.shared
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)

    @State private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @State private var routeLoadTask: Task<Void, Never>?
    @State private var routeSpeedPrefetchTask: Task<Void, Never>?
    @State private var routePlaybackTask: Task<Void, Never>?
    @State private var isBusy = false
    @State private var isStopping = false
    @State private var locationCommandID = UUID()
    @State private var reconnectTask: Task<Void, Never>?
    @State private var resolvedSearchItems: [MKMapItem] = []
    @State private var showResolvedSearch = false
    @State private var trafficEstimateDate: Date?
    @State private var isLoadingRoute = false
    @State private var isPrefetchingRouteSpeeds = false
    @State private var isImportingCoordinates = false
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    @State private var searchText = ""
    @State private var searchRegion: MKCoordinateRegion?
    @State private var searchRequestID = UUID()
    @StateObject private var searchCompleter = LocationSearchCompleter()
    @State private var showCoordinateImporter = false
    @State private var showRouteSearch = false
    @State private var routeStartSelection: RouteSearchSelection?
    @State private var routeEndSelection: RouteSearchSelection?
    @State private var routeWaypoints: [RouteWaypoint] = []
    @State private var routePlan: RouteSimulationPlan?
    @State private var returnRoutePlan: RouteSimulationPlan?
    @State private var returnPlaybackSamples: [RoutePlaybackSample] = []
    @State private var routePolyline: MKPolyline?
    @State private var routePlaybackSamples: [RoutePlaybackSample] = []
    @State private var routePlaybackCoordinate: CLLocationCoordinate2D?
    @State private var simulatedCoordinate: CLLocationCoordinate2D?
    @State private var routeRequestID = UUID()
    @State private var preparationID = UUID()
    @AppStorage("routes.travelMode") private var travelMode: RouteTravelMode = .walking
    @AppStorage("routes.automaticSpeed") private var automaticSpeed = true
    @AppStorage("routes.customSpeedKilometersPerHour") private var customSpeedKilometersPerHour = 5.0
    @AppStorage("routes.repeatRoundTrip") private var repeatRoundTrip = false
    @State private var showRouteOptions = false
    @State private var useSatelliteMap = false
    @State private var alternativeRoutes: [RouteSimulationPlan] = []
    @State private var selectedRouteIndex = 0
    @State private var isImportedRoute = false
    @AppStorage("routes.simulateSignalStops") private var simulateSignalStops = true
    @AppStorage("routes.maximumSignalStop") private var maximumSignalStop = 45.0
    @AppStorage("routes.useTrafficEstimate") private var useTrafficEstimate = true
    @State private var trafficDelayMultiplier = 1.0
    @State private var trafficStatus = "Traffic estimate not loaded."
    @State private var playbackStatus: String?
    @State private var trafficRequest: MKDirections?

    private static let routeDurationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    // Bookmarks
    @State private var bookmarks: [LocationBookmark] = []
    @State private var showBookmarks = false
    @State private var showSaveBookmark = false
    @State private var newBookmarkName = ""

    private var pairingFilePath: String {
        PairingFileStore.prepareURL().path
    }

    private var pairingExists: Bool {
        FileManager.default.fileExists(atPath: pairingFilePath)
    }

    private var deviceIP: String {
        DeviceConnectionContext.targetIPAddress
    }

    private var routeStartCoordinate: CLLocationCoordinate2D? {
        routeStartSelection?.coordinate
    }

    private var routeEndCoordinate: CLLocationCoordinate2D? {
        routeEndSelection?.coordinate
    }

    private var hasActiveSimulation: Bool {
        simulationSession.connectionState != .stopped || simulationSession.gpsRestorationConfirmed == false ||
            simulationSession.isActive || simulatedCoordinate != nil || routePlaybackTask != nil
    }

    private var isRouteRunning: Bool {
        routePlaybackTask != nil || simulationSession.routeCoordinates != nil
    }

    private var hasRouteContext: Bool {
        routeStartSelection != nil ||
        routeEndSelection != nil ||
        routePlan != nil ||
        isLoadingRoute ||
        isPrefetchingRouteSpeeds ||
        routePlaybackCoordinate != nil ||
        simulationSession.routeCoordinates != nil
    }

    private var displayedRouteCoordinate: CLLocationCoordinate2D? {
        simulationSession.routeCoordinates == nil ? routePlaybackCoordinate : simulationSession.coordinate
    }

    private var routeSummaryText: String? {
        guard let routePlan else { return nil }
        let distanceText = Measurement(
            value: routePlan.distance / 1000,
            unit: UnitLength.kilometers
        ).formatted(.measurement(width: .abbreviated, usage: .road))
        let duration = (routePlaybackSamples.isEmpty
            ? routePlan.expectedTravelTime
            : routePlaybackSamples.reduce(0) { $0 + $1.delayFromPrevious })
            + routePlan.scheduledStops.reduce(0) { $0 + $1.duration }
        let durationText = Self.routeDurationFormatter.string(from: duration)
        if let durationText, !durationText.isEmpty {
            return "\(distanceText) • ETA \(durationText)"
        }
        return distanceText
    }

    private var routeStatusText: String {
        if simulationSession.routeCoordinates != nil {
            return playbackStatus ?? "Route simulation active."
        }
        if isLoadingRoute {
            return "Calculating route…"
        }
        if isPrefetchingRouteSpeeds {
            return "Preparing route and return journey…"
        }
        if routePlan != nil {
            return "Route ready."
        }
        if routeStartSelection != nil || routeEndSelection != nil {
            return "Pick both route endpoints to build the route."
        }
        return "Plan a route from the toolbar."
    }

    private var routeAttributionLink: some View {
        Link(
            "Speed limit data © OpenStreetMap contributors (ODbL)",
            destination: OpenStreetMapSpeedLimitService.copyrightURL
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var searchResultsListBase: some View {
        List(searchCompleter.results.prefix(10), id: \.self) { result in
            Button {
                selectSearchResult(result)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(.subheadline)
                    if !result.subtitle.isEmpty {
                        Text(result.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .frame(maxHeight: 350)
        .scrollDisabled(true)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var searchResultsList: some View {
        if #available(iOS 26, *) {
            searchResultsListBase
                .glassEffect(in: .rect(cornerRadius: 12))
        } else {
            searchResultsListBase
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            MapReader { proxy in
                Map(position: $position) {
                    if hasRouteContext {
                        if let routePolyline {
                            MapPolyline(routePolyline)
                                .stroke(.blue.opacity(0.8), lineWidth: 5)
                        }
                        if let returnRoutePlan,
                           let returnLine = makeRoutePolyline(for: returnRoutePlan.displayCoordinates) {
                            MapPolyline(returnLine)
                                .stroke(.orange.opacity(0.7), lineWidth: 4)
                        }
                        if let routeStartCoordinate {
                            Marker("Start", coordinate: routeStartCoordinate)
                                .tint(.green)
                        }
                        ForEach(Array(routeWaypoints.enumerated()), id: \.element.id) { index, stop in
                            Marker("Stop \(index + 1)", coordinate: stop.selection.coordinate).tint(.purple)
                        }
                        if let routeEndCoordinate {
                            Marker("End", coordinate: routeEndCoordinate)
                                .tint(.red)
                        }
                        if let displayedRouteCoordinate {
                            Marker("Current", coordinate: displayedRouteCoordinate)
                                .tint(.blue)
                        }
                    } else if let coordinate {
                        Marker("Pin", coordinate: coordinate)
                            .tint(.red)
                    }
                }
                .onMapCameraChange(frequency: .onEnd) { context in
                    searchRegion = context.region
                    searchCompleter.region = context.region
                }
                .mapStyle(useSatelliteMap ? .hybrid(elevation: .realistic) : .standard(elevation: .realistic))
                .onTapGesture { point in
                    if let loc = proxy.convert(point, from: .local) {
                        applySelection(loc)
                    }
                }
                .mapControls {
                    MapCompass()
                }
            }
                .ignoresSafeArea()
                .onChange(of: coordinate.map(CoordinateSnapshot.init)) { _, new in
                    if let new {
                        position = .region(
                            MKCoordinateRegion(
                                center: new.coordinate,
                                latitudinalMeters: 1000,
                                longitudinalMeters: 1000
                            )
                        )
                    }
                }

            VStack(spacing: 0) {
                if !searchCompleter.results.isEmpty {
                    searchResultsList
                }

                Spacer()

                VStack(spacing: 12) {
                    connectionStatusControls
                    if isImportingCoordinates {
                        ProgressView("Importing coordinates…")
                            .font(.footnote)
                    }

                    if hasRouteContext {
                        routeControls
                    } else {
                        pinControls
                    }
                }
                .padding(.bottom, 24)
                .padding(.horizontal, 16)
                .padding(.horizontal, 16)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button {
                    showBookmarks = true
                } label: {
                    Image(systemName: "bookmark.fill")
                }

                Button {
                    showRouteSearch = true
                } label: {
                    Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                }
                .disabled(isBusy || isRouteRunning)

                Button {
                    showCoordinateImporter = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .disabled(isBusy || isRouteRunning || isImportingCoordinates)
                .accessibilityLabel("Import Coordinates")

                Button {
                    showRouteOptions = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Route Options")
            }
            ToolbarItem(placement: .topBarTrailing) {
                TextField("Search location...", text: $searchText)
                    .padding(.leading, 6)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onChange(of: searchText) { _, newValue in
                        searchCompleter.update(query: newValue)
                    }
                    .onSubmit {
                        applyCoordinatesFromSearchText()
                    }
            }
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
        .alert("Save Bookmark", isPresented: $showSaveBookmark) {
            TextField("Name", text: $newBookmarkName)
            Button("Save") { addBookmark() }
            Button("Cancel", role: .cancel) { newBookmarkName = "" }
        } message: {
            Text("Enter a name for this location.")
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarksView(bookmarks: $bookmarks) { bookmark in
                applySelection(bookmark.coordinate)
                showBookmarks = false
            } onDelete: { offsets in
                bookmarks.remove(atOffsets: offsets)
                saveBookmarks()
            }
        }
        .sheet(isPresented: $showRouteSearch) {
            RouteSearchSheet(
                initialStart: routeStartSelection,
                initialEnd: routeEndSelection,
                initialWaypoints: routeWaypoints,
                searchRegion: searchRegion
            ) { startSelection, endSelection, waypoints in
                routeStartSelection = startSelection
                routeEndSelection = endSelection
                routeWaypoints = waypoints
                isImportedRoute = false
                refreshRoute()
            }
        }
        .sheet(isPresented: $showResolvedSearch) {
            LocationSearchResultsSheet(items: resolvedSearchItems) { item in
                applySelection(item.placemark.coordinate)
                showResolvedSearch = false
            }
        }
        .sheet(isPresented: $showRouteOptions) {
            routeOptionsSheet
        }
        .onChange(of: travelMode) { _, _ in
            if isImportedRoute {
                prepareRoutePlayback()
            } else {
                refreshRoute()
            }
        }
        .onChange(of: repeatRoundTrip) { _, _ in prepareRoutePlayback() }
        .onChange(of: simulationSession.routeCoordinates != nil) { _, hasRoute in
            if !hasRoute {
                cancelRoutePlayback(resetMarker: false)
                trafficRequest?.cancel()
                trafficRequest = nil
                playbackStatus = nil
            }
        }
        .onChange(of: automaticSpeed) { _, _ in prepareRoutePlayback() }
        .onChange(of: simulateSignalStops) { _, _ in prepareRoutePlayback() }
        .onChange(of: customSpeedKilometersPerHour) { _, _ in
            if !automaticSpeed { prepareRoutePlayback() }
        }
        .onChange(of: selectedRouteIndex) { _, index in
            guard alternativeRoutes.indices.contains(index) else { return }
            setRoutePlan(alternativeRoutes[index])
            prepareRoutePlayback()
            if let routePolyline { position = .rect(routePolyline.boundingMapRect) }
        }
        .fileImporter(
            isPresented: $showCoordinateImporter,
            allowedContentTypes: CoordinateImportParser.supportedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            importCoordinates(result)
        }
        .onAppear {
            loadBookmarks()
            if let routeCoordinates = simulationSession.routeCoordinates {
                coordinate = nil
                routePolyline = makeRoutePolyline(for: routeCoordinates)
                routeStartSelection = routeCoordinates.first.map {
                    RouteSearchSelection(title: "Route Start", coordinate: $0)
                }
                routeEndSelection = routeCoordinates.last.map {
                    RouteSearchSelection(title: "Route End", coordinate: $0)
                }
                if let routePolyline {
                    position = .rect(routePolyline.boundingMapRect)
                }
            } else if let activeCoordinate = simulationSession.coordinate {
                coordinate = activeCoordinate
                simulatedCoordinate = activeCoordinate
            }
            if !isRouteRunning {
                if routePlan != nil, routePlaybackSamples.isEmpty { prepareRoutePlayback() }
                else if routePlan == nil, routeStartSelection != nil, routeEndSelection != nil { refreshRoute() }
            }
        }
        .onDisappear {
            routeLoadTask?.cancel()
            routeLoadTask = nil
            routeSpeedPrefetchTask?.cancel()
            routeSpeedPrefetchTask = nil
            routeRequestID = UUID()
            preparationID = UUID()
            searchRequestID = UUID()
            isLoadingRoute = false
            isPrefetchingRouteSpeeds = false
            endBackgroundTask()
        }
    }

    // MARK: - Bookmarks

    private func loadBookmarks() {
        guard let data = UserDefaults.standard.data(forKey: "locationBookmarks"),
              let decoded = try? JSONDecoder().decode([LocationBookmark].self, from: data) else { return }
        bookmarks = decoded
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: "locationBookmarks")
        }
    }

    private func addBookmark() {
        guard let coord = coordinate else { return }
        let name = newBookmarkName.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookmark = LocationBookmark(
            name: name.isEmpty ? String(format: "%.4f, %.4f", coord.latitude, coord.longitude) : name,
            latitude: coord.latitude,
            longitude: coord.longitude
        )
        bookmarks.append(bookmark)
        saveBookmarks()
        newBookmarkName = ""
    }

    private func setRoutePlan(_ plan: RouteSimulationPlan?) {
        routePlan = plan
        returnRoutePlan = nil
        returnPlaybackSamples = []
        routePolyline = plan.flatMap { makeRoutePolyline(for: $0.displayCoordinates) }
    }

    private func makeRoutePolyline(for coordinates: [CLLocationCoordinate2D]) -> MKPolyline? {
        guard coordinates.count > 1 else { return nil }
        return coordinates.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return nil }
            return MKPolyline(coordinates: baseAddress, count: buffer.count)
        }
    }

    // MARK: - Location

    private func selectSearchResult(_ result: MKLocalSearchCompletion) {
        searchText = ""
        searchCompleter.results = []
        let requestID = UUID()
        searchRequestID = requestID
        let request = MKLocalSearch.Request(completion: result)
        Task {
            do {
                let items = try await searchLocations(request)
                guard searchRequestID == requestID, searchText.isEmpty, !isRouteRunning else { return }
                guard let item = items.first else { throw URLError(.resourceUnavailable) }
                applySelection(item.placemark.coordinate)
            } catch {
                guard searchRequestID == requestID, searchText.isEmpty else { return }
                alertTitle = "Address Not Found"
                alertMessage = "Try adding the city and country, or choose the point on the map. " + error.localizedDescription
                showAlert = true
            }
        }
    }

    private func applyCoordinatesFromSearchText() {
        let input = searchText
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isRouteRunning else { return }
        let lines = query.components(separatedBy: CharacterSet(charactersIn: ";\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let pairs = lines.compactMap(CoordinateText.parse)
        if pairs.count > 1, pairs.count == lines.count {
            searchText = ""
            searchCompleter.results = []
            applyImportedCoordinates(pairs.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }, sourceName: "Imported")
            return
        }
        if let pair = CoordinateText.parse(query) {
            searchText = ""
            searchCompleter.results = []
            applySelection(CLLocationCoordinate2D(latitude: pair.latitude, longitude: pair.longitude))
            return
        }
        let requestID = UUID()
        searchRequestID = requestID
        let region = searchRegion
        Task {
            do {
                let items = try await searchAddress(query, region: region)
                guard searchRequestID == requestID, searchText == input, !isRouteRunning else { return }
                guard !items.isEmpty else { throw URLError(.resourceUnavailable) }
                searchText = ""
                searchCompleter.results = []
                resolvedSearchItems = items
                showResolvedSearch = true
            } catch {
                guard searchRequestID == requestID, searchText == input else { return }
                alertTitle = "Address Not Found"
                alertMessage = "Add the city and country, enter latitude, longitude, or tap the map to choose an exact point. " + error.localizedDescription
                showAlert = true
            }
        }
    }

    private func importCoordinates(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let sourceName = url.deletingPathExtension().lastPathComponent
            isImportingCoordinates = true

            Task {
                do {
                    let coordinates = try await Task.detached(priority: .userInitiated) {
                        try CoordinateImportParser.parse(url: url)
                    }.value

                    await MainActor.run {
                        isImportingCoordinates = false
                        applyImportedCoordinates(
                            coordinates,
                            sourceName: sourceName.isEmpty ? "Imported" : sourceName
                        )
                    }
                } catch {
                    await MainActor.run {
                        isImportingCoordinates = false
                        showImportError(error)
                    }
                }
            }
        case .failure(let error):
            showImportError(error)
        }
    }

    private func applyImportedCoordinates(
        _ importedCoordinates: [CLLocationCoordinate2D],
        sourceName: String
    ) {
        guard !isRouteRunning else { return }

        guard importedCoordinates.count <= 100_000 else {
            showImportError(CoordinateImportError.tooLarge)
            return
        }
        let coordinates = importedCoordinates.filter(CLLocationCoordinate2DIsValid)
        guard let firstCoordinate = coordinates.first else {
            showImportError(CoordinateImportError.noCoordinates)
            return
        }

        if coordinates.count == 1 {
            applySelection(firstCoordinate)
            return
        }

        routeLoadTask?.cancel()
        routeLoadTask = nil
        routeSpeedPrefetchTask?.cancel()
        routeSpeedPrefetchTask = nil
        routeRequestID = UUID()
        setRoutePlan(nil)
        routePlaybackSamples = []
        routePlaybackCoordinate = nil
        isLoadingRoute = false
        isPrefetchingRouteSpeeds = false
        coordinate = nil

        let displayCoordinates = sampledRouteCoordinates(
            from: coordinates,
            targetDistance: RouteSimulationDefaults.pathSamplingDistance
        )

        guard displayCoordinates.count > 1,
              let lastCoordinate = displayCoordinates.last else {
            showImportError(CoordinateImportError.tooLarge)
            return
        }

        let distance = distanceAlong(displayCoordinates)
        let fallbackSpeed = RouteSimulationDefaults.importedRouteFallbackSpeedMetersPerSecond
        routeWaypoints = []
        routeStartSelection = RouteSearchSelection(title: "\(sourceName) Start", coordinate: firstCoordinate)
        routeEndSelection = RouteSearchSelection(title: "\(sourceName) End", coordinate: lastCoordinate)
        setRoutePlan(RouteSimulationPlan(
            displayCoordinates: displayCoordinates,
            distance: distance,
            expectedTravelTime: distance / fallbackSpeed
        ))

        if let routePolyline {
            position = .rect(routePolyline.boundingMapRect)
        }

        isImportedRoute = true
        alternativeRoutes = []
        prepareRoutePlayback()
    }

    private func showImportError(_ error: Error) {
        alertTitle = "Import Failed"
        alertMessage = error.localizedDescription
        showAlert = true
    }

    private var connectionStatusControls: some View {
        VStack(spacing: 4) {
            HStack {
                Text(simulationSession.connectionState.rawValue).font(.caption.weight(.semibold))
                if simulationSession.connectionState == .connecting { ProgressView().controlSize(.mini) }
                if simulationSession.connectionState == .disconnected {
                    Button("Retry connection", action: retryConnection).font(.caption)
                }
            }
            if let date = simulationSession.lastSuccessfulUpdate {
                HStack(spacing: 4) {
                    Text("Last successful update")
                    Text(date, style: .time)
                }.font(.caption2).foregroundStyle(.secondary)
            }
            if let message = simulationSession.gpsRestorationMessage {
                Text(message).font(.caption2).foregroundStyle(.secondary)
            }
            if let failure = simulationSession.lastFailure {
                DisclosureGroup("Connection details") {
                    Text(failure).font(.caption2).textSelection(.enabled)
                    Text("Target IP: " + deviceIP).font(.caption2)
                    Text("Last pairing lookup: " + RemotePairingPortResolver.lastAttemptDescription).font(.caption2)
                    Text(pairingExists ? "Pairing file available." : "Pairing file missing.").font(.caption2)
                }.font(.caption)
            }
        }
    }

    @ViewBuilder
    private var pinControls: some View {
        if let coord = coordinate {
            Text(String(format: "%.6f, %.6f", coord.latitude, coord.longitude))
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Stop", action: clear)
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(isStopping || !hasActiveSimulation)

                Button("Simulate Location", action: simulate)
                    .buttonStyle(.borderedProminent)
                    .disabled(!pairingExists || isBusy || isLoadingRoute)

                Button {
                    showSaveBookmark = true
                } label: {
                    Image(systemName: "bookmark")
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .disabled(isRouteRunning)
            }
        } else {
            Text("Tap map to drop pin")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var routeControls: some View {
        VStack(spacing: 10) {
            Text(routeStatusText)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if isLoadingRoute || isPrefetchingRouteSpeeds {
                ProgressView()
                    .controlSize(.small)
            } else if let routeSummaryText {
                Text(routeSummaryText)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }

            if let plan = routePlan, !plan.waypoints.isEmpty {
                Text("\(plan.waypoints.count) scheduled stops · \(Int(plan.scheduledStops.reduce(0) { $0 + $1.duration })) seconds waiting per direction")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if automaticSpeed && travelMode == .driving {
                routeAttributionLink
            }

            if alternativeRoutes.count > 1 {
                Picker("Route", selection: $selectedRouteIndex) {
                    ForEach(alternativeRoutes.indices, id: \.self) { index in
                        Text("\(index + 1). \(alternativeRoutes[index].name)").tag(index)
                    }
                }
                .disabled(isBusy || isRouteRunning || isLoadingRoute)
            }

            HStack {
                Label(travelMode == .walking ? "Walking" : "Driving",
                      systemImage: travelMode == .walking ? "figure.walk" : "car.fill")
                Spacer()
                Text(automaticSpeed ? "Automatic speed" : String(format: "%.1f km/h", customSpeedKilometersPerHour))
                if repeatRoundTrip { Image(systemName: "repeat") }
            }
            .font(.caption)

            if travelMode == .driving {
                Text(useTrafficEstimate ? trafficStatus : "Traffic adjustment off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let trafficEstimateDate {
                    HStack {
                        Text("Traffic estimate updated")
                        Text(trafficEstimateDate, style: .relative)
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                if simulateSignalStops {
                    Text("Mapped signals: \(routePlaybackSamples.filter(\.isTrafficSignal).count). Stops are simulated.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Route Options") { showRouteOptions = true }
                Button("Recalculate", action: refreshRoute)
                    .disabled(isImportedRoute || isBusy || isRouteRunning || isLoadingRoute)
            }
            .buttonStyle(.bordered)

            if travelMode == .driving, let destination = routePlan?.displayCoordinates.last,
               let url = WazeDestinationLink.url(latitude: destination.latitude, longitude: destination.longitude) {
                Link("Open destination in Waze", destination: url)
                    .font(.footnote)
                Text("Waze calculates its own route. Its traffic and route are not imported into this simulation.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if simulationSession.routeCoordinates != nil {
                if simulationSession.stopSecondsRemaining > 0 {
                    Text("\(simulationSession.stopTitle) · \(Int(ceil(simulationSession.stopSecondsRemaining))) s" +
                        (simulationSession.isPaused ? " (paused)" : ""))
                        .font(.caption).monospacedDigit()
                }
                ProgressView(value: simulationSession.legProgress)
                Text(String(format: "%@ · %.1f km/h · %.2f km left · %d round trips",
                    simulationSession.returning ? "Return" : "Outward",
                    simulationSession.currentSpeedKilometersPerHour,
                    simulationSession.remainingDistance / 1000, simulationSession.completedRoundTrips))
                    .font(.caption.monospaced())
                if let eta = Self.routeDurationFormatter.string(from: simulationSession.remainingTime) {
                    Text("Approx. time to this leg's end: " + eta + (simulationSession.isPaused ? " (paused)" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(simulationSession.isPaused ? "Resume" : "Pause") {
                    simulationSession.togglePause()
                }
                .buttonStyle(.bordered)
                .disabled(simulationSession.connectionState == .disconnected || simulationSession.connectionState == .connecting)
            }

            HStack(spacing: 12) {
                Button("Stop", action: clear)
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(isStopping || !hasActiveSimulation)

                Button("Play Route", action: simulateRoute)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !pairingExists ||
                        isBusy ||
                        isRouteRunning ||
                        isLoadingRoute ||
                        isPrefetchingRouteSpeeds ||
                        routePlan == nil ||
                        routePlaybackSamples.isEmpty
                    )

                Button("Reset", action: resetRouteSelection)
                    .buttonStyle(.bordered)
                    .disabled(isBusy || isRouteRunning)
            }
        }
    }

    private var routeOptionsSheet: some View {
        NavigationStack {
            Form {
                Section("Travel") {
                    Picker("Travel mode", selection: $travelMode) {
                        Label("Walking", systemImage: "figure.walk").tag(RouteTravelMode.walking)
                        Label("Driving", systemImage: "car.fill").tag(RouteTravelMode.driving)
                    }
                    Toggle("Automatic speed", isOn: $automaticSpeed)
                    if !automaticSpeed {
                        Text(String(format: "Speed: %.1f km/h", customSpeedKilometersPerHour))
                            .monospacedDigit()
                        Slider(value: $customSpeedKilometersPerHour, in: 0.5...200, step: 0.5) {
                            Text("Speed in kilometers per hour")
                        }
                        HStack {
                            Button("5 km/h") { customSpeedKilometersPerHour = 5 }
                            Button("15 km/h") { customSpeedKilometersPerHour = 15 }
                            Button("50 km/h") { customSpeedKilometersPerHour = 50 }
                        }
                        .buttonStyle(.bordered)
                    }
                    Text("Walking uses 5 km/h. Driving uses road speed limits when available. Custom speed overrides both.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .disabled(isBusy || isRouteRunning || isLoadingRoute || isImportingCoordinates)

                Section("Traffic and signals") {
                    Toggle("Slow down using Apple's traffic estimate", isOn: $useTrafficEstimate)
                    Toggle("Random stops near mapped signals", isOn: $simulateSignalStops)
                    if simulateSignalStops {
                        Text(String(format: "Maximum stop: %.0f seconds", maximumSignalStop))
                        Slider(value: $maximumSignalStop, in: 5...90, step: 5) {
                            Text("Maximum signal stop in seconds")
                        }
                    }
                    Text("Driving only. Signals come from OpenStreetMap; each pass has a 60% chance of a 5-second to maximum stop. The real light color is unknown. Traffic adjusts the primary route as a whole, not individual streets, and refreshes each leg. Imported and alternative routes use no traffic estimate.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .disabled(travelMode != .driving || isBusy || isRouteRunning || isLoadingRoute)

                Section("Repeat") {
                    Toggle("Repeat round trip", isOn: $repeatRoundTrip)
                        .disabled(isBusy || isRouteRunning)
                    Text("Driving calculates a separate return route with Apple Maps (orange line). Walking and imported paths retrace their original coordinates. Repeats until you tap Stop.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Mobile data connection") {
                    Text(MobileDataConnectionGuide.instructions)
                    Text(MobileDataConnectionGuide.limitation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Map") {
                    Toggle("Satellite map", isOn: $useSatelliteMap)
                    Text("Routes and map coverage are supplied by Apple Maps. Recalculate requests fresh directions and any available alternatives. Imported paths keep their original geometry.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Route Options")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showRouteOptions = false }
                }
            }
        }
    }

    private func simulate() {
        guard pairingExists, let coord = coordinate, !isBusy else { return }
        stopResendLoop()
        LocationSimulationSession.shared.clearRoute()
        simulationSession.markConnecting()
        runLocationCommand(
            errorTitle: "Simulation Failed",
            errorMessage: { code in
                locationSimulationErrorMessage(for: code)
            },
            operation: { locationUpdateCode(for: coord) }
        ) {
            routePlaybackCoordinate = nil
            beginBackgroundTask()
            LocationSimulationSession.shared.clearRoute()
            startResendLoop(with: coord)
        }
    }

    private func simulateRoute() {
        guard pairingExists,
              let routePlan,
              let firstCoordinate = routePlaybackSamples.first?.coordinate,
              !isBusy, !isRouteRunning, !isLoadingRoute, !isPrefetchingRouteSpeeds,
              routePlaybackSamples.count > 1 else {
            return
        }
        stopResendLoop()
        cancelRoutePlayback(resetMarker: false)
        simulationSession.markConnecting()
        runLocationCommand(
            errorTitle: "Route Simulation Failed",
            errorMessage: { code in
                locationSimulationErrorMessage(for: code)
            },
            operation: { locationUpdateCode(for: firstCoordinate) }
        ) {
            beginBackgroundTask()
            let routeID = LocationSimulationSession.shared.startRoute(
                at: firstCoordinate,
                coordinates: routePlan.displayCoordinates
            )
            simulatedCoordinate = nil
            routePlaybackCoordinate = firstCoordinate
            startRoutePlayback(
                routeID: routeID, plan: routePlan, samples: routePlaybackSamples,
                returnPlan: returnRoutePlan, returnSamples: returnPlaybackSamples,
                repeating: repeatRoundTrip
            )
        }
    }

    private func runLocationCommand(
        errorTitle: String, errorMessage: @escaping (Int32) -> String,
        operation: @escaping () -> Int32, onSuccess: @escaping () -> Void
    ) {
        let requestID = UUID()
        locationCommandID = requestID
        let generation = simulationSession.commandGeneration
        let token = generation.current()
        isBusy = true
        LocationSimulationCommandQueue.shared.async {
            let code = generation.isCurrent(token) ? operation() : Int32(-999)
            DispatchQueue.main.async {
                guard locationCommandID == requestID else { return }
                isBusy = false
                guard generation.isCurrent(token) else { return }
                if code == 0 { onSuccess() }
                else {
                    simulationSession.recordFailure(errorMessage(code))
                    alertTitle = errorTitle
                    alertMessage = errorMessage(code)
                    showAlert = true
                }
            }
        }
    }

    private func clear() {
        guard !isStopping else { return }
        routeLoadTask?.cancel()
        routeLoadTask = nil
        routeSpeedPrefetchTask?.cancel()
        routeSpeedPrefetchTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        preparationID = UUID()
        routeRequestID = UUID()
        locationCommandID = UUID()
        isLoadingRoute = false
        isPrefetchingRouteSpeeds = false
        isBusy = false
        cancelRoutePlayback(resetMarker: true)
        trafficRequest?.cancel()
        trafficRequest = nil
        playbackStatus = nil
        stopResendLoop()
        // Stop all local work immediately, even without pairing or a live
        // location service. The remote reset is a separate confirmation.
        simulationSession.stop()
        endBackgroundTask()
        let generation = simulationSession.commandGeneration
        let token = generation.current()
        isStopping = true
        LocationSimulationCommandQueue.shared.async {
            let code = generation.isCurrent(token) ? clear_simulated_location() : Int32(-999)
            DispatchQueue.main.async {
                isStopping = false
                guard generation.isCurrent(token) else { return }
                simulationSession.confirmGPSRestoration(code == 0)
            }
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { endBackgroundTask() }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func startResendLoop(with coordinate: CLLocationCoordinate2D) {
        simulatedCoordinate = coordinate
        LocationSimulationSession.shared.startResending(at: coordinate) {
            locationUpdateCode(for: coordinate)
        }
    }

    private func stopResendLoop() {
        LocationSimulationSession.shared.pauseResending()
        simulatedCoordinate = nil
    }

    private func cancelRoutePlayback(resetMarker: Bool) {
        routePlaybackTask?.cancel()
        routePlaybackTask = nil
        if resetMarker {
            routePlaybackCoordinate = nil
        }
    }

    private func applySelection(_ coordinate: CLLocationCoordinate2D) {
        guard !isRouteRunning else { return }
        searchRequestID = UUID()
        if hasRouteContext {
            resetRouteSelection()
        }
        self.coordinate = coordinate
    }

    private func resetRouteSelection() {
        routeLoadTask?.cancel()
        routeLoadTask = nil
        routeSpeedPrefetchTask?.cancel()
        routeSpeedPrefetchTask = nil
        routeRequestID = UUID()
        preparationID = UUID()
        alternativeRoutes = []
        isImportedRoute = false
        setRoutePlan(nil)
        routeWaypoints = []
        routeStartSelection = nil
        routeEndSelection = nil
        routePlaybackSamples = []
        routePlaybackCoordinate = nil
        isLoadingRoute = false
        isPrefetchingRouteSpeeds = false
    }

    private func refreshRoute() {
        guard !isRouteRunning, !isImportedRoute else { return }
        routeLoadTask?.cancel()
        routeSpeedPrefetchTask?.cancel()
        preparationID = UUID()
        alternativeRoutes = []
        setRoutePlan(nil)
        routePlaybackSamples = []

        guard let routeStart = routeStartSelection?.coordinate,
              let routeEnd = routeEndSelection?.coordinate else {
            isLoadingRoute = false
            isPrefetchingRouteSpeeds = false
            return
        }

        let requestID = UUID()
        routeRequestID = requestID
        isLoadingRoute = true
        isPrefetchingRouteSpeeds = false

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: routeStart))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: routeEnd))
        request.requestsAlternateRoutes = true
        request.transportType = travelMode == .walking ? .walking : .automobile

        let waypoints = routeWaypoints
        let mode = travelMode
        routeLoadTask = Task {
            do {
                let plans: [RouteSimulationPlan]
                if !waypoints.isEmpty {
                    plans = [try await multiStopPlan(start: routeStart, end: routeEnd, waypoints: waypoints, mode: mode)]
                } else {
                let directions = MKDirections(request: request)
                let response = try await withTaskCancellationHandler { try await directions.calculate() } onCancel: { directions.cancel() }
                guard !Task.isCancelled else { return }
                plans = response.routes.compactMap { route -> RouteSimulationPlan? in
                    let coordinates = sampledRouteCoordinates(
                        from: route.polyline.coordinateArray,
                        targetDistance: RouteSimulationDefaults.pathSamplingDistance
                    )
                    guard coordinates.count > 1 else { return nil }
                    return RouteSimulationPlan(
                        displayCoordinates: coordinates,
                        distance: route.distance,
                        expectedTravelTime: route.expectedTravelTime,
                        name: route.name
                    )
                }
                }
                guard !Task.isCancelled else { return }
                guard let firstPlan = plans.first else {
                    throw NSError(
                        domain: "RouteSimulation", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "No route was found for this travel mode. Try another destination or travel mode."]
                    )
                }

                await MainActor.run {
                    guard routeRequestID == requestID else { return }
                    alternativeRoutes = plans
                    selectedRouteIndex = 0
                    setRoutePlan(firstPlan)
                    isLoadingRoute = false
                    prepareRoutePlayback()
                    if let routePolyline { position = .rect(routePolyline.boundingMapRect) }
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard routeRequestID == requestID else { return }
                    isLoadingRoute = false
                    isPrefetchingRouteSpeeds = false
                }
            } catch {
                await MainActor.run {
                    guard routeRequestID == requestID else { return }
                    isLoadingRoute = false
                    isPrefetchingRouteSpeeds = false
                    alertTitle = "Route Failed"
                    alertMessage = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }

    private func prepareRoutePlayback() {
        guard !isRouteRunning else { return }
        routeSpeedPrefetchTask?.cancel()
        let requestID = UUID()
        preparationID = requestID
        routePlaybackSamples = []
        returnRoutePlan = nil
        returnPlaybackSamples = []
        guard let routePlan else {
            isPrefetchingRouteSpeeds = false
            return
        }

        let useRoadSpeeds = automaticSpeed && travelMode == .driving
        let includeSignals = simulateSignalStops && travelMode == .driving
        let needsDrivingReturn = repeatRoundTrip && travelMode == .driving && !isImportedRoute
        let needsImportedReturn = repeatRoundTrip && travelMode == .driving && isImportedRoute
        let chosenSpeed: Double? = !automaticSpeed
            ? RoutePlaybackTiming.metersPerSecond(kilometersPerHour: customSpeedKilometersPerHour)
            : travelMode == .walking ? 5 / 3.6 : nil

        isPrefetchingRouteSpeeds = true
        routeSpeedPrefetchTask = Task.detached(priority: .utility) {
            do {
                let reversePlan: RouteSimulationPlan?
                if needsDrivingReturn { reversePlan = try await drivingReturnPlan(for: routePlan) }
                else if needsImportedReturn {
                    reversePlan = RouteSimulationPlan(displayCoordinates: Array(routePlan.displayCoordinates.reversed()),
                        distance: routePlan.distance, expectedTravelTime: routePlan.expectedTravelTime, name: routePlan.name)
                } else { reversePlan = nil }
                async let outward = preparedSamples(for: routePlan, chosenSpeed: chosenSpeed,
                    useRoadSpeeds: useRoadSpeeds, includeSignals: includeSignals)
                async let inward = preparedSamples(for: reversePlan, chosenSpeed: chosenSpeed,
                    useRoadSpeeds: useRoadSpeeds, includeSignals: includeSignals)
                let (samples, reverseSamples) = await (outward, inward)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard preparationID == requestID else { return }
                    routePlaybackSamples = samples
                    returnRoutePlan = reversePlan
                    returnPlaybackSamples = reverseSamples
                    isPrefetchingRouteSpeeds = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard preparationID == requestID else { return }
                    isPrefetchingRouteSpeeds = false
                    alertTitle = "Return Route Unavailable"
                    alertMessage = "Could not prepare a driving return route. Retry or turn off Repeat round trip. " + error.localizedDescription
                    showAlert = true
                }
            }
        }
    }

    private func startRoutePlayback(
        routeID: UUID, plan: RouteSimulationPlan, samples: [RoutePlaybackSample],
        returnPlan: RouteSimulationPlan?, returnSamples: [RoutePlaybackSample], repeating: Bool
    ) {
        guard let outward = streamingPath(samples) else { return }
        let inward = streamingPath(returnSamples) ?? outward.reversed()
        let driving = travelMode == .driving
        let signalStops = simulateSignalStops && driving
        let maxStop = maximumSignalStop
        routePlaybackTask = Task {
            let session = LocationSimulationSession.shared
            let clock = ContinuousClock()
            var returning = false
            repeat {
                let path = returning ? inward : outward
                let legPlan = returning ? (returnPlan ?? plan) : plan
                // Hold the endpoint while Apple calculates the next ETA.
                let trafficHold = Task {
                    while !Task.isCancelled && session.isCurrentRoute(routeID) {
                        do { try await Task.sleep(for: .seconds(4)) } catch { return }
                        guard !Task.isCancelled, session.isCurrentRoute(routeID),
                              session.connectionState != .disconnected,
                              let coordinate = session.coordinate else { return }
                        let code = await sendLocationUpdate(for: coordinate)
                        guard !Task.isCancelled, session.isCurrentRoute(routeID) else { return }
                        if code == 0 { session.recordSuccessfulUpdate(coordinate) }
                        else { session.recordFailure(locationSimulationErrorMessage(for: code)); return }
                    }
                }
                await updateTrafficEstimate(plan: legPlan, routeID: routeID)
                trafficHold.cancel()
                guard !Task.isCancelled, session.isCurrentRoute(routeID) else { return }
                let slowdown = trafficDelayMultiplier
                let randomStops: [RouteScheduledStop] = signalStops ? path.signalIndices.compactMap { index in
                    let duration = RouteTrafficBehavior.signalStopDuration(chanceRoll: Double.random(in: 0..<1),
                        durationRoll: Double.random(in: 0...1), maximum: maxStop)
                    return duration > 0 ? RouteScheduledStop(distance: path.cumulative[index], duration: duration, title: "Simulated signal stop") : nil
                } : []
                let plannedStops = returning && returnPlan == nil
                    ? RouteStopSchedule.reversed(plan.scheduledStops, length: outward.length) : legPlan.scheduledStops
                let stops = RouteStopSchedule.ordered(plannedStops, signals: randomStops, length: path.length)
                var stopIndex = 0
                var signalPause = 0.0
                var stopTitle = ""
                var motion = RouteMotionState()
                var lastTick = clock.now
                var lastHoldSend = clock.now
                var deadline = clock.now

                while motion.distance < path.length || signalPause > 0 {
                    guard !Task.isCancelled, session.isCurrentRoute(routeID) else { return }
                    if session.connectionState == .disconnected || session.reconnectRequested {
                        motion.speed = 0
                        if session.reconnectRequested, let coordinate = session.coordinate {
                            _ = await reconnectLocation(at: coordinate, routeID: routeID)
                        } else {
                            do { try await Task.sleep(for: .seconds(0.5)) } catch { return }
                        }
                        lastTick = clock.now
                        deadline = clock.now
                        lastHoldSend = clock.now
                        continue
                    }

                    deadline = max(deadline.advanced(by: .seconds(0.5)), clock.now)
                    do { try await clock.sleep(until: deadline) } catch { return }
                    guard !Task.isCancelled, session.isCurrentRoute(routeID) else { return }
                    let elapsed = min(1, lastTick.duration(to: clock.now).timeInterval)
                    lastTick = clock.now
                    if session.isPaused || signalPause > 0 {
                        motion.speed = 0
                        signalPause = RouteStopSchedule.remaining(signalPause, elapsed: elapsed, paused: session.isPaused)
                        playbackStatus = session.isPaused ? "Route paused." : "\(stopTitle) · \(Int(ceil(signalPause))) s remaining"
                        session.updateStop(title: stopTitle, remaining: signalPause)
                        if lastHoldSend.duration(to: clock.now).timeInterval >= 4,
                           let coordinate = session.coordinate {
                            let code = await sendLocationUpdate(for: coordinate)
                            guard !Task.isCancelled, session.isCurrentRoute(routeID) else { return }
                            if code == 0 { session.recordSuccessfulUpdate(coordinate) }
                            else { session.recordFailure(locationSimulationErrorMessage(for: code)) }
                            lastHoldSend = clock.now
                        }
                    } else {
                        playbackStatus = nil
                        session.updateStop(title: "", remaining: 0)
                        let nextStop = stopIndex < stops.count ? stops[stopIndex].distance : path.length
                        let next = path.advance(motion, elapsed: elapsed, slowdown: slowdown,
                            stopAt: nextStop, driving: driving)
                        let point = path.point(at: next.distance)
                        let coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
                        let code = await sendLocationUpdate(for: coordinate)
                        guard !Task.isCancelled, session.isCurrentRoute(routeID) else { return }
                        guard code == 0 else {
                            session.recordFailure(locationSimulationErrorMessage(for: code))
                            continue
                        }
                        motion = next
                        routePlaybackCoordinate = coordinate
                        session.recordSuccessfulUpdate(coordinate)
                        lastHoldSend = clock.now
                        if stopIndex < stops.count, motion.distance >= stops[stopIndex].distance {
                            signalPause = stops[stopIndex].duration
                            stopTitle = stops[stopIndex].title
                            session.updateStop(title: stopTitle, remaining: signalPause)
                            stopIndex += 1
                        }
                    }
                    let futureStops = stops.dropFirst(stopIndex).reduce(0) { $0 + $1.duration }
                    session.updateProgress(distance: motion.distance, length: path.length, speed: motion.speed,
                        eta: path.remainingTime(at: motion.distance, slowdown: slowdown) + futureStops + signalPause,
                        returning: returning)
                }
                if returning { session.completedReturn() }
                returning.toggle()
            } while repeating && !Task.isCancelled && session.isCurrentRoute(routeID)

            guard !Task.isCancelled, session.isCurrentRoute(routeID) else { return }
            routePlaybackTask = nil
            session.clearRoute()
            session.updateProgress(distance: 1, length: 1, speed: 0, eta: 0, returning: false)
            if let coordinate = session.coordinate { startResendLoop(with: coordinate) }
        }
        if let task = routePlaybackTask { simulationSession.attachPlaybackTask(task, routeID: routeID) }
    }

    private func reconnectLocation(at coordinate: CLLocationCoordinate2D, routeID: UUID?) async -> Bool {
        let generation = simulationSession.commandGeneration
        let token = generation.current()
        var lastCode: Int32 = -999
        for attempt in 0..<3 {
            guard !Task.isCancelled, generation.isCurrent(token),
                  routeID.map({ simulationSession.isCurrentRoute($0) }) ?? true else { return false }
            if attempt > 0 {
                do { try await Task.sleep(for: .seconds(Double(attempt))) } catch { return false }
            }
            guard !Task.isCancelled, generation.isCurrent(token) else { return false }
            lastCode = await sendLocationUpdate(for: coordinate)
            guard !Task.isCancelled, generation.isCurrent(token) else { return false }
            if lastCode == 0 {
                simulationSession.recordSuccessfulUpdate(coordinate)
                simulationSession.finishReconnect()
                if routeID == nil { startResendLoop(with: coordinate) }
                return true
            }
        }
        guard generation.isCurrent(token) else { return false }
        simulationSession.recordFailure("Three connection attempts failed. " + locationSimulationErrorMessage(for: lastCode))
        return false
    }

    private func retryConnection() {
        guard !isStopping, !isBusy, simulationSession.connectionState == .disconnected else { return }
        simulationSession.requestReconnect()
        if simulationSession.routeCoordinates != nil { return }
        guard let coordinate = simulationSession.coordinate ?? self.coordinate else {
            simulationSession.recordFailure("Select a point before retrying the connection.")
            return
        }
        reconnectTask?.cancel()
        reconnectTask = Task { _ = await reconnectLocation(at: coordinate, routeID: nil) }
    }

    private func updateTrafficEstimate(plan: RouteSimulationPlan, routeID: UUID) async {
        trafficDelayMultiplier = 1
        trafficEstimateDate = nil
        guard travelMode == .driving, useTrafficEstimate, !isImportedRoute,
              selectedRouteIndex == 0,
              let start = plan.displayCoordinates.first,
              let end = plan.displayCoordinates.last else {
            trafficStatus = "Traffic estimate unavailable for this route or mode."
            return
        }
        playbackStatus = "Updating traffic estimate…"
        defer {
            if LocationSimulationSession.shared.isCurrentRoute(routeID) {
                trafficRequest = nil
                playbackStatus = nil
            }
        }
        let legs = plan.trafficLegs.isEmpty
            ? [RouteTrafficLeg(start: start, end: end, distance: plan.distance, idealTime: plan.expectedTravelTime)]
            : plan.trafficLegs
        var totalTraffic = 0.0, totalIdeal = 0.0
        for (index, leg) in legs.enumerated() {
            guard !Task.isCancelled, LocationSimulationSession.shared.isCurrentRoute(routeID) else { return }
            playbackStatus = "Updating traffic: leg \(index + 1)/\(legs.count)…"
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: leg.start))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: leg.end))
            request.transportType = .automobile
            request.departureDate = Date()
            let directions = MKDirections(request: request)
            trafficRequest = directions
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                directions.cancel()
            }
            do {
                let eta = try await withTaskCancellationHandler { try await directions.calculateETA() } onCancel: { directions.cancel() }
                timeout.cancel()
                guard !Task.isCancelled, LocationSimulationSession.shared.isCurrentRoute(routeID) else { return }
                guard leg.distance > 0, abs(eta.distance - leg.distance) / leg.distance <= 0.05 else {
                    trafficStatus = "Traffic estimate unavailable for this path; keeping selected speed."
                    return
                }
                totalTraffic += eta.expectedTravelTime
                totalIdeal += leg.idealTime
            } catch {
                timeout.cancel()
                guard !Task.isCancelled, LocationSimulationSession.shared.isCurrentRoute(routeID) else { return }
                trafficStatus = "Traffic estimate unavailable; keeping selected speed."
                return
            }
        }
        trafficDelayMultiplier = RouteTrafficBehavior.slowdown(idealTime: totalIdeal, trafficTime: totalTraffic)
        trafficEstimateDate = Date()
        trafficStatus = String(format: "Approximate route-wide traffic: %.1f× travel time.", trafficDelayMultiplier)
    }

    private func sendLocationUpdate(for coordinate: CLLocationCoordinate2D) async -> Int32 {
        let generation = LocationSimulationSession.shared.commandGeneration
        let token = generation.current()
        let ip = deviceIP
        let pairingPath = pairingFilePath
        return await withCheckedContinuation { continuation in
            LocationSimulationCommandQueue.shared.async {
                guard generation.isCurrent(token) else {
                    continuation.resume(returning: Int32(-999))
                    return
                }
                continuation.resume(returning: simulate_location(ip, coordinate.latitude, coordinate.longitude, pairingPath))
            }
        }
    }

    private func locationUpdateCode(for coordinate: CLLocationCoordinate2D) -> Int32 {
        simulate_location(deviceIP, coordinate.latitude, coordinate.longitude, pairingFilePath)
    }
}

// Direct search complements autocomplete; neither is an offline address list.
private func searchAddress(_ query: String, region: MKCoordinateRegion?) async throws -> [MKMapItem] {
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = query
    request.resultTypes = [.address, .pointOfInterest]
    if let region { request.region = region }
    return try await searchLocations(request)
}

private func searchLocations(_ request: MKLocalSearch.Request) async throws -> [MKMapItem] {
    let search = MKLocalSearch(request: request)
    let timeout = Task {
        do { try await Task.sleep(for: .seconds(15)) } catch { return }
        search.cancel()
    }
    defer { timeout.cancel() }
    return try await withTaskCancellationHandler {
        try await search.start().mapItems
    } onCancel: { search.cancel() }
}

private struct RouteSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let searchRegion: MKCoordinateRegion?
    let onApply: (RouteSearchSelection, RouteSearchSelection, [RouteWaypoint]) -> Void
    @StateObject private var startCompleter = LocationSearchCompleter()
    @StateObject private var endCompleter = LocationSearchCompleter()
    @State private var waypoints: [RouteWaypoint]
    @State private var showStopEditor = false
    @State private var editingStopID: UUID?
    @State private var startQuery: String
    @State private var endQuery: String
    @State private var startSelection: RouteSearchSelection?
    @State private var endSelection: RouteSearchSelection?
    @State private var resolvingTask: Task<Void, Never>?
    @State private var resolutionID = UUID()
    @State private var isResolvingSelection = false
    @State private var errorMessage: String?
    @State private var foundItems: [MKMapItem] = []
    @State private var foundItemsField: RouteSearchField = .start
    @State private var mapPickerField: RouteSearchField?
    @FocusState private var focusedField: RouteSearchField?

    init(initialStart: RouteSearchSelection?, initialEnd: RouteSearchSelection?,
         initialWaypoints: [RouteWaypoint], searchRegion: MKCoordinateRegion?,
         onApply: @escaping (RouteSearchSelection, RouteSearchSelection, [RouteWaypoint]) -> Void) {
        self.searchRegion = searchRegion
        self.onApply = onApply
        _waypoints = State(initialValue: Array(initialWaypoints.prefix(RouteStopSchedule.maximumWaypoints)))
        _startQuery = State(initialValue: initialStart?.title ?? "")
        _endQuery = State(initialValue: initialEnd?.title ?? "")
        _startSelection = State(initialValue: initialStart)
        _endSelection = State(initialValue: initialEnd)
    }

    private var activeResults: [MKLocalSearchCompletion] {
        switch focusedField {
        case .start: return startCompleter.results
        case .end: return endCompleter.results
        case .none: return []
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    routeField(title: "Start", text: $startQuery, selection: startSelection, field: .start)
                    waypointControls
                    routeField(title: "End", text: $endQuery, selection: endSelection, field: .end)
                    Text("Include city and country for better matches. You can also enter latitude, longitude or choose either endpoint on the map.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    }
                    if isResolvingSelection {
                        ProgressView("Searching address…")
                    } else if !foundItems.isEmpty {
                        ForEach(foundItems.indices, id: \.self) { index in
                            let item = foundItems[index]
                            Button {
                                select(item, field: foundItemsField)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(item.name ?? "Location")
                                    Text(item.placemark.title ?? "")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Divider()
                        }
                    } else {
                        ForEach(Array(activeResults.enumerated()), id: \.element) { _, result in
                            Button { resolve(result, field: focusedField ?? .start) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.title)
                                    Text(result.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Divider()
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Simulate Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Route") {
                        guard let startSelection, let endSelection else { return }
                        onApply(startSelection, endSelection, waypoints)
                        dismiss()
                    }
                    .disabled(startSelection == nil || endSelection == nil || isResolvingSelection)
                }
            }
        }
        .presentationDetents([.large])
        .sheet(isPresented: $showStopEditor) {
            RouteStopEditor(initial: waypoints.first { $0.id == editingStopID }, region: searchRegion) { stop in
                if let index = waypoints.firstIndex(where: { $0.id == stop.id }) { waypoints[index] = stop }
                else if waypoints.count < RouteStopSchedule.maximumWaypoints { waypoints.append(stop) }
            }
        }
        .sheet(item: $mapPickerField) { field in
            RouteEndpointPicker(
                title: field == .start ? "Choose Start" : "Choose Destination",
                coordinate: (field == .start ? startSelection : endSelection)?.coordinate,
                region: searchRegion
            ) { coordinate in
                let title = String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)
                apply(RouteSearchSelection(title: title, coordinate: coordinate), field: field)
            }
        }
        .onAppear {
            startCompleter.region = searchRegion
            endCompleter.region = searchRegion
            if startSelection == nil { focusedField = .start }
            else if endSelection == nil { focusedField = .end }
        }
        .onDisappear { invalidateSearch() }
    }

    private var waypointControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Intermediate stops (\(waypoints.count)/5)").font(.headline)
            Text("Visited in this order. Repeat visits them in reverse order on the return, with the same waiting times.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(waypoints.enumerated()), id: \.element.id) { index, stop in
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        invalidateSearch(); focusedField = nil
                        editingStopID = stop.id; showStopEditor = true
                    } label: {
                        VStack(alignment: .leading) {
                            Text("\(index + 1). " + stop.selection.title).lineLimit(2)
                            Text("Wait \(Int(stop.duration)) seconds").font(.caption)
                        }
                    }
                    HStack {
                        Button("Move up") { waypoints.swapAt(index, index - 1) }.disabled(index == 0)
                        Button("Move down") { waypoints.swapAt(index, index + 1) }.disabled(index == waypoints.count - 1)
                        Button("Remove", role: .destructive) { waypoints.removeAll { $0.id == stop.id } }
                    }.font(.caption).buttonStyle(.bordered)
                }
                Divider()
            }
            Button("Add stop") {
                invalidateSearch(); focusedField = nil
                editingStopID = nil; showStopEditor = true
            }.buttonStyle(.bordered).disabled(waypoints.count >= RouteStopSchedule.maximumWaypoints)
        }
    }

    private func routeField(title: String, text: Binding<String>, selection: RouteSearchSelection?,
                            field: RouteSearchField) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField("Address, city or latitude, longitude", text: text)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused($focusedField, equals: field)
                .submitLabel(.search)
                .onChange(of: text.wrappedValue) { _, query in update(query, field: field) }
                .onSubmit { resolveTyped(field: field) }
            HStack {
                Button("Search address") { resolveTyped(field: field) }
                    .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Choose on map") {
                    invalidateSearch()
                    focusedField = nil
                    mapPickerField = field
                }
            }
            .buttonStyle(.bordered).font(.caption)
            if let selection {
                Text(String(format: "%.5f, %.5f", selection.coordinate.latitude, selection.coordinate.longitude))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    private func invalidateSearch() {
        resolvingTask?.cancel()
        resolutionID = UUID()
        isResolvingSelection = false
        foundItems = []
    }

    private func update(_ query: String, field: RouteSearchField) {
        // Programmatic selection updates must not invalidate their own result.
        let selected = field == .start ? startSelection : endSelection
        guard query != selected?.title else { return }
        invalidateSearch()
        errorMessage = nil
        if field == .start { startSelection = nil; startCompleter.update(query: query) }
        else { endSelection = nil; endCompleter.update(query: query) }
    }

    private func apply(_ selection: RouteSearchSelection, field: RouteSearchField) {
        invalidateSearch()
        errorMessage = nil
        if field == .start {
            startSelection = selection
            startQuery = selection.title
            startCompleter.update(query: "")
            focusedField = .end
        } else {
            endSelection = selection
            endQuery = selection.title
            endCompleter.update(query: "")
            focusedField = nil
        }
    }

    private func select(_ item: MKMapItem, field: RouteSearchField) {
        let title = item.placemark.title ?? item.name ?? "Selected location"
        apply(RouteSearchSelection(title: title, coordinate: item.placemark.coordinate), field: field)
    }

    private func resolveTyped(field: RouteSearchField) {
        let query = (field == .start ? startQuery : endQuery).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        if let pair = CoordinateText.parse(query) {
            apply(RouteSearchSelection(title: query,
                coordinate: CLLocationCoordinate2D(latitude: pair.latitude, longitude: pair.longitude)), field: field)
            return
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        if let searchRegion { request.region = searchRegion }
        resolve(request, field: field, requiresChoice: true)
    }

    private func resolve(_ completion: MKLocalSearchCompletion, field: RouteSearchField) {
        resolve(MKLocalSearch.Request(completion: completion), field: field, requiresChoice: false)
    }

    private func resolve(_ request: MKLocalSearch.Request, field: RouteSearchField, requiresChoice: Bool) {
        invalidateSearch()
        let requestID = resolutionID
        isResolvingSelection = true
        errorMessage = nil
        resolvingTask = Task {
            do {
                let items = try await searchLocations(request)
                guard !Task.isCancelled, resolutionID == requestID else { return }
                isResolvingSelection = false
                guard let first = items.first else {
                    errorMessage = "No matches. Add city and country, use coordinates, or choose the point on the map."
                    return
                }
                if requiresChoice {
                    foundItemsField = field
                    foundItems = items
                    focusedField = nil
                } else { select(first, field: field) }
            } catch {
                guard !Task.isCancelled, resolutionID == requestID else { return }
                isResolvingSelection = false
                errorMessage = "Search failed. You can choose a point on the map or use coordinates. " + error.localizedDescription
            }
        }
    }
}

private struct RouteStopEditor: View {
    @Environment(\.dismiss) private var dismiss
    let region: MKCoordinateRegion?
    let onSave: (RouteWaypoint) -> Void
    let stopID: UUID
    @State private var query: String
    @State private var selection: RouteSearchSelection?
    @State private var seconds: String
    @State private var showMap = false
    @State private var items: [MKMapItem] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var searchID = UUID()
    @State private var isSearching = false
    @State private var error: String?

    init(initial: RouteWaypoint?, region: MKCoordinateRegion?, onSave: @escaping (RouteWaypoint) -> Void) {
        self.region = region
        self.onSave = onSave
        stopID = initial?.id ?? UUID()
        _query = State(initialValue: initial?.selection.title ?? "")
        _selection = State(initialValue: initial?.selection)
        _seconds = State(initialValue: String(Int(initial?.duration ?? 60)))
    }
    private var duration: Double? {
        guard let value = Double(seconds), RouteStopSchedule.validDuration(value) else { return nil }
        return value
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Stop location") {
                    TextField("Address, city or latitude, longitude", text: $query)
                        .autocorrectionDisabled().submitLabel(.search)
                        .onSubmit { search() }
                        .onChange(of: query) { _, value in
                            guard value != selection?.title else { return }
                            selection = nil
                            invalidate()
                        }
                    Button("Search address") { search() }.disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Choose on map") { invalidate(); showMap = true }
                    if let selection {
                        Text(String(format: "%.6f, %.6f", selection.coordinate.latitude, selection.coordinate.longitude))
                            .font(.caption.monospaced())
                    }
                    if isSearching { ProgressView("Searching…") }
                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                    ForEach(items.indices, id: \.self) { index in
                        let item = items[index]
                        Button {
                            apply(RouteSearchSelection(title: item.placemark.title ?? item.name ?? "Stop",
                                coordinate: item.placemark.coordinate))
                        } label: {
                            VStack(alignment: .leading) {
                                Text(item.name ?? "Location")
                                Text(item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Waiting time") {
                    TextField("Seconds", text: $seconds).keyboardType(.numberPad)
                    HStack {
                        Button("30 s") { seconds = "30" }
                        Button("1 min") { seconds = "60" }
                        Button("5 min") { seconds = "300" }
                    }.buttonStyle(.bordered)
                    Text("Enter 0 to 86,400 seconds. Zero passes through without waiting. Pause freezes the countdown; Stop ends the simulation.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if duration == nil { Text("Enter a valid waiting time.").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Scheduled stop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let selection, let duration else { return }
                        onSave(RouteWaypoint(id: stopID, selection: selection, duration: duration))
                        dismiss()
                    }.disabled(selection == nil || duration == nil || isSearching)
                }
            }
        }
        .sheet(isPresented: $showMap) {
            RouteEndpointPicker(title: "Choose stop", coordinate: selection?.coordinate, region: region) { coordinate in
                apply(RouteSearchSelection(title: String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude),
                    coordinate: coordinate))
            }
        }
        .onDisappear { invalidate() }
    }
    private func invalidate() {
        searchTask?.cancel()
        searchID = UUID()
        items = []
        isSearching = false
    }
    private func apply(_ value: RouteSearchSelection) {
        invalidate()
        selection = value
        query = value.title
        error = nil
    }
    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        invalidate()
        if let pair = CoordinateText.parse(text) {
            apply(RouteSearchSelection(title: text, coordinate: CLLocationCoordinate2D(latitude: pair.latitude, longitude: pair.longitude)))
            return
        }
        let id = searchID
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = [.address, .pointOfInterest]
        if let region { request.region = region }
        isSearching = true
        error = nil
        searchTask = Task {
            do {
                let found = try await searchLocations(request)
                guard !Task.isCancelled, searchID == id else { return }
                items = found
                isSearching = false
                if found.isEmpty { error = "No matches. Include city and country, use coordinates or choose on map." }
            } catch {
                guard !Task.isCancelled, searchID == id else { return }
                isSearching = false
                self.error = "Search failed. Use coordinates or choose on map. " + error.localizedDescription
            }
        }
    }
}

private struct LocationSearchResultsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let items: [MKMapItem]
    let onSelect: (MKMapItem) -> Void
    @State private var selectedIndex: Int?
    @State private var previewPosition: MapCameraPosition = .automatic

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let selectedIndex, items.indices.contains(selectedIndex) {
                    let item = items[selectedIndex]
                    Map(position: $previewPosition) { Marker(item.name ?? "Location", coordinate: item.placemark.coordinate) }
                        .frame(height: 180)
                }
                List(items.indices, id: \.self) { index in
                    let item = items[index]
                    Button {
                        selectedIndex = index
                        previewPosition = .region(MKCoordinateRegion(center: item.placemark.coordinate,
                            latitudinalMeters: 1200, longitudinalMeters: 1200))
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name ?? "Location").foregroundStyle(.primary)
                                Text(item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary)
                                Text(String(format: "%.5f, %.5f", item.placemark.coordinate.latitude,
                                    item.placemark.coordinate.longitude)).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                            if selectedIndex == index { Image(systemName: "checkmark.circle.fill") }
                        }
                    }
                }
            }
            .navigationTitle("Choose an address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use location") {
                        guard let selectedIndex, items.indices.contains(selectedIndex) else { return }
                        onSelect(items[selectedIndex])
                        dismiss()
                    }.disabled(selectedIndex == nil)
                }
            }
        }
    }
}

private struct RouteEndpointPicker: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let onSelect: (CLLocationCoordinate2D) -> Void
    @State private var position: MapCameraPosition
    @State private var selectedCoordinate: CLLocationCoordinate2D?

    init(title: String, coordinate: CLLocationCoordinate2D?, region: MKCoordinateRegion?,
         onSelect: @escaping (CLLocationCoordinate2D) -> Void) {
        self.title = title
        self.onSelect = onSelect
        _selectedCoordinate = State(initialValue: coordinate)
        if let coordinate {
            _position = State(initialValue: .region(MKCoordinateRegion(center: coordinate,
                latitudinalMeters: 1500, longitudinalMeters: 1500)))
        } else if let region { _position = State(initialValue: .region(region)) }
        else { _position = State(initialValue: .automatic) }
    }

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $position) {
                    if let selectedCoordinate { Marker(title, coordinate: selectedCoordinate) }
                }
                .onTapGesture { point in
                    if let coordinate = proxy.convert(point, from: .local) { selectedCoordinate = coordinate }
                }
                .safeAreaInset(edge: .bottom) {
                    Text("Tap the map to place the endpoint.")
                        .padding().background(.regularMaterial)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Point") {
                        guard let selectedCoordinate else { return }
                        onSelect(selectedCoordinate)
                        dismiss()
                    }
                    .disabled(selectedCoordinate == nil)
                }
            }
        }
    }
}

// MARK: - Bookmarks Sheet

struct BookmarksView: View {
    @Binding var bookmarks: [LocationBookmark]
    let onSelect: (LocationBookmark) -> Void
    let onDelete: (IndexSet) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if bookmarks.isEmpty {
                    ContentUnavailableView(
                        "No Bookmarks",
                        systemImage: "bookmark.slash",
                        description: Text("Drop a pin on the map and tap the bookmark icon to save a location.")
                    )
                } else {
                    List {
                        ForEach(bookmarks) { bookmark in
                            Button {
                                onSelect(bookmark)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bookmark.name)
                                        .foregroundStyle(.primary)
                                    Text(String(format: "%.6f, %.6f", bookmark.latitude, bookmark.longitude))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete(perform: onDelete)
                    }
                }
            }
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !bookmarks.isEmpty {
                    EditButton()
                }
            }
        }
    }
}
