import SwiftData
import SwiftUI
import MapKit
import StripePaymentSheet
import UIKit
import UserNotifications

private enum AppTab {
    case ride
    case activity
    case drive
}
private struct RideOption: Identifiable {
    let id: String
    let name: String
    let detail: String
    let arrival: String
    let symbol: String

    static let all = [
        RideOption(id: "tryps-go", name: "Tryps Go", detail: "Everyday rides", arrival: "3 min", symbol: "car.side.fill"),
        RideOption(id: "tryps-comfort", name: "Comfort", detail: "More room to relax", arrival: "5 min", symbol: "car.side.rear.open.fill"),
        RideOption(id: "tryps-xl", name: "Tryps XL", detail: "Groups up to 6", arrival: "8 min", symbol: "van.side.fill")
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
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \RideBooking.requestedAt, order: .reverse) private var bookings: [RideBooking]
    @StateObject private var locationManager = PickupLocationManager()

    @State private var selectedTab = AppTab.ride
    @State private var selectedRideID = RideOption.all[0].id
    @State private var pickup = "Current location"
    @State private var destination = ""
    @State private var pickupCoordinate: CLLocationCoordinate2D?
    @State private var destinationCoordinate: CLLocationCoordinate2D?
    @State private var resolvedPickupLabel: String?
    @State private var resolvedDestinationLabel: String?
    @State private var scheduleForLater = false
    @State private var scheduledPickup = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now.addingTimeInterval(3600)
    @State private var cloudRides: [TripStatus] = []
    @State private var fareEstimates: [String: FareEstimate] = [:]
    @State private var fareEstimateRequestID = UUID()
    @State private var isEstimatingFare = false
    @State private var savedPlaces: [SavedPlace] = []
    @State private var isSavedPlacesPresented = false
    @State private var isRatingPresented = false
    @State private var ratingRideID: String?
    @State private var ratingTarget: String?
    @State private var selectedPlaceIsPickup = true
    @State private var sessionToken = SessionStore.loadToken()
    @State private var accountRole = SessionStore.loadRole()
    @State private var driverAvailable = false
    @State private var driverOnboardingComplete = false
    @State private var driverRides: [DriverRide] = []
    @State private var isDriverLoading = false
    @State private var isSignInPresented = false
    @State private var isRequestingRide = false
    @State private var errorMessage: String?
    @State private var pendingPayment: PendingPayment?
    @State private var receipt: BookingReceipt?

    private var selectedRide: RideOption {
        RideOption.all.first(where: { $0.id == selectedRideID }) ?? RideOption.all[0]
    }

    private var selectedFare: FareEstimate? {
        fareEstimates[selectedRideID]
    }

    private var shouldTrackDriverLocation: Bool {
        accountRole == .driver &&
            (driverAvailable || driverRides.contains(where: { $0.status == "confirmed" }))
    }

