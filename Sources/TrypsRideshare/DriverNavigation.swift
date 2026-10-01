import Foundation

struct TurnByTurnProgress {
    private(set) var currentStepIndex = 0

    mutating func reset() {
        currentStepIndex = 0
    }

    mutating func advanceIfReached(distanceToManeuver: Double, stepCount: Int, threshold: Double = 35) -> Bool {
        guard distanceToManeuver.isFinite,
              distanceToManeuver >= 0,
              distanceToManeuver <= threshold,
              currentStepIndex + 1 < stepCount else { return false }
        currentStepIndex += 1
        return true
    }
}

#if canImport(SwiftUI) && canImport(MapKit) && canImport(AVFoundation) && canImport(UIKit)
import AVFoundation
import CoreLocation
import MapKit
import SwiftUI
import UIKit

extension Notification.Name {
    static let driverNavigationDidUpdate = Notification.Name("driverNavigationDidUpdate")
    static let driverNavigationDidStop = Notification.Name("driverNavigationDidStop")
}

@MainActor
final class DriverNavigationStore: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = DriverNavigationStore()

    @Published private(set) var route: MKRoute?
    @Published private(set) var currentInstruction = "Preparing route…"
    @Published private(set) var nextInstruction: String?
    @Published private(set) var distanceToNextManeuver: CLLocationDistance = 0
    @Published private(set) var remainingDistance: CLLocationDistance = 0
    @Published private(set) var remainingTime: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var destinationName = ""
    @Published private(set) var destinationCoordinate: CLLocationCoordinate2D?
    @Published private(set) var isNavigating = false

    private let locationManager = CLLocationManager()
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var destination: CLLocationCoordinate2D?
    private var routeSteps: [MKRoute.Step] = []
    private var progress = TurnByTurnProgress()
    private var routeRequestID: UUID?
    private var activeRideID: String?
    private var requestedAlwaysAuthorization = false
    private var routedFromLiveLocation = false

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = 10
        locationManager.activityType = .automotiveNavigation
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    func start(rideID: String, pickup: CLLocationCoordinate2D, dropOff: CLLocationCoordinate2D, status: String) {
        let destinationIsDropOff = status == "arrived" || status == "in_progress"
        let nextDestination = destinationIsDropOff ? dropOff : pickup
        guard activeRideID != rideID || !sameCoordinate(destination, nextDestination) else { return }
        activeRideID = rideID
        destination = nextDestination
        destinationCoordinate = nextDestination
        destinationName = destinationIsDropOff ? "Rider destination" : "Rider pickup"
        errorMessage = nil
        route = nil
        routeSteps = []
        progress.reset()
        routedFromLiveLocation = false
        isNavigating = true
        try? AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.duckOthers, .allowBluetoothA2DP]
        )
        try? AVAudioSession.sharedInstance().setActive(true)
        requestRoute(from: locationManager.location?.coordinate ?? pickup, to: nextDestination)
        if locationManager.authorizationStatus == .authorizedAlways {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.startUpdatingLocation()
        } else {
            requestedAlwaysAuthorization = true
            locationManager.requestAlwaysAuthorization()
        }
    }

    func stop() {
        routeRequestID = nil
        activeRideID = nil
        destination = nil
        destinationCoordinate = nil
        destinationName = ""
        route = nil
        routeSteps = []
        isNavigating = false
        speechSynthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false
        NotificationCenter.default.post(name: .driverNavigationDidStop, object: nil)
    }

    func syncCarPlayState() {
        if isNavigating, route != nil {
            publishCarPlayUpdate()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard isNavigating else { return }
        if manager.authorizationStatus == .authorizedAlways ||
            manager.authorizationStatus == .authorizedWhenInUse {
            if manager.authorizationStatus == .authorizedAlways {
                manager.allowsBackgroundLocationUpdates = true
            } else if !requestedAlwaysAuthorization {
                requestedAlwaysAuthorization = true
                manager.requestAlwaysAuthorization()
            }
            manager.startUpdatingLocation()
            if let destination, let location = manager.location?.coordinate {
                requestRoute(from: location, to: destination)
            }
        } else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            errorMessage = "Allow location access to use turn-by-turn navigation."
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isNavigating, let location = locations.last else { return }
        if !routedFromLiveLocation, let destination {
            routedFromLiveLocation = true
            requestRoute(from: location.coordinate, to: destination)
            return
        }
        updateProgress(location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        errorMessage = "Your location is unavailable. Check location access and try again."
    }

    private func requestRoute(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) {
        let requestID = UUID()
        routeRequestID = requestID
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .automobile
        Task {
            do {
                let response = try await MKDirections(request: request).calculate()
                guard routeRequestID == requestID, isNavigating, let route = response.routes.first else {
                    if routeRequestID == requestID { errorMessage = "No driving route is available." }
                    return
                }
                self.route = route
                routeSteps = route.steps.filter {
                    !$0.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                progress.reset()
                guard !routeSteps.isEmpty else {
                    errorMessage = "This route has no turn-by-turn instructions."
                    return
                }
                errorMessage = nil
                currentInstruction = routeSteps[0].instructions
                nextInstruction = routeSteps.dropFirst().first?.instructions
                announce(routeSteps[0].instructions)
                publishCarPlayUpdate()
            } catch {
                guard routeRequestID == requestID else { return }
                errorMessage = "Couldn’t calculate a driving route. Check your connection and try again."
            }
        }
    }

    private func updateProgress(_ location: CLLocation) {
        let stepIndex = progress.currentStepIndex
        guard !routeSteps.isEmpty, stepIndex < routeSteps.count else { return }
        let step = routeSteps[stepIndex]
        guard step.polyline.pointCount > 0 else { return }
        var coordinates = Array(
            repeating: kCLLocationCoordinate2DInvalid,
            count: step.polyline.pointCount
        )
        step.polyline.getCoordinates(
            &coordinates,
            range: NSRange(location: 0, length: step.polyline.pointCount)
        )
        guard let endpoint = coordinates.last else { return }
        let endpointLocation = CLLocation(latitude: endpoint.latitude, longitude: endpoint.longitude)
        distanceToNextManeuver = location.distance(from: endpointLocation)
        if progress.advanceIfReached(distanceToManeuver: distanceToNextManeuver, stepCount: routeSteps.count) {
            let nextStepIndex = progress.currentStepIndex
            announce(routeSteps[nextStepIndex].instructions)
        }
        let currentStepIndex = progress.currentStepIndex
        let remainingSteps = routeSteps[currentStepIndex...]
        remainingDistance = remainingSteps.reduce(0) { $0 + $1.distance }
        remainingTime = remainingSteps.reduce(0) { $0 + $1.expectedTravelTime }
        currentInstruction = routeSteps[currentStepIndex].instructions
        nextInstruction = routeSteps.dropFirst(currentStepIndex + 1).first?.instructions
        publishCarPlayUpdate()
    }

    private func announce(_ instruction: String) {
        let utterance = AVSpeechUtterance(string: instruction)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speechSynthesizer.speak(utterance)
    }

    private func sameCoordinate(_ first: CLLocationCoordinate2D?, _ second: CLLocationCoordinate2D) -> Bool {
        guard let first else { return false }
        return abs(first.latitude - second.latitude) < 0.00001 &&
            abs(first.longitude - second.longitude) < 0.00001
    }

    private func publishCarPlayUpdate() {
        let instructions = routeSteps.map(\.instructions)
        NotificationCenter.default.post(
            name: .driverNavigationDidUpdate,
            object: self,
            userInfo: [
                "rideID": activeRideID ?? "",
                "destinationName": destinationName,
                "instructions": instructions,
                "currentStepIndex": currentStepIndex,
                "currentInstruction": currentInstruction,
                "distanceToNextManeuver": distanceToNextManeuver,
                "remainingDistance": remainingDistance,
                "remainingTime": remainingTime,
                "destinationLatitude": destination?.latitude ?? 0,
                "destinationLongitude": destination?.longitude ?? 0,
                "originLatitude": locationManager.location?.coordinate.latitude ?? 0,
                "originLongitude": locationManager.location?.coordinate.longitude ?? 0,
            ]
        )
    }
}

struct DriverNavigationPanel: View {
    @ObservedObject var navigation: DriverNavigationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Turn-by-turn · \(navigation.destinationName)", systemImage: "location.north.fill")
                .font(.subheadline.weight(.semibold))
            if let route = navigation.route {
                Map {
                    MapPolyline(route.polyline)
                        .stroke(TrypsStyle.green, lineWidth: 6)
                    if let destination = navigation.destinationCoordinate {
                        Marker(navigation.destinationName, coordinate: destination)
                    }
                }
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.turn.up.right")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(TrypsStyle.green)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(navigation.currentInstruction)
                            .font(.subheadline.weight(.semibold))
                        Text("\(navigation.distanceToNextManeuver.formatted(.measurement(width: .abbreviated, usage: .road))) to maneuver")
                            .font(.caption)
                            .foregroundStyle(TrypsStyle.muted)
                    }
                    Spacer()
                }
                Text("\(navigation.remainingDistance.formatted(.measurement(width: .abbreviated, usage: .road))) · \(Int(navigation.remainingTime / 60)) min remaining")
                    .font(.caption)
                    .foregroundStyle(TrypsStyle.muted)
                if let next = navigation.nextInstruction {
                    Text("Then \(next)")
                        .font(.caption)
                        .foregroundStyle(TrypsStyle.muted)
                }
            } else if let error = navigation.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            } else {
                ProgressView("Finding driving route…")
                    .font(.footnote)
            }
        }
        .padding(12)
        .background(TrypsStyle.paleGreen, in: RoundedRectangle(cornerRadius: 14))
    }
}
#elseif canImport(SwiftUI) && canImport(MapKit)
import SwiftUI
import MapKit

@MainActor
final class DriverNavigationStore: ObservableObject {
    static let shared = DriverNavigationStore()
    @Published private(set) var route: Any?
    @Published private(set) var currentInstruction = ""
    @Published private(set) var nextInstruction: String?
    @Published private(set) var distanceToNextManeuver = 0.0
    @Published private(set) var remainingDistance = 0.0
    @Published private(set) var remainingTime = 0.0
    @Published private(set) var errorMessage: String?
    @Published private(set) var destinationName = ""
    @Published private(set) var isNavigating = false
    func start(rideID: String, pickup: CLLocationCoordinate2D, dropOff: CLLocationCoordinate2D, status: String) { }
    func stop() { }
}

struct DriverNavigationPanel: View {
    @ObservedObject var navigation: DriverNavigationStore
    var body: some View { EmptyView() }
}
#endif
