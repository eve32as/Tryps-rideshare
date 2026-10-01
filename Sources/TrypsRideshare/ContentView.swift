#if canImport(SwiftUI)
import SwiftUI
import MapKit
@preconcurrency import CoreLocation

private enum TrypsStyle {
    static let ink = Color(red: 0.10, green: 0.15, blue: 0.14)
    static let muted = Color(red: 0.47, green: 0.52, blue: 0.50)
    static let green = Color(red: 0.10, green: 0.45, blue: 0.34)
    static let paleGreen = Color(red: 0.90, green: 0.95, blue: 0.92)
    static let line = Color(red: 0.91, green: 0.93, blue: 0.92)
}

private struct Destination: Identifiable {
    let id: String
    let name: String
    let subtitle: String
    let symbol: String
    let coordinate: CLLocationCoordinate2D
    let fareSurcharge: Int

    init(
        id: String,
        name: String,
        subtitle: String,
        symbol: String,
        coordinate: CLLocationCoordinate2D,
        fareSurcharge: Int = 0
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.symbol = symbol
        self.coordinate = coordinate
        self.fareSurcharge = fareSurcharge
    }

    static let suggestions = [
        Destination(id: "mission", name: "Mission Dolores Park", subtitle: "Dolores St, San Francisco", symbol: "leaf", coordinate: CLLocationCoordinate2D(latitude: 37.7596, longitude: -122.4269)),
        Destination(id: "sfo", name: "San Francisco Airport", subtitle: "San Francisco International", symbol: "airplane", coordinate: CLLocationCoordinate2D(latitude: 37.6213, longitude: -122.3790), fareSurcharge: 24),
        Destination(id: "ferry", name: "Ferry Building", subtitle: "1 Ferry Building, San Francisco", symbol: "water.waves", coordinate: CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937)),
        Destination(id: "chase", name: "Chase Center", subtitle: "1 Warriors Way, San Francisco", symbol: "basketball", coordinate: CLLocationCoordinate2D(latitude: 37.7680, longitude: -122.3877), fareSurcharge: 4),
        Destination(id: "painted", name: "Painted Ladies", subtitle: "Steiner St, San Francisco", symbol: "house", coordinate: CLLocationCoordinate2D(latitude: 37.7761, longitude: -122.4329)),
    ]
}

private enum EditingStop: String, Identifiable {
    case pickup
    case dropOff

    var id: String { rawValue }
    var title: String { self == .pickup ? "Choose a pickup" : "Choose a destination" }
}

private struct Ride: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let symbol: String
    let seats: Int
    let fare: Int

    static let options = [
        Ride(id: "everyday", name: "Everyday", detail: "4 min away", symbol: "car.side.fill", seats: 4, fare: 18),
        Ride(id: "comfort", name: "Comfort", detail: "6 min away", symbol: "car.side.fill", seats: 4, fare: 26),
        Ride(id: "xl", name: "XL", detail: "8 min away", symbol: "car.2.fill", seats: 6, fare: 32),
    ]
}