    private var currentSelectedSavedPlace: RideLocation? {
        let coordinate = selectedPlaceIsPickup ? pickupCoordinate : destinationCoordinate
        guard let coordinate else { return nil }
        let label = selectedPlaceIsPickup
            ? (resolvedPickupLabel ?? pickup)
            : (resolvedDestinationLabel ?? destination)
        return RideLocation(label: label, coordinate: coordinate)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if selectedTab == .ride {
                rideScreen
            } else if selectedTab == .drive {
                driverScreen
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
                accountRole = SessionStore.loadRole()
                Task { await registerForPushNotifications() }
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
        .sheet(isPresented: $isSavedPlacesPresented) {
            if let sessionToken {
                SavedPlacesSheet(
                    token: sessionToken,
                    currentPlace: currentSelectedSavedPlace,
                    defaultName: selectedPlaceIsPickup ? "Pickup" : "Destination"
                ) { place in
                    applySavedPlace(place)
                } onChange: {
                    Task { await refreshSavedPlaces() }
                }
            }
        }
        .sheet(isPresented: $isRatingPresented) {
            if let sessionToken, let ratingRideID, let ratingTarget {
                RatingSheet(target: ratingTarget) { stars, comment in
                    Task { await submitRating(rideID: ratingRideID, stars: stars, comment: comment, token: sessionToken) }
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
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
            if sessionToken != nil {
                Task { await registerForPushNotifications() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .trypsAPNsTokenRegistered)) { notification in
            guard let deviceToken = notification.object as? String, let sessionToken else { return }
            Task { try? await RideAPI.registerDeviceToken(token: sessionToken, deviceToken: deviceToken) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .trypsRideNotificationOpened)) { notification in
            selectedTab = accountRole == .driver ? .drive : .activity
            if accountRole == .rider {
                Task { await refreshRiderDashboard() }
            } else {
                Task { await refreshDriverDashboard() }
            }
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == .drive, accountRole == .driver {
                Task { await refreshDriverDashboard() }
            }
        }
        .task(id: selectedTab) {
            if selectedTab == .drive, accountRole == .driver {
                guard await refreshDriverDashboard() else { return }
                while !Task.isCancelled {
                    guard await pollDriverDashboard() else { return }
                    try? await Task.sleep(for: .seconds(15))
                }
            } else if selectedTab == .activity, accountRole == .rider {
                while !Task.isCancelled {
                    await refreshRiderDashboard()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, selectedTab == .drive, accountRole == .driver {
                Task { await refreshDriverDashboard() }
            }
        }
        .onReceive(locationManager.$coordinate.compactMap { $0 }) { coordinate in
            if pickup == "Current location" || locationManager.address == pickup {
                pickupCoordinate = coordinate
            }
            if shouldTrackDriverLocation, let sessionToken {
                Task { try? await RideAPI.updateDriverLocation(token: sessionToken, coordinate: coordinate) }
            }
        }
        .onReceive(locationManager.$address.compactMap { $0 }) { address in
            if pickup == "Current location" || locationManager.address == pickup {
                resolvedPickupLabel = address
                pickup = address
            }
        }
        .onChange(of: pickup) { _, newValue in
            if newValue != resolvedPickupLabel {
                pickupCoordinate = nil
                resolvedPickupLabel = nil
            }
        }
        .onChange(of: destination) { _, newValue in
            if newValue != resolvedDestinationLabel {
                destinationCoordinate = nil
                resolvedDestinationLabel = nil
                fareEstimates = [:]
            }
        }
        .onChange(of: pickupCoordinate?.latitude) { _, _ in Task { await refreshFareEstimates() } }
        .onChange(of: pickupCoordinate?.longitude) { _, _ in Task { await refreshFareEstimates() } }
        .onChange(of: destinationCoordinate?.latitude) { _, _ in Task { await refreshFareEstimates() } }
        .onChange(of: destinationCoordinate?.longitude) { _, _ in Task { await refreshFareEstimates() } }
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
                if sessionToken == nil {
                    isSignInPresented = true
                } else if accountRole == .driver {
                    selectedTab = .drive
                } else {
                    selectedTab = .activity
                }
            } label: {
                Image(systemName: sessionToken == nil ? "person.crop.circle.fill" : "person.crop.circle.badge.checkmark")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(TrypsStyle.accent, Color.white)
                    .accessibilityLabel(sessionToken == nil ? "Sign in" : "Account signed in")
            }
            .buttonStyle(.plain)
            .accessibilityAction {
                if sessionToken == nil {
                    isSignInPresented = true
                } else if accountRole == .driver {
                    selectedTab = .drive
                } else {
                    selectedTab = .activity
                }
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
                if sessionToken != nil {
                    savedPlaceActions
                }
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
                    Text(selectedFare?.formattedFare ?? (isEstimatingFare ? "…" : "Estimate unavailable"))
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
            .disabled(isRequestingRide || isEstimatingFare || selectedFare == nil || destinationCoordinate == nil || pickupCoordinate == nil)
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
                Label(
                    scheduleForLater ? scheduledPickup.formatted(date: .abbreviated, time: .shortened) : "Today · now",
                    systemImage: "clock"
                )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TrypsStyle.muted)
            }

            VStack(spacing: 8) {
                ForEach(RideOption.all) { ride in
                    Button {
                        selectedRideID = ride.id
                    } label: {
                        RideOptionRow(
                            ride: ride,
                            fare: fareEstimates[ride.id],
                            isSelected: ride.id == selectedRideID
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(ride.id == selectedRideID ? .isSelected : [])
                }
            }

            if let selectedFare {
                Text("Approx. \(selectedFare.estimatedDistanceKm.formatted(.number.precision(.fractionLength(1)))) km · estimated fare")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TrypsStyle.muted)
            }

            Toggle("Schedule this ride", isOn: $scheduleForLater)
                .font(.system(size: 14, weight: .medium))
                .tint(TrypsStyle.accent)
            if scheduleForLater {
                DatePicker(
                    "Pickup time",
                    selection: $scheduledPickup,
                    in: Date.now.addingTimeInterval(16 * 60)...Date.now.addingTimeInterval(30 * 24 * 60 * 60),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .font(.system(size: 13, weight: .medium))
                .tint(TrypsStyle.accent)
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

                if sessionToken != nil {
                    if cloudRides.isEmpty {
                        emptyActivityCard
                    } else {
                        ForEach(cloudRides) { trip in
                            TripActivityRow(
                                trip: trip,
                                localShareURL: bookings.first(where: { $0.rideID == trip.id })?.shareURL,
                                onRate: { beginRating(rideID: trip.id, target: "driver") },
                                onCancel: { Task { await cancelRide(trip) } }
                            )
                        }
                    }
                } else if bookings.isEmpty {
                    emptyActivityCard
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

    private var emptyActivityCard: some View {
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
    }

    private var savedPlaceActions: some View {
        HStack {
            Button {
                selectedPlaceIsPickup = true
                isSavedPlacesPresented = true
            } label: {
                Label("Pickup saved", systemImage: "bookmark")
            }
            Spacer()
            Button {
                selectedPlaceIsPickup = false
                isSavedPlacesPresented = true
            } label: {
                Label("Destination saved", systemImage: "bookmark")
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(TrypsStyle.accent)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(.ride, title: "Ride", symbol: "car.side.fill")
            tabButton(.activity, title: "Activity", symbol: "clock.arrow.circlepath")
            if accountRole == .driver {
                tabButton(.drive, title: "Drive", symbol: "steeringwheel")
            }

        }
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(.white.shadow(.drop(color: .black.opacity(0.04), radius: 10, y: -3)))
    }

    private var driverScreen: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Drive with Tryps")
                        .font(.system(size: 29, weight: .bold, design: .rounded))
                        .foregroundStyle(TrypsStyle.ink)
                    Text("Go online when you’re ready to take a ride.")
                        .font(.system(size: 14))
                        .foregroundStyle(TrypsStyle.muted)
                }

                if !driverOnboardingComplete {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Set up driver payouts", systemImage: "creditcard")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(TrypsStyle.ink)
                        Text("Stripe securely collects the driver and bank details needed to receive payouts.")
                            .font(.system(size: 13))
                            .foregroundStyle(TrypsStyle.muted)
                        Button("Continue with Stripe") {
                            Task { await beginDriverOnboarding() }
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(TrypsStyle.accent, in: RoundedRectangle(cornerRadius: 15))
                    }
                    .padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20))
                } else if driverRides.isEmpty {
                    Button {
                        Task { await toggleDriverAvailability() }
                    } label: {
                        HStack {
                            Image(systemName: driverAvailable ? "pause.fill" : "steeringwheel")
                            Text(driverAvailable ? "Go offline" : "Go online")
                            Spacer()
                            Circle()
                                .fill(driverAvailable ? .green : TrypsStyle.muted)
                                .frame(width: 9, height: 9)
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 54)
                        .background(TrypsStyle.accent, in: RoundedRectangle(cornerRadius: 17))
                    }
                    .disabled(isDriverLoading)
                    if driverAvailable {
                        Text("While online, your location is shared to match nearby riders and stays active in the background. Go offline to stop sharing.")
                            .font(.system(size: 12))
                            .foregroundStyle(TrypsStyle.muted)
                    }
                } else {
                    Label("On a ride", systemImage: "car.side.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 54)
                        .background(TrypsStyle.accent, in: RoundedRectangle(cornerRadius: 17))
                }

                HStack {
                    Text("Assigned rides")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(TrypsStyle.ink)
                    Spacer()
                    Button("Refresh") { Task { await refreshDriverDashboard() } }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TrypsStyle.accent)
                        .disabled(isDriverLoading)
                }

                if driverRides.isEmpty {
                    Text(driverAvailable ? "You’re online. New assigned rides will appear here." : "No active rides.")
                        .font(.system(size: 13))
                        .foregroundStyle(TrypsStyle.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .background(.white, in: RoundedRectangle(cornerRadius: 18))
                } else {
                    ForEach(driverRides) { ride in
                        VStack(alignment: .leading, spacing: 10) {
                            Label(ride.pickup, systemImage: "circle.fill")
                            Label(ride.destination, systemImage: "mappin.and.ellipse")
                            if ride.status == "confirmed" {
                                Button("Complete ride") {
                                    Task { await completeDriverRide(ride) }
                                }
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(TrypsStyle.accent)
                            } else if ride.hasRated != true {
                                Button("Rate rider") { beginRating(rideID: ride.id, target: "rider") }
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(TrypsStyle.accent)
                            }
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(TrypsStyle.ink)
                        .padding(15)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white, in: RoundedRectangle(cornerRadius: 18))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
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
    private func refreshDriverDashboard() async -> Bool {
        guard let sessionToken, accountRole == .driver else { return false }
        guard !isDriverLoading else { return true }
        isDriverLoading = true
        defer { isDriverLoading = false }
        do {
            let profile = try await RideAPI.driverProfile(token: sessionToken)
            driverOnboardingComplete = profile.onboardingComplete
            driverAvailable = profile.available
            driverRides = try await RideAPI.assignedRides(token: sessionToken)
            if shouldTrackDriverLocation {
                locationManager.startTracking()
            } else {
                locationManager.stopTracking()
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @MainActor
    private func pollDriverDashboard() async -> Bool {
        guard let sessionToken, accountRole == .driver else { return false }
        guard !isDriverLoading else { return true }
        isDriverLoading = true
        defer { isDriverLoading = false }
        do {
            if driverAvailable {
                let heartbeatAccepted = try await RideAPI.driverHeartbeat(token: sessionToken)
                if !heartbeatAccepted {
                    driverAvailable = false
                    locationManager.stopTracking()
                }
            }
            driverRides = try await RideAPI.assignedRides(token: sessionToken)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @MainActor
    private func beginDriverOnboarding() async {
        guard let sessionToken else {
            isSignInPresented = true
            return
        }
        do {
            let url = try await RideAPI.driverOnboarding(token: sessionToken)
            openURL(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func toggleDriverAvailability() async {
        guard let sessionToken else { return }
        isDriverLoading = true
        defer { isDriverLoading = false }
        do {
            if !driverAvailable {
                locationManager.requestLocation()
                guard let coordinate = locationManager.coordinate else {
                    errorMessage = locationManager.errorMessage ?? "Wait for your current location, then try going online again."
                    return
                }
                try await RideAPI.updateDriverLocation(token: sessionToken, coordinate: coordinate)
            }
            let newAvailability = !driverAvailable
            try await RideAPI.setDriverAvailability(token: sessionToken, available: newAvailability)
            driverAvailable = newAvailability
            if newAvailability {
                locationManager.startTracking()
            } else {
                locationManager.stopTracking()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func completeDriverRide(_ ride: DriverRide) async {
        guard let sessionToken else { return }
        isDriverLoading = true
        defer { isDriverLoading = false }
        do {
            try await RideAPI.completeRide(token: sessionToken, rideID: ride.id)
            driverRides.removeAll { $0.id == ride.id }
            driverAvailable = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func refreshRiderDashboard() async {
        guard let sessionToken, accountRole == .rider else { return }
        do {
            cloudRides = try await RideAPI.rides(token: sessionToken)
            savedPlaces = try await RideAPI.savedPlaces(token: sessionToken)
            guard pendingPayment == nil else { return }
            if let unpaid = cloudRides.first(where: {
                $0.status == "awaiting_payment" && $0.paymentReady
            }), let trip = try? await RideAPI.ride(token: sessionToken, id: unpaid.id),
               let clientSecret = trip.paymentIntentClientSecret {
                let rideName = RideOption.all.first(where: { $0.id == trip.rideType })?.name ?? trip.rideType
                pendingPayment = PendingPayment(
                    id: trip.id,
                    clientSecret: clientSecret,
                    pickup: trip.pickup,
                    destination: trip.destination,
                    rideName: rideName,
                    fare: String(format: "$%.2f", Double(trip.amountCents) / 100),
                    shareURL: nil
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func refreshSavedPlaces() async {
        guard let sessionToken else { return }
        do {
            savedPlaces = try await RideAPI.savedPlaces(token: sessionToken)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func applySavedPlace(_ place: SavedPlace) {
        let coordinate = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
        if selectedPlaceIsPickup {
            pickup = place.label
            resolvedPickupLabel = place.label
            pickupCoordinate = coordinate
        } else {
            destination = place.label
            resolvedDestinationLabel = place.label
            destinationCoordinate = coordinate
        }
    }

    private func beginRating(rideID: String, target: String) {
        ratingRideID = rideID
        ratingTarget = target
        isRatingPresented = true
    }

    @MainActor
    private func registerForPushNotifications() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            do {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                return
            }
        }
        let updatedSettings = await UNUserNotificationCenter.current().notificationSettings()
        guard updatedSettings.authorizationStatus == .authorized ||
                updatedSettings.authorizationStatus == .provisional else { return }
        UIApplication.shared.registerForRemoteNotifications()
        if let deviceToken = UserDefaults.standard.string(forKey: TrypsAppDelegate.deviceTokenDefaultsKey),
           let sessionToken {
            try? await RideAPI.registerDeviceToken(token: sessionToken, deviceToken: deviceToken)
        }
    }

    @MainActor
    private func submitRating(rideID: String, stars: Int, comment: String, token: String) async {
        do {
            try await RideAPI.rateRide(token: token, rideID: rideID, stars: stars, comment: comment)
            isRatingPresented = false
            await refreshRiderDashboard()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func refreshFareEstimates() async {
        guard let pickupCoordinate, let destinationCoordinate else {
            fareEstimateRequestID = UUID()
            fareEstimates = [:]
            isEstimatingFare = false
            return
        }
        let requestID = UUID()
        fareEstimateRequestID = requestID
        isEstimatingFare = true
        fareEstimates = [:]
        defer {
            if fareEstimateRequestID == requestID {
                isEstimatingFare = false
            }
        }
        let pickup = RideLocation(label: self.pickup, coordinate: pickupCoordinate)
        let destination = RideLocation(label: self.destination, coordinate: destinationCoordinate)
        do {
            var estimates: [String: FareEstimate] = [:]
            for ride in RideOption.all {
                let request = RideRequest(
                    pickup: pickup,
                    destination: destination,
                    rideType: ride.id,
                    scheduledAt: nil
                )
                estimates[ride.id] = try await RideAPI.fareEstimate(request: request)
                guard fareEstimateRequestID == requestID else { return }
            }
            fareEstimates = estimates
        } catch {
            if fareEstimateRequestID == requestID {
                fareEstimates = [:]
            }
        }
    }

    @MainActor
    private func cancelRide(_ ride: TripStatus) async {
        guard let sessionToken else { return }
        do {
            if ride.status == "confirmed" {
                try await RideAPI.refundRide(token: sessionToken, rideID: ride.id)
            } else {
                try await RideAPI.cancelRide(token: sessionToken, rideID: ride.id)
            }
            await refreshRiderDashboard()
        } catch {
            errorMessage = error.localizedDescription
        }
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
                rideType: selectedRide.id,
                scheduledAt: scheduleForLater ? ISO8601DateFormatter().string(from: scheduledPickup) : nil
            )
            let response = try await RideAPI.requestRide(token: sessionToken, request: request)
            if response.status == "scheduled" {
                modelContext.insert(RideBooking(
                    pickup: trimmedPickup,
                    destination: trimmedDestination,
                    rideName: selectedRide.name,
                    fare: Self.formatFare(response.amountCents, currency: response.currency),
                    rideID: response.rideId,
                    shareURL: response.shareUrl.absoluteString,
                    status: response.status
                ))
                selectedTab = .activity
                errorMessage = "Ride scheduled for \(scheduledPickup.formatted(date: .abbreviated, time: .shortened)). We’ll find a nearby driver 15 minutes before pickup."
                return
            }
            guard let clientSecret = response.paymentIntentClientSecret else {
                throw RideAPIError.response
            }
            pendingPayment = PendingPayment(
                id: response.rideId,
                clientSecret: clientSecret,
                pickup: trimmedPickup,
                destination: trimmedDestination,
                rideName: selectedRide.name,
                fare: Self.formatFare(response.amountCents, currency: response.currency),
                shareURL: response.shareUrl
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func formatFare(_ amountCents: Int, currency: String) -> String {
        (Double(amountCents) / 100).formatted(.currency(code: currency.uppercased()))
    }

    @MainActor
    private func handlePaymentResult(_ result: PaymentSheetResult, payment: PendingPayment) {
        switch result {
        case .completed:
            let booking = RideBooking(
                pickup: payment.pickup,
                destination: payment.destination,
                rideName: payment.rideName,
                fare: payment.fare,
                rideID: payment.id,
                shareURL: payment.shareURL?.absoluteString,
                status: "awaiting_payment"
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
            resolvedPickupLabel = item.name ?? query
            pickup = resolvedPickupLabel ?? query
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
            resolvedDestinationLabel = item.name ?? query
            destination = resolvedDestinationLabel ?? query
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
    let fare: FareEstimate?
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

            Text(fare?.formattedFare ?? "—")
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
                if let status = booking.status {
                    Text(status.capitalized)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(TrypsStyle.accent)
                }
                if let shareURL = booking.shareURL.flatMap(URL.init(string:)) {
                    ShareLink(item: shareURL) {
                        Label("Share trip", systemImage: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .tint(TrypsStyle.accent)
                }
            }
        }
        .padding(15)
        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct TripActivityRow: View {
    let trip: TripStatus
    let localShareURL: String?
    let onRate: () -> Void
    let onCancel: () -> Void
    @State private var isSafetyCenterPresented = false
    @State private var isRefundConfirmationPresented = false

    private var tripShareURL: URL? {
        localShareURL.flatMap(URL.init(string:))
    }

    private var driverCoordinate: CLLocationCoordinate2D? {
        guard let latitude = trip.driverLatitude, let longitude = trip.driverLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(trip.rideType.replacingOccurrences(of: "-", with: " ").capitalized)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(TrypsStyle.ink)
                Spacer()
                Text(trip.status.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TrypsStyle.accent)
            }
            Label(trip.pickup, systemImage: "circle.fill")
            Label(trip.destination, systemImage: "mappin.and.ellipse")
            if let scheduledAt = trip.scheduledAt, let date = ISO8601DateFormatter().date(from: scheduledAt) {
                Label(date.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
            }
            if trip.status == "refund_pending" {
                Label("Full refund is processing. Your driver is not assigned to new rides.", systemImage: "arrow.uturn.backward.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TrypsStyle.muted)
            }
            if let coordinate = driverCoordinate, trip.status == "confirmed" {
                Map {
                    Annotation("Driver", coordinate: coordinate) {
                        Image(systemName: "car.fill")
                            .foregroundStyle(.white)
                            .padding(9)
                            .background(TrypsStyle.accent, in: Circle())
                    }
                }
                .mapStyle(.standard)
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .accessibilityLabel("Live map showing your driver's last reported location")
            } else if trip.status == "confirmed" {
                Label("Driver location is updating", systemImage: "location")
                    .font(.system(size: 11))
                    .foregroundStyle(TrypsStyle.muted)
            }
            HStack {
                Button {
                    isSafetyCenterPresented = true
                } label: {
                    Label("Safety", systemImage: "shield.lefthalf.filled")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(TrypsStyle.accent)
                Spacer()
                if trip.status == "completed", !trip.hasRated {
                    Button("Rate driver", action: onRate)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TrypsStyle.accent)
                }
                if trip.status == "scheduled" {
                    Button("Cancel reservation", action: onCancel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.red)
                }
                if trip.status == "confirmed" {
                    Button("Cancel & full refund") {
                        isRefundConfirmationPresented = true
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(TrypsStyle.muted)
        .padding(15)
        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .sheet(isPresented: $isSafetyCenterPresented) {
            SafetyCenterSheet(tripURL: tripShareURL)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .alert("Cancel ride and request a full refund?", isPresented: $isRefundConfirmationPresented) {
            Button("Keep ride", role: .cancel) {}
            Button("Request refund", role: .destructive, action: onCancel)
        } message: {
            Text("The ride will be canceled and Tryps will request a full refund through Stripe. Refund timing depends on your bank.")
        }
    }
}

private struct SafetyCenterSheet: View {
    let tripURL: URL?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(TrypsStyle.accent)
                    .frame(width: 46, height: 46)
                    .background(TrypsStyle.accent.opacity(0.1), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("Safety center")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(TrypsStyle.ink)
                    Text("Keep someone you trust in the loop.")
                        .font(.system(size: 13))
                        .foregroundStyle(TrypsStyle.muted)
                }
            }

            if let tripURL {
                ShareLink(
                    item: tripURL,
                    subject: Text("My Tryps ride"),
                    message: Text("Follow my trip status and driver's latest reported location.")
                ) {
                    Label("Share trip with a trusted contact", systemImage: "person.badge.shield.checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(TrypsStyle.accent, in: RoundedRectangle(cornerRadius: 15))
                }
            } else {
                Label("A trip-sharing link isn't available for this ride.", systemImage: "info.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(TrypsStyle.muted)
            }

            if let emergencyURL = URL(string: "tel:911") {
                Link(destination: emergencyURL) {
                    Label("Call 911 (United States)", systemImage: "phone.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
                }
            }
            Text("This starts a phone call only. Tryps does not contact or dispatch emergency services.")
                .font(.system(size: 11))
                .foregroundStyle(TrypsStyle.muted)
            Button("Done") { dismiss() }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TrypsStyle.ink)
                .frame(maxWidth: .infinity)
        }
        .padding(24)
        .padding(.top, 12)
    }
}

private struct SavedPlacesSheet: View {
    let token: String
    let currentPlace: RideLocation?
    let defaultName: String
    let onChoose: (SavedPlace) -> Void
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var places: [SavedPlace] = []
    @State private var name = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Saved places") {
                    if places.isEmpty {
                        Text("Save home, work, or another frequent stop.")
                            .foregroundStyle(TrypsStyle.muted)
                    }
                    ForEach(places) { place in
                        Button {
                            onChoose(place)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(place.name).fontWeight(.semibold)
                                Text(place.label).font(.caption).foregroundStyle(TrypsStyle.muted)
                            }
                        }
                        .tint(TrypsStyle.ink)
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                Task { await delete(place) }
                            }
                        }
                    }
                }

                Section("Add a saved place") {
                    TextField("Name (for example, Home)", text: $name)
                    if let currentPlace {
                        Text(currentPlace.label)
                            .font(.caption)
                            .foregroundStyle(TrypsStyle.muted)
                        Button("Save this place") {
                            Task { await save(currentPlace) }
                        }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        Text("Choose a pickup or destination on the ride screen first.")
                            .font(.caption)
                            .foregroundStyle(TrypsStyle.muted)
                    }
                }

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("Saved places")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                name = defaultName
                await load()
            }
        }
    }

    @MainActor
    private func load() async {
        do {
            places = try await RideAPI.savedPlaces(token: token)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func delete(_ place: SavedPlace) async {
        do {
            try await RideAPI.deleteSavedPlace(token: token, id: place.id)
            places.removeAll { $0.id == place.id }
            onChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func save(_ location: RideLocation) async {
        do {
            _ = try await RideAPI.savePlace(
                token: token,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                location: location
            )
            onChange()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct RatingSheet: View {
    let target: String
    let onSubmit: (Int, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var stars = 5
    @State private var comment = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("Rate your \(target)")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(TrypsStyle.ink)
            HStack(spacing: 10) {
                ForEach(1...5, id: \.self) { value in
                    Button {
                        stars = value
                    } label: {
                        Image(systemName: value <= stars ? "star.fill" : "star")
                            .font(.system(size: 27))
                            .foregroundStyle(Color.orange)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(value) stars")
                }
            }
            TextField("Add a comment (optional)", text: $comment, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            Button("Submit rating") {
                onSubmit(stars, comment)
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(TrypsStyle.accent, in: RoundedRectangle(cornerRadius: 15))
        }
        .padding(24)
        .padding(.top, 12)
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
            Text("Payment submitted. Your driver will appear once it’s confirmed.")
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
