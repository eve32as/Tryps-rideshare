#if canImport(SwiftUI)
import SwiftUI
import MapKit
@preconcurrency import CoreLocation

enum TrypsStyle {
    static let ink = Color(red: 0.10, green: 0.15, blue: 0.14)
    static let muted = Color(red: 0.47, green: 0.52, blue: 0.50)
    static let green = Color(red: 0.10, green: 0.45, blue: 0.34)
    static let paleGreen = Color(red: 0.90, green: 0.95, blue: 0.92)
    static let line = Color(red: 0.91, green: 0.93, blue: 0.92)
}

private enum TrypsLayout {
    static let mapBackdropHeightFraction: CGFloat = 0.55
    static let overlappingBookingPanelHeightFraction: CGFloat = 0.70
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
    let symbol: String
    let seats: Int

    static let options = [
        Ride(id: "everyday", name: "Everyday", symbol: "car.side.fill", seats: 4),
        Ride(id: "comfort", name: "Comfort", symbol: "car.side.fill", seats: 4),
        Ride(id: "xl", name: "XL", symbol: "car.2.fill", seats: 6),
    ]
}

struct ContentView: View {
    @State private var destination = Destination.suggestions[0]
    @State private var selectedPickup: Destination?
    @State private var selectedRide = Ride.options[0]
    @State private var editingStop: EditingStop?
    @State private var isShowingAccount = false
    @StateObject private var account = FirebaseAccountStore.shared
    @StateObject private var rideStore = FirebaseRideStore.shared
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
        let signedInID = account.userID ?? "signed-out"
        guard let pickupCoordinate else { return "no-pickup-\(destinationID)-\(signedInID)" }
        return "\(rounded(pickupCoordinate.latitude)),\(rounded(pickupCoordinate.longitude))-\(destinationID)-\(signedInID)"
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
                    .frame(height: geometry.size.height * TrypsLayout.mapBackdropHeightFraction)
                    .ignoresSafeArea(edges: .top)

                VStack(spacing: 0) {
                    header
                        .padding(.top, geometry.safeAreaInsets.top + 10)
                        .padding(.horizontal, 22)

                    Spacer(minLength: 0)

                    bookingPanel
                        .frame(height: geometry.size.height * TrypsLayout.overlappingBookingPanelHeightFraction)
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
        .sheet(isPresented: $isShowingAccount) {
            FirebaseAccountView(account: account, locationManager: locationManager)
        }
        .background {
#if canImport(StripePaymentSheet) && canImport(UIKit)
            if let paymentSession = rideStore.paymentSession {
                StripePaymentSheetPresenter(session: paymentSession) { result in
                    rideStore.paymentFinished(result)
                }
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
            }
#endif
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
            routeError = "Invalid pickup or destination location"
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
            if account.userID != nil {
                await rideStore.loadQuotes(
                    pickup: pickupCoordinate,
                    dropOff: destination.coordinate,
                    rideTypes: Ride.options.map(\.id)
                )
            }
            guard !Task.isCancelled, activeRouteRequestToken == requestToken else { return }
        } catch {
            guard !Task.isCancelled, activeRouteRequestToken == requestToken else { return }
            route = nil
            routeError = "Route unavailable"
        }
    }

    private var routeSummary: String {
        if isCalculatingRoute { return "Finding your route…" }
        if route != nil && account.userID == nil { return "Sign in to get ride quotes" }
        if route != nil && rideStore.isWorking { return "Getting secure ride quotes…" }
        if route != nil && rideStore.quotes.isEmpty {
            return rideStore.errorMessage ?? "Ride prices unavailable"
        }
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
            hasRoute: route != nil && rideStore.quotes[selectedRide.id] != nil,
            isCalculatingRoute: isCalculatingRoute || rideStore.isWorking
        )
            && account.userID != nil
            && (rideStore.rideId == nil ||
                (rideStore.rideStatus == "awaiting_payment" && rideStore.paymentSession == nil))
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