struct ContentView: View {
    @State private var destination = Destination.suggestions[0]
    @State private var selectedPickup: Destination?
    @State private var selectedRide = Ride.options[0]
    @State private var editingStop: EditingStop?
    @State private var isRideRequested = false
    @State private var route: MKRoute?
    @State private var routeError: String?
    @State private var isCalculatingRoute = false
    @State private var activeRouteRequestToken: UUID?
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.7596, longitude: -122.4269),
            span: MKCoordinateSpan(latitudeDelta: 0.035, longitudeDelta: 0.035)
        )
    )
    @StateObject private var locationManager = PickupLocationManager()

    private var pickupCoordinate: CLLocationCoordinate2D? {
        selectedPickup?.coordinate ?? locationManager.location?.coordinate
    }

    private var pickupLabel: String {
        selectedPickup?.name ?? locationManager.pickupLabel
    }

    private var routeRequestID: String {
        let destinationID = "\(destination.id)-\(rounded(destination.coordinate.latitude)),\(rounded(destination.coordinate.longitude))"
        guard let pickupCoordinate else { return "no-pickup-\(destinationID)" }
        return "\(rounded(pickupCoordinate.latitude)),\(rounded(pickupCoordinate.longitude))-\(destinationID)"
    }

    private func rounded(_ coordinate: CLLocationDegrees) -> CLLocationDegrees {
        (coordinate * 10_000).rounded() / 10_000
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                RideMapView(
                    cameraPosition: $cameraPosition,
                    pickup: pickupCoordinate,
                    destination: destination.coordinate,
                    route: route
                )
                    .frame(height: geometry.size.height * 0.55)
                    .ignoresSafeArea(edges: .top)

                VStack(spacing: 0) {
                    header
                        .padding(.top, geometry.safeAreaInsets.top + 10)
                        .padding(.horizontal, 22)

                    Spacer(minLength: 0)

                    bookingPanel
                        .frame(height: geometry.size.height * 0.70)
                }
            }
            .background(TrypsStyle.paleGreen)
            .ignoresSafeArea(edges: .top)
        }
        .preferredColorScheme(.light)
        .task {
            locationManager.requestLocation()
        }
        .task(id: routeRequestID) {
            await calculateRoute()
        }
        .sheet(item: $editingStop) { stop in
            DestinationPicker(
                title: stop.title,
                searchRegionCenter: pickupCoordinate,
                onSelect: { place in
                    switch stop {
                    case .pickup:
                        selectedPickup = place
                    case .dropOff:
                        destination = place
                    }
                    editingStop = nil
                }
            )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert("Your ride is on its way", isPresented: $isRideRequested) {
            Button("Done", role: .cancel) { }
        } message: {
            Text("\(selectedRide.name) to \(destination.name) · about \(BookingFare.formatted(fare(for: selectedRide)))")
        }
    }

    private func calculateRoute() async {
        let requestToken = UUID()
        activeRouteRequestToken = requestToken
        defer {
            if activeRouteRequestToken == requestToken {
                isCalculatingRoute = false
                activeRouteRequestToken = nil
            }
        }

        guard let pickupCoordinate else {
            route = nil
            routeError = nil
            isCalculatingRoute = false
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: destination.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.035, longitudeDelta: 0.035)
                )
            )
            return
        }
        guard CLLocationCoordinate2DIsValid(pickupCoordinate),
              CLLocationCoordinate2DIsValid(destination.coordinate) else {
            route = nil
            routeError = "Choose a pickup and destination"
            isCalculatingRoute = false
            return
        }

        route = nil
        isCalculatingRoute = true
        routeError = nil

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: pickupCoordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination.coordinate))
        request.transportType = .automobile

        do {
            let response = try await MKDirections(request: request).calculate()
            guard !Task.isCancelled, activeRouteRequestToken == requestToken else { return }
            guard let route = response.routes.first else {
                self.route = nil
                routeError = "No driving route found"
                return
            }
            self.route = route
            cameraPosition = .rect(route.polyline.boundingMapRect)
        } catch {
            guard !Task.isCancelled, activeRouteRequestToken == requestToken else { return }
            route = nil
            routeError = "Route unavailable"
        }
    }

    private var routeSummary: String {
        if isCalculatingRoute { return "Finding your route…" }
        if let route {
            let minutes = max(1, Int((route.expectedTravelTime / 60).rounded()))
            let miles = route.distance / 1_609.344
            return "\(minutes) min · \(miles.formatted(.number.precision(.fractionLength(1)))) mi"
        }
        if selectedPickup == nil &&
            (locationManager.authorizationStatus == .denied || locationManager.authorizationStatus == .restricted) {
            return "Allow location to see your route"
        }
        return routeError ?? (pickupCoordinate == nil ? "Choose a pickup location" : "Choose a destination")
    }

    private var canRequestRide: Bool {
        BookingReadiness.canRequestRide(
            hasPickup: pickupCoordinate.map { CLLocationCoordinate2DIsValid($0) } ?? false,
            hasDestination: CLLocationCoordinate2DIsValid(destination.coordinate),
            hasRoute: route != nil,
            isCalculatingRoute: isCalculatingRoute
        )
    }

    private var header: some View {
        HStack {
            HStack(spacing: 9) {
                Image(systemName: "arrow.trianglehead.branch")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(TrypsStyle.green, in: RoundedRectangle(cornerRadius: 12))
                Text("tryps")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .tracking(-0.8)
                    .foregroundStyle(TrypsStyle.ink)
            }

            Spacer()

            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(TrypsStyle.ink)
                .padding(5)
                .background(.white.opacity(0.92), in: Circle())
                .accessibilityHidden(true)
        }
    }

    private var bookingPanel: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(TrypsStyle.line)
                .frame(width: 38, height: 5)
                .padding(.top, 11)
                .padding(.bottom, 13)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Where to?")
                                .font(.system(size: 25, weight: .bold, design: .rounded))
                                .tracking(-0.7)
                                .foregroundStyle(TrypsStyle.ink)
                            Text("A better way to get there.")
                                .font(.system(size: 14, weight: .regular))
                                .foregroundStyle(TrypsStyle.muted)
                        }
                        Spacer()
                        Label("Now", systemImage: "clock")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(TrypsStyle.ink)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(Color(red: 0.96, green: 0.97, blue: 0.96), in: Capsule())
                    }

                    locationCard

                    HStack {
                        Text("RIDE OPTIONS")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1.1)
                            .foregroundStyle(TrypsStyle.muted)
                        Spacer()
                        Text(routeSummary)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(route == nil ? TrypsStyle.muted : TrypsStyle.green)
                    }
                    .padding(.top, 1)

                    VStack(spacing: 8) {
                        ForEach(Ride.options) { ride in
                            RideOptionRow(
                                ride: ride,
                                fare: fare(for: ride),
                                isSelected: ride == selectedRide
                            ) {
                                selectedRide = ride
                            }
                        }
                    }

                    HStack(spacing: 12) {
                        Image(systemName: "creditcard.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(TrypsStyle.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Personal · •••• 2048")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(TrypsStyle.ink)
                            Text("Visa")
                                .font(.system(size: 11))
                                .foregroundStyle(TrypsStyle.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(TrypsStyle.muted)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Color(red: 0.97, green: 0.98, blue: 0.97), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Payment method, Personal Visa ending in 2048")
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 14)
            }

            Button {
                guard canRequestRide else { return }
                isRideRequested = true
            } label: {
                HStack {
                    Text("Confirm \(selectedRide.name)")
                        .font(.system(size: 16, weight: .bold))
                    Spacer()
                    Text(BookingFare.formatted(fare(for: selectedRide)))
                        .font(.system(size: 16, weight: .bold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .frame(height: 56)
                .background(TrypsStyle.green, in: RoundedRectangle(cornerRadius: 17))
            }
            .accessibilityHint("Requests the selected ride to \(destination.name)")
            .disabled(!canRequestRide)
            .opacity(canRequestRide ? 1 : 0.55)
            .padding(.horizontal, 22)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .background(.white)
        }
        .background(.white)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26))
        .shadow(color: .black.opacity(0.08), radius: 22, y: -7)
    }

    private var locationCard: some View {
        HStack(spacing: 13) {
            VStack(spacing: 0) {
                Circle()
                    .fill(TrypsStyle.green)
                    .frame(width: 9, height: 9)
                Rectangle()
                    .fill(TrypsStyle.line)
                    .frame(width: 1.5, height: 28)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(red: 0.91, green: 0.56, blue: 0.29))
                    .frame(width: 9, height: 9)
            }
            .padding(.leading, 3)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button {
                        editingStop = .pickup
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pickup")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(TrypsStyle.muted)
                            Text(pickupLabel)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(TrypsStyle.ink)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button {
                        selectedPickup = nil
                        locationManager.requestLocation()
                    } label: {
                        Image(systemName: locationManager.location == nil ? "location.circle" : "location.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(TrypsStyle.green)
                    }
                    .accessibilityLabel("Use my current location")
                }

                Rectangle()
                    .fill(TrypsStyle.line)
                    .frame(height: 1)
                    .padding(.vertical, 9)

                Button {
                    editingStop = .dropOff
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Drop-off")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(TrypsStyle.muted)
                            Text(destination.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(TrypsStyle.ink)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(TrypsStyle.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(.white, in: RoundedRectangle(cornerRadius: 17))
        .overlay {
            RoundedRectangle(cornerRadius: 17)
                .stroke(TrypsStyle.line, lineWidth: 1)
        }
    }

    private func fare(for ride: Ride) -> Int {
        BookingFare.total(
            baseFare: ride.fare,
            pickupSurcharge: selectedPickup?.fareSurcharge ?? 0,
            dropOffSurcharge: destination.fareSurcharge
        )
    }
}

private struct RideOptionRow: View {
    let ride: Ride
    let fare: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: ride.symbol)
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(isSelected ? TrypsStyle.green : TrypsStyle.ink)
                    .frame(width: 43, height: 37)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(ride.name)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(TrypsStyle.ink)
                        Image(systemName: "person.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(TrypsStyle.muted)
                        Text("\(ride.seats)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(TrypsStyle.muted)
                    }
                    Text(ride.detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TrypsStyle.muted)
                }

                Spacer()

                Text(BookingFare.formatted(fare))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(TrypsStyle.ink)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? TrypsStyle.green : TrypsStyle.line)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(isSelected ? TrypsStyle.paleGreen.opacity(0.65) : .white, in: RoundedRectangle(cornerRadius: 15))
            .overlay {
                RoundedRectangle(cornerRadius: 15)
                    .stroke(isSelected ? TrypsStyle.green.opacity(0.45) : TrypsStyle.line, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(ride.name), \(ride.detail), \(ride.seats) seats, \(BookingFare.formatted(fare))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct DestinationPicker: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let searchRegionCenter: CLLocationCoordinate2D?
    let onSelect: (Destination) -> Void
    @State private var searchText = ""
    @State private var searchResults = Destination.suggestions
    @State private var isSearching = false
    @State private var searchFailed = false
    @State private var activeSearchToken: UUID?

    var body: some View {
        NavigationStack {
            Group {
                if searchResults.isEmpty && !isSearching {
                    ContentUnavailableView(
                        searchFailed ? "Search unavailable" : "No places found",
                        systemImage: searchFailed ? "wifi.exclamationmark" : "magnifyingglass",
                        description: Text(searchFailed ? "Check your connection and try again." : "Try a different search.")
                    )
                } else {
                    List(searchResults) { destination in
                        Button {
                            onSelect(destination)
                            dismiss()
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: destination.symbol)
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(TrypsStyle.green)
                                    .frame(width: 38, height: 38)
                                    .background(TrypsStyle.paleGreen, in: RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(destination.name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(TrypsStyle.ink)
                                    Text(destination.subtitle)
                                        .font(.system(size: 12))
                                        .foregroundStyle(TrypsStyle.muted)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                }
            }
            .overlay {
                if isSearching {
                    ProgressView("Searching places…")
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .searchable(text: $searchText, prompt: "Search places")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .tint(TrypsStyle.green)
                }
            }
            .task(id: searchText) {
                await searchPlaces()
            }
        }
    }

    private func searchPlaces() async {
        let searchToken = UUID()
        activeSearchToken = searchToken
        defer {
            if activeSearchToken == searchToken {
                isSearching = false
                activeSearchToken = nil
            }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = Destination.suggestions
            searchFailed = false
            return
        }

        isSearching = true
        do {
            try await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, activeSearchToken == searchToken else { return }

            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            if let center = searchRegionCenter {
                request.region = MKCoordinateRegion(
                    center: center,
                    span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
                )
            }

            let response = try await MKLocalSearch(request: request).start()
            guard !Task.isCancelled, activeSearchToken == searchToken else { return }
            searchResults = response.mapItems.enumerated().compactMap { index, item in
                guard let name = item.name else { return nil }
                let coordinate = item.placemark.coordinate
                guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
                return Destination(
                    id: "\(name)-\(coordinate.latitude),\(coordinate.longitude)-\(index)",
                    name: name,
                    subtitle: item.placemark.title ?? "",
                    symbol: "mappin.and.ellipse",
                    coordinate: coordinate
                )
            }
            searchFailed = false
        } catch {
            guard !Task.isCancelled, activeSearchToken == searchToken else { return }
            searchResults = []
            searchFailed = true
        }
    }
}

private struct RideMapView: View {
    @Binding var cameraPosition: MapCameraPosition
    let pickup: CLLocationCoordinate2D?
    let destination: CLLocationCoordinate2D
    let route: MKRoute?

    var body: some View {
        Map(position: $cameraPosition) {
            if let pickup {
                Annotation("Pickup", coordinate: pickup) {
                    mapMarker(symbol: "location.fill", tint: TrypsStyle.green)
                }
                .annotationTitles(.hidden)
            }
            Annotation("Drop-off", coordinate: destination) {
                mapMarker(symbol: "mappin.and.ellipse", tint: Color(red: 0.91, green: 0.56, blue: 0.29))
            }
            .annotationTitles(.hidden)
            if let route {
                MapPolyline(route.polyline)
                    .stroke(TrypsStyle.green, lineWidth: 5)
            }
            UserAnnotation()
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .mapControlVisibility(.visible)
    }

    private func mapMarker(symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(tint, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
    }
}

@MainActor
private final class PickupLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var location: CLLocation?
    @Published private(set) var pickupLabel = "Finding your location…"
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        authorizationStatus = manager.authorizationStatus
    }

    func requestLocation() {
        location = nil
        pickupLabel = "Finding your location…"
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            pickupLabel = "Location access needed"
        @unknown default:
            pickupLabel = "Location unavailable"
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse {
            manager.requestLocation()
        } else if authorizationStatus == .denied || authorizationStatus == .restricted {
            pickupLabel = "Location access needed"
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        self.location = location
        pickupLabel = "Your location"
        Task {
            guard let placemark = try? await geocoder.reverseGeocodeLocation(location),
                  let name = placemark.first?.name,
                  self.location?.coordinate.latitude == location.coordinate.latitude,
                  self.location?.coordinate.longitude == location.coordinate.longitude else { return }
            pickupLabel = name
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if location == nil {
            pickupLabel = authorizationStatus == .denied || authorizationStatus == .restricted
                ? "Location access needed"
                : "Couldn’t find your location"
        }
    }
}
#endif
