import SwiftData
import SwiftUI
import MapKit
import StripePaymentSheet

private enum AppTab {
    case ride
    case activity
}

private struct RideOption: Identifiable {
    let id: String
    let name: String
    let detail: String
    let price: String
    let arrival: String
    let symbol: String

    static let all = [
        RideOption(id: "tryps-go", name: "Tryps Go", detail: "Everyday rides", price: "$12.50", arrival: "3 min", symbol: "car.side.fill"),
        RideOption(id: "tryps-comfort", name: "Comfort", detail: "More room to relax", price: "$18.20", arrival: "5 min", symbol: "car.side.rear.open.fill"),
        RideOption(id: "tryps-xl", name: "Tryps XL", detail: "Groups up to 6", price: "$24.80", arrival: "8 min", symbol: "van.side.fill")
    ]
}

private struct BookingReceipt: Identifiable {
    let id = UUID()
    let pickup: String
    let destination: String
    let rideName: String
    let fare: String
}

private enum TrypsStyle {
    static let ink = Color(red: 0.09, green: 0.14, blue: 0.13)
    static let muted = Color(red: 0.43, green: 0.49, blue: 0.46)
    static let accent = Color(red: 0.18, green: 0.39, blue: 0.31)
    static let canvas = Color(red: 0.97, green: 0.97, blue: 0.94)
    static let line = Color(red: 0.88, green: 0.90, blue: 0.87)
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RideBooking.requestedAt, order: .reverse) private var bookings: [RideBooking]
    @StateObject private var locationManager = PickupLocationManager()

    @State private var selectedTab = AppTab.ride
    @State private var selectedRideID = RideOption.all[0].id
    @State private var pickup = "Current location"
    @State private var destination = ""
    @State private var pickupCoordinate: CLLocationCoordinate2D?
    @State private var destinationCoordinate: CLLocationCoordinate2D?
    @State private var sessionToken = SessionStore.loadToken()
    @State private var isSignInPresented = false
    @State private var isRequestingRide = false
    @State private var errorMessage: String?
    @State private var pendingPayment: PendingPayment?
    @State private var receipt: BookingReceipt?

    private var selectedRide: RideOption {
        RideOption.all.first(where: { $0.id == selectedRideID }) ?? RideOption.all[0]
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if selectedTab == .ride {
                rideScreen
            } else {
                activityScreen
            }

            tabBar
        }
        .background(TrypsStyle.canvas.ignoresSafeArea())
        .preferredColorScheme(.light)
        .sheet(item: $receipt) { bookingReceipt in
            ReceiptView(receipt: bookingReceipt)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isSignInPresented) {
            AppleSignInSheet {
                sessionToken = SessionStore.loadToken()
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $pendingPayment) { payment in
            PaymentSheetPresenter(clientSecret: payment.clientSecret) { result in
                handlePaymentResult(result, payment: payment)
            }
            .ignoresSafeArea()
        }
        .alert("Tryps", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            locationManager.requestLocation()
        }
        .onReceive(locationManager.$coordinate.compactMap { $0 }) { coordinate in
            if pickup == "Current location" || locationManager.address == pickup {
                pickupCoordinate = coordinate
            }
        }
        .onReceive(locationManager.$address.compactMap { $0 }) { address in
            if pickup == "Current location" || locationManager.address == pickup {
                pickup = address
            }
        }
        .onChange(of: pickup) { _, newValue in
            if newValue != locationManager.address {
                pickupCoordinate = nil
            }
        }
        .onChange(of: destination) { _, _ in
            destinationCoordinate = nil
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 9) {
                Image(systemName: "arrow.trianglehead.branch")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(TrypsStyle.accent, in: RoundedRectangle(cornerRadius: 12))
                Text("tryps")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .tracking(-1.2)
                    .foregroundStyle(TrypsStyle.ink)
            }

            Spacer()

            Button {
                isSignInPresented = true
            } label: {
                Image(systemName: sessionToken == nil ? "person.crop.circle.fill" : "person.crop.circle.badge.checkmark")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(TrypsStyle.accent, Color.white)
                    .accessibilityLabel(sessionToken == nil ? "Sign in" : "Account signed in")
            }
            .buttonStyle(.plain)
            .accessibilityAction {
                isSignInPresented = true
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var rideScreen: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Where to?")
                        .font(.system(size: 29, weight: .bold, design: .rounded))
                        .tracking(-0.8)
                        .foregroundStyle(TrypsStyle.ink)
                    Text("A better ride is just around the corner.")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(TrypsStyle.muted)
                }

                RouteMapPreview(
                    pickupCoordinate: pickupCoordinate,
                    destinationCoordinate: destinationCoordinate,
                    userCoordinate: locationManager.coordinate
                )
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .accessibilityLabel("Map showing current pickup and destination")

                routeFields
                ridePicker
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 18)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                Task { await requestRide() }
            } label: {
                HStack {
                    if isRequestingRide {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "car.fill")
                        .font(.system(size: 16, weight: .semibold))
                    }
                    Text(isRequestingRide ? "Finding a driver…" : "Request \(selectedRide.name)")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text(selectedRide.price)
                        .font(.system(size: 16, weight: .bold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .bold))
                        .padding(.leading, 4)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .frame(height: 56)
                .background(TrypsStyle.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .disabled(isRequestingRide || destinationCoordinate == nil || pickupCoordinate == nil)
            .opacity(destinationCoordinate == nil || pickupCoordinate == nil ? 0.55 : 1)
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(TrypsStyle.canvas)
        }
    }

    private var routeFields: some View {
        VStack(spacing: 0) {
            routeField(symbol: "circle.fill", tint: TrypsStyle.accent, placeholder: "Pickup location", text: $pickup) {
                Task { await resolvePickup() }
            }
            HStack(spacing: 10) {
                Rectangle()
                    .fill(TrypsStyle.line)
                    .frame(width: 1, height: 18)
                    .padding(.leading, 7)
                Rectangle()
                    .fill(TrypsStyle.line)
                    .frame(height: 1)
            }
            .padding(.leading, 18)
            .padding(.trailing, 16)
            routeField(symbol: "mappin.and.ellipse", tint: Color(red: 0.83, green: 0.40, blue: 0.25), placeholder: "Where are you going?", text: $destination) {
                Task { await resolveDestination() }
            }
        }
        .padding(.vertical, 5)
        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(TrypsStyle.line.opacity(0.7), lineWidth: 1))
    }

    private func routeField(
        symbol: String,
        tint: Color,
        placeholder: String,
        text: Binding<String>,
        submit: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 16)
            TextField(placeholder, text: text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(TrypsStyle.ink)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .accessibilityLabel(placeholder)
                .onSubmit(submit)
        }
        .padding(.horizontal, 18)
        .frame(height: 48)
    }

    private var ridePicker: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Text("Choose your ride")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(TrypsStyle.ink)
                Spacer()
                Label("Today · now", systemImage: "clock")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TrypsStyle.muted)
            }

            VStack(spacing: 8) {
                ForEach(RideOption.all) { ride in
                    Button {
                        selectedRideID = ride.id
                    } label: {
                        RideOptionRow(ride: ride, isSelected: ride.id == selectedRideID)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(ride.id == selectedRideID ? .isSelected : [])
                }
            }
        }
    }

    private var activityScreen: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your rides")
                        .font(.system(size: 29, weight: .bold, design: .rounded))
                        .tracking(-0.8)
                        .foregroundStyle(TrypsStyle.ink)
                    Text("All your trips, together in one place.")
                        .font(.system(size: 14))
                        .foregroundStyle(TrypsStyle.muted)
                }

                if bookings.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "steeringwheel")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(TrypsStyle.accent)
                            .frame(width: 62, height: 62)
                            .background(TrypsStyle.accent.opacity(0.09), in: Circle())
                        Text("Your next ride starts here")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(TrypsStyle.ink)
                        Text("Book a ride and your trip details will show up here.")
                            .font(.system(size: 13))
                            .foregroundStyle(TrypsStyle.muted)
                            .multilineTextAlignment(.center)
                        Button("Find a ride") { selectedTab = .ride }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(TrypsStyle.accent)
                            .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                    .padding(.horizontal, 24)
                    .background(.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                } else {
                    ForEach(bookings) { booking in
                        BookingHistoryRow(booking: booking)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(.ride, title: "Ride", symbol: "car.side.fill")
            tabButton(.activity, title: "Activity", symbol: "clock.arrow.circlepath")
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(.white.shadow(.drop(color: .black.opacity(0.04), radius: 10, y: -3)))
    }

    private func tabButton(_ tab: AppTab, title: String, symbol: String) -> some View {
        Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(selectedTab == tab ? TrypsStyle.accent : TrypsStyle.muted)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func requestRide() async {
        let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPickup = pickup.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pickupCoordinate, let destinationCoordinate,
              !trimmedDestination.isEmpty, !trimmedPickup.isEmpty else {
            errorMessage = "Choose a pickup and destination from the map search results."
            return
        }
        guard let sessionToken else {
            isSignInPresented = true
            return
        }

        isRequestingRide = true
        defer { isRequestingRide = false }
        do {
            let request = RideRequest(
                pickup: RideLocation(label: trimmedPickup, coordinate: pickupCoordinate),
                destination: RideLocation(label: trimmedDestination, coordinate: destinationCoordinate),
                rideType: selectedRide.id
            )
            let response = try await RideAPI.requestRide(token: sessionToken, request: request)
            pendingPayment = PendingPayment(
                id: response.rideId,
                clientSecret: response.paymentIntentClientSecret,
                pickup: trimmedPickup,
                destination: trimmedDestination,
                rideName: selectedRide.name,
                fare: selectedRide.price
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func handlePaymentResult(_ result: PaymentSheetResult, payment: PendingPayment) {
        switch result {
        case .completed:
            let booking = RideBooking(
                pickup: payment.pickup,
                destination: payment.destination,
                rideName: payment.rideName,
                fare: payment.fare
            )
            modelContext.insert(booking)
            receipt = BookingReceipt(
                pickup: payment.pickup,
                destination: payment.destination,
                rideName: payment.rideName,
                fare: payment.fare
            )
            selectedTab = .activity
            pendingPayment = nil
        case .canceled:
            pendingPayment = nil
            guard let sessionToken else { return }
            Task {
                do {
                    try await RideAPI.cancelRide(token: sessionToken, rideID: payment.id)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        case .failed(let error):
            pendingPayment = nil
            errorMessage = error.localizedDescription
            guard let sessionToken else { return }
            Task {
                try? await RideAPI.cancelRide(token: sessionToken, rideID: payment.id)
            }
        }
    }

    @MainActor
    private func resolvePickup() async {
        let query = pickup.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        do {
            let item = try await searchPlace(query)
            pickup = item.name ?? query
            pickupCoordinate = item.placemark.coordinate
        } catch {
            errorMessage = "Couldn’t find that pickup. Try a nearby address or place name."
        }
    }

    @MainActor
    private func resolveDestination() async {
        let query = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        do {
            let item = try await searchPlace(query)
            destination = item.name ?? query
            destinationCoordinate = item.placemark.coordinate
        } catch {
            errorMessage = "Couldn’t find that destination. Try a nearby address or place name."
        }
    }

    private func searchPlace(_ query: String) async throws -> MKMapItem {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let pickupCoordinate {
            request.region = MKCoordinateRegion(
                center: pickupCoordinate,
                latitudinalMeters: 20_000,
                longitudinalMeters: 20_000
            )
        }
        let response = try await MKLocalSearch(request: request).start()
        guard let firstMatch = response.mapItems.first else {
            throw RideAPIError.response
        }
        return firstMatch
    }
}

private struct RideOptionRow: View {
    let ride: RideOption
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ride.symbol)
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(TrypsStyle.ink)
                .frame(width: 44, height: 42)
                .background(TrypsStyle.canvas, in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 3) {
                Text(ride.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(TrypsStyle.ink)
                Text("\(ride.arrival) away · \(ride.detail)")
                    .font(.system(size: 11))
                    .foregroundStyle(TrypsStyle.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(ride.price)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TrypsStyle.ink)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? TrypsStyle.accent.opacity(0.055) : .white, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(isSelected ? TrypsStyle.accent : TrypsStyle.line.opacity(0.8), lineWidth: isSelected ? 1.5 : 1)
        }
    }
}

private struct RouteMapPreview: View {
    let pickupCoordinate: CLLocationCoordinate2D?
    let destinationCoordinate: CLLocationCoordinate2D?
    let userCoordinate: CLLocationCoordinate2D?

    @State private var cameraPosition = MapCameraPosition.region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
        )
    )
    @State private var route: MKRoute?

    var body: some View {
        Map(position: $cameraPosition) {
            UserAnnotation()
            if let pickupCoordinate {
                Annotation("Pickup", coordinate: pickupCoordinate) {
                    mapPin(symbol: "circle.fill", color: TrypsStyle.accent)
                }
            }
            if let destinationCoordinate {
                Annotation("Destination", coordinate: destinationCoordinate) {
                    mapPin(symbol: "mappin.and.ellipse", color: Color(red: 0.83, green: 0.40, blue: 0.25))
                }
            }
            if let route {
                MapPolyline(route.polyline)
                    .stroke(TrypsStyle.accent, lineWidth: 5)
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .mapControls {
            MapCompass()
            MapUserLocationButton()
        }
        .onChange(of: pickupCoordinate?.latitude) { _, _ in updateMap() }
        .onChange(of: pickupCoordinate?.longitude) { _, _ in updateMap() }
        .onChange(of: destinationCoordinate?.latitude) { _, _ in updateMap() }
        .onChange(of: destinationCoordinate?.longitude) { _, _ in updateMap() }
        .onChange(of: userCoordinate?.latitude) { _, _ in
            if pickupCoordinate == nil, let userCoordinate {
                cameraPosition = .region(MKCoordinateRegion(
                    center: userCoordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.035, longitudeDelta: 0.035)
                ))
            }
        }
    }

    private func mapPin(symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(color, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
    }

    private func updateMap() {
        guard let pickupCoordinate else {
            route = nil
            return
        }
        if let destinationCoordinate {
            Task {
                let request = MKDirections.Request()
                request.source = MKMapItem(placemark: MKPlacemark(coordinate: pickupCoordinate))
                request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destinationCoordinate))
                request.transportType = .automobile
                do {
                    let directions = try await MKDirections(request: request).calculate()
                    guard let firstRoute = directions.routes.first else { return }
                    route = firstRoute
                    cameraPosition = .rect(firstRoute.polyline.boundingMapRect.insetBy(dx: -2_000, dy: -2_000))
                } catch {
                    route = nil
                }
            }
        } else {
            route = nil
            cameraPosition = .region(MKCoordinateRegion(
                center: pickupCoordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.035, longitudeDelta: 0.035)
            ))
        }
    }
}

private struct BookingHistoryRow: View {
    let booking: RideBooking

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "car.side.fill")
                .font(.system(size: 17))
                .foregroundStyle(TrypsStyle.accent)
                .frame(width: 42, height: 42)
                .background(TrypsStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(booking.rideName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TrypsStyle.ink)
                    Spacer()
                    Text(booking.fare)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TrypsStyle.ink)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Label(booking.pickup, systemImage: "circle.fill")
                    Label(booking.destination, systemImage: "mappin.and.ellipse")
                }
                .font(.system(size: 11))
                .foregroundStyle(TrypsStyle.muted)
                .lineLimit(1)
                Text(booking.requestedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(TrypsStyle.muted)
            }
        }
        .padding(15)
        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ReceiptView: View {
    let receipt: BookingReceipt
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark")
                .font(.system(size: 25, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(TrypsStyle.accent, in: Circle())
                .padding(.top, 16)
            Text("Your ride is requested")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(TrypsStyle.ink)
            Text("Your \(receipt.rideName) is on its way.")
                .font(.system(size: 14))
                .foregroundStyle(TrypsStyle.muted)
            VStack(alignment: .leading, spacing: 12) {
                Label(receipt.pickup, systemImage: "circle.fill")
                Label(receipt.destination, systemImage: "mappin.and.ellipse")
                HStack {
                    Label(receipt.rideName, systemImage: "car.side.fill")
                    Spacer()
                    Text(receipt.fare).fontWeight(.semibold)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(TrypsStyle.ink)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TrypsStyle.canvas, in: RoundedRectangle(cornerRadius: 16))
            Button("Done") { dismiss() }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(TrypsStyle.accent, in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(24)
    }
}
