#if canImport(CarPlay) && canImport(MapKit) && canImport(UIKit)
import CarPlay
import MapKit
import UIKit

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var mapTemplate: CPMapTemplate?
    private var navigationSession: CPNavigationSession?
    private var currentTripKey: String?
    private var updateObserver: NSObjectProtocol?
    private var stopObserver: NSObjectProtocol?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        self.interfaceController = interfaceController
        let mapTemplate = CPMapTemplate()
        mapTemplate.mapDelegate = self
        let panButton = CPMapButton { [weak mapTemplate] _ in
            mapTemplate?.showPanningInterface(animated: true)
        }
        panButton.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right")
        mapTemplate.mapButtons = [panButton]
        self.mapTemplate = mapTemplate
        interfaceController.setRootTemplate(mapTemplate, animated: true)
        updateObserver = NotificationCenter.default.addObserver(
            forName: .driverNavigationDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in self?.updateNavigation(notification.userInfo ?? [:]) }
        }
        DriverNavigationStore.shared.syncCarPlayState()
        stopObserver = NotificationCenter.default.addObserver(
            forName: .driverNavigationDidStop,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stopNavigation() }
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        if let updateObserver { NotificationCenter.default.removeObserver(updateObserver) }
        if let stopObserver { NotificationCenter.default.removeObserver(stopObserver) }
        updateObserver = nil
        stopObserver = nil
        stopNavigation()
        self.interfaceController = nil
        mapTemplate = nil
    }

    private func updateNavigation(_ values: [AnyHashable: Any]) {
        guard let mapTemplate,
              let rideID = values["rideID"] as? String,
              !rideID.isEmpty,
              let destinationName = values["destinationName"] as? String,
              let instructions = values["instructions"] as? [String],
              let destinationLatitude = values["destinationLatitude"] as? CLLocationDegrees,
              let destinationLongitude = values["destinationLongitude"] as? CLLocationDegrees else { return }

        let tripKey = "\(rideID):\(destinationName)"
        if tripKey != currentTripKey {
            navigationSession?.finishTrip()
            currentTripKey = tripKey
            let originCoordinate = CLLocationCoordinate2D(
                latitude: values["originLatitude"] as? CLLocationDegrees ?? destinationLatitude,
                longitude: values["originLongitude"] as? CLLocationDegrees ?? destinationLongitude
            )
            let destinationCoordinate = CLLocationCoordinate2D(
                latitude: destinationLatitude,
                longitude: destinationLongitude
            )
            let routeChoice = CPRouteChoice(
                summaryVariants: ["Tryps driver route"],
                additionalInformationVariants: [destinationName],
                selectionSummaryVariants: ["Navigate to \(destinationName)"]
            )
            let trip = CPTrip(
                origin: MKMapItem(placemark: MKPlacemark(coordinate: originCoordinate)),
                destination: MKMapItem(placemark: MKPlacemark(coordinate: destinationCoordinate)),
                routeChoices: [routeChoice]
            )
            navigationSession = mapTemplate.startNavigationSession(for: trip)
        }

        let maneuvers = instructions.enumerated().map { index, instruction in
            let maneuver = CPManeuver()
            maneuver.instructionVariants = [instruction]
            maneuver.symbolImage = UIImage(systemName: index == 0 ? "location.north.fill" : "arrow.turn.up.right")
            maneuver.initialTravelEstimates = CPTravelEstimates(
                distanceRemaining: Measurement(value: index == 0
                    ? values["distanceToNextManeuver"] as? CLLocationDistance ?? 0
                    : 0, unit: UnitLength.meters),
                timeRemaining: index == 0 ? values["remainingTime"] as? TimeInterval ?? 0 : 0
            )
            return maneuver
        }
        guard !maneuvers.isEmpty else { return }
        let currentIndex = values["currentStepIndex"] as? Int ?? 0
        navigationSession?.upcomingManeuvers = Array(maneuvers.dropFirst(currentIndex))
        let currentManeuver = maneuvers[min(max(currentIndex, 0), maneuvers.count - 1)]
        let estimate = CPTravelEstimates(
            distanceRemaining: Measurement(
                value: values["distanceToNextManeuver"] as? CLLocationDistance ?? 0,
                unit: UnitLength.meters
            ),
            timeRemaining: values["remainingTime"] as? TimeInterval ?? 0
        )
        navigationSession?.updateTravelEstimates(estimate, for: currentManeuver)
    }

    private func stopNavigation() {
        navigationSession?.finishTrip()
        navigationSession = nil
        currentTripKey = nil
    }
}

extension CarPlaySceneDelegate: CPMapTemplateDelegate { }
#endif