            Button {
                isShowingAccount = true
            } label: {
                Image(systemName: account.email == nil ? "person.crop.circle" : "person.crop.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(TrypsStyle.ink)
                    .padding(5)
                    .background(.white.opacity(0.92), in: Circle())
            }
            .accessibilityLabel(account.email.map { "Account, signed in as \($0)" } ?? "Sign in or create an account")
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
                            let quote = rideStore.quotes[ride.id]
                            RideOptionRow(
                                ride: ride,
                                fare: quote?.formattedAmount,
                                detail: quote.map {
                                    let minutes = max(1, Int(($0.estimatedDurationSeconds / 60.0).rounded()))
                                    return "\($0.distanceKm.formatted(.number.precision(.fractionLength(1)))) route km · \(minutes) min"
                                } ?? "Waiting for quote",
                                isSelected: ride == selectedRide
                            ) {
                                selectedRide = ride
                            }
                        }
                    }
                    if let quote = rideStore.quotes[selectedRide.id] {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Estimated fare breakdown")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(TrypsStyle.ink)
                            Text(quote.formattedFareBreakdown)
                                .font(.caption)
                                .foregroundStyle(TrypsStyle.muted)
                            Text("Based on a driving route; traffic and final trip may change the fare.")
                                .font(.caption2)
                                .foregroundStyle(TrypsStyle.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                    }

                    if let rideID = rideStore.rideId {
                        rideStatusCard(rideID: rideID)
                    }
                    if let error = rideStore.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 12) {
                        Image(systemName: "creditcard.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(TrypsStyle.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Secure payment")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(TrypsStyle.ink)
                            Text("Powered by Stripe")
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
                    .accessibilityLabel("Secure payment powered by Stripe")
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 14)
            }

            Button {
                guard canRequestRide else { return }
                guard let quote = rideStore.quotes[selectedRide.id] else { return }
                Task { await rideStore.requestRide(quote: quote) }
            } label: {
                HStack {
                    Text(rideStore.rideId == nil ? "Request & pay · \(selectedRide.name)" : "Retry secure payment")
                        .font(.system(size: 16, weight: .bold))
                    Spacer()
                    Text(rideStore.quotes[selectedRide.id]?.formattedAmount ?? "—")
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
            .disabled(!canRequestRide || rideStore.isWorking)
            .opacity(canRequestRide && !rideStore.isWorking ? 1 : 0.55)
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

    @ViewBuilder
    private func rideStatusCard(rideID: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Booking \(rideID.prefix(8))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(TrypsStyle.muted)
            Text((rideStore.rideStatus ?? "awaiting_payment").replacingOccurrences(of: "_", with: " ").capitalized)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(TrypsStyle.ink)
            if let dispatchMessage = rideStore.dispatchMessage {
                Text(dispatchMessage)
                    .font(.footnote)
                    .foregroundStyle(TrypsStyle.muted)
            }
            if ["awaiting_payment", "searching_driver", "offered", "driver_assigned", "en_route"].contains(rideStore.rideStatus ?? "") {
                Button("Cancel ride", role: .destructive) {
                    Task { await rideStore.cancelRide() }
                }
                .disabled(rideStore.isWorking)
            }
            if rideStore.paymentStatus == "refund_pending" {
                Text("Your ride is cancelled; the refund is still processing.")
                    .font(.footnote)
                    .foregroundStyle(TrypsStyle.muted)
                Button("Retry refund") {
                    Task { await rideStore.cancelRide() }
                }
                .disabled(rideStore.isWorking)
            } else if rideStore.paymentStatus == "refunded" {
                Text("Your refund has been issued.")
                    .font(.footnote)
                    .foregroundStyle(TrypsStyle.muted)
            }
            if ["completed", "cancelled"].contains(rideStore.rideStatus ?? "") {
                Button("Book another ride") {
                    rideStore.resetRide()
                }
                .tint(TrypsStyle.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(TrypsStyle.paleGreen, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct RideOptionRow: View {
    let ride: Ride
    let fare: String?
    let detail: String
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
                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TrypsStyle.muted)
                }

                Spacer()

                if let fare {
                    Text(fare)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(TrypsStyle.ink)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }

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
        .accessibilityLabel("\(ride.name), \(detail), \(ride.seats) seats, \(fare ?? "price loading")")
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
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
#if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .tint(TrypsStyle.green)
                }
#else
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .tint(TrypsStyle.green)
                }
#endif
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
final class PickupLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var location: CLLocation?
    @Published private(set) var pickupLabel = "Finding your location…"
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 100
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

    func startUpdatingLocation() {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            pickupLabel = "Location access needed"
        @unknown default:
            pickupLabel = "Location unavailable"
        }
    }

    func stopUpdatingLocation() {
        manager.stopUpdatingLocation()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.applyAuthorizationStatus(status)
        }
    }

    private func applyAuthorizationStatus(_ status: CLAuthorizationStatus) {
        authorizationStatus = status
        if authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse {
            manager.requestLocation()
        } else if authorizationStatus == .denied || authorizationStatus == .restricted {
            pickupLabel = "Location access needed"
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor [weak self] in
            self?.applyLocation(location)
        }
    }

    private func applyLocation(_ location: CLLocation) {
        self.location = location
        pickupLabel = "Your location"
        geocoder.cancelGeocode()
        Task {
            guard let placemark = try? await geocoder.reverseGeocodeLocation(location),
                  let name = placemark.first?.name,
                  self.location?.coordinate.latitude == location.coordinate.latitude,
                  self.location?.coordinate.longitude == location.coordinate.longitude else { return }
            pickupLabel = name
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.applyLocationFailure()
        }
    }

    private func applyLocationFailure() {
        if location == nil {
            pickupLabel = authorizationStatus == .denied || authorizationStatus == .restricted
                ? "Location access needed"
                : "Couldn’t find your location"
        }
    }
}
#endif
