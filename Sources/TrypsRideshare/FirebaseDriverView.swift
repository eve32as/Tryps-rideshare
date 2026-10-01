#if canImport(SwiftUI) && canImport(FirebaseFirestore) && canImport(FirebaseFunctions)
import SwiftUI
import MapKit
@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseFunctions

private struct DriverOffer: Identifiable {
    let id: String
    let pickup: CLLocationCoordinate2D
    let dropOff: CLLocationCoordinate2D
    let rideType: String
}
@MainActor
private final class FirebaseDriverStore: ObservableObject {
    static let shared = FirebaseDriverStore()

    @Published private(set) var offers: [DriverOffer] = []
    @Published private(set) var applicationSubmitted = false
    @Published private(set) var activeRideId: String?
    @Published private(set) var activeRideStatus: String?
    @Published private(set) var activeRidePickup: CLLocationCoordinate2D?
    @Published private(set) var activeRideDropOff: CLLocationCoordinate2D?
    @Published private(set) var isAvailable = false
    @Published private(set) var acceptsWomenAndMinorsRides = false
    @Published private(set) var ecoFriendlyVehicle = false
    @Published private(set) var preferencesLoaded = false
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    private var offerListener: ListenerRegistration?
    private var applicationListener: ListenerRegistration?
    private var driverListener: ListenerRegistration?
    private var assignedRidesListener: ListenerRegistration?
    private var rideListener: ListenerRegistration?
    private var listeningUserID: String?
    private var listeningAsDriver = false

    private init() { }

    func start(userID: String, isDriver: Bool) {
        guard listeningUserID != userID || listeningAsDriver != isDriver else { return }
        stop()
        listeningUserID = userID
        listeningAsDriver = isDriver

        applicationListener = Firestore.firestore().collection("driverApplications")
            .document(userID)
            .addSnapshotListener { [weak self] snapshot, _ in
                let submitted = snapshot?.exists == true
                Task { @MainActor in self?.applicationSubmitted = submitted }
            }

        guard isDriver else { return }
        driverListener = Firestore.firestore().collection("drivers").document(userID)
            .addSnapshotListener { [weak self] snapshot, _ in
                let data = snapshot?.data()
                let available = data?["available"] as? Bool ?? false
                let acceptsWomenAndMinorsRides = data?["acceptsWomenAndMinorsRides"] as? Bool ?? false
                let ecoFriendlyVehicle = data?["ecoFriendlyVehicle"] as? Bool ?? false
                Task { @MainActor in
                    self?.isAvailable = available
                    self?.acceptsWomenAndMinorsRides = acceptsWomenAndMinorsRides
                    self?.ecoFriendlyVehicle = ecoFriendlyVehicle
                    self?.preferencesLoaded = snapshot?.exists == true
                }
            }
        assignedRidesListener = Firestore.firestore().collection("rides")
            .whereField("driverUid", isEqualTo: userID)
            .addSnapshotListener { [weak self] snapshot, _ in
                let activeRideID = snapshot?.documents.first(where: {
                    ["driver_assigned", "en_route", "arrived", "in_progress"].contains(
                        $0.data()["status"] as? String ?? ""
                    )
                })?.documentID
                let activeRideData = snapshot?.documents.first(where: {
                    $0.documentID == activeRideID
                })?.data()
                let pickup = (activeRideData?["pickup"] as? [String: Any]).flatMap(Self.coordinate)
                let dropOff = (activeRideData?["dropOff"] as? [String: Any]).flatMap(Self.coordinate)
                Task { @MainActor in
                    guard let self else { return }
                    if let activeRideID, self.activeRideId != activeRideID {
                        self.activeRideId = activeRideID
                        self.activeRidePickup = pickup
                        self.activeRideDropOff = dropOff
                        self.listenForActiveRide(activeRideID)
                    } else if activeRideID == nil, self.activeRideId != nil {
                        self.activeRideId = nil
                        self.activeRideStatus = nil
                        self.activeRidePickup = nil
                        self.activeRideDropOff = nil
                        self.rideListener?.remove()
                        self.rideListener = nil
                    }
                }
            }
        offerListener = Firestore.firestore().collection("drivers")
            .document(userID)
            .collection("offers")
            .whereField("status", isEqualTo: "pending")
            .addSnapshotListener { [weak self] snapshot, error in
                let offers = snapshot?.documents.compactMap { document -> DriverOffer? in
                    guard let data = document.data() as? [String: Any],
                          let expiry = data["expiresAt"] as? Timestamp,
                          expiry.dateValue() > Date(),
                          let pickupData = data["pickup"] as? [String: Any],
                          let dropOffData = data["dropOff"] as? [String: Any],
                          let rideType = data["rideType"] as? String,
                          let pickup = Self.coordinate(pickupData),
                          let dropOff = Self.coordinate(dropOffData) else { return nil }
                    return DriverOffer(id: document.documentID, pickup: pickup, dropOff: dropOff, rideType: rideType)
                } ?? []
                Task { @MainActor in
                    self?.offers = offers
                    if error != nil {
                        self?.errorMessage = "Couldn’t refresh ride offers."
                    }
                }
            }
    }

    func stop() {
        if isAvailable {
            Task {
                _ = try? await call("setDriverAvailability", data: ["available": false])
            }
        }
        offerListener?.remove()
        applicationListener?.remove()
        driverListener?.remove()
        assignedRidesListener?.remove()
        rideListener?.remove()
        offerListener = nil
        applicationListener = nil
        driverListener = nil
        assignedRidesListener = nil
        rideListener = nil
        listeningUserID = nil
        listeningAsDriver = false
        offers = []
        applicationSubmitted = false
        activeRideId = nil
        activeRideStatus = nil
        activeRidePickup = nil
        activeRideDropOff = nil
        isAvailable = false
        acceptsWomenAndMinorsRides = false
        ecoFriendlyVehicle = false
        preferencesLoaded = false
    }

    func submitApplication(
        displayName: String,
        vehicle: String,
        plate: String,
        acceptsWomenAndMinorsRides: Bool,
        ecoFriendlyVehicle: Bool
    ) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            _ = try await call("applyToDrive", data: [
                "displayName": displayName,
                "vehicleDescription": vehicle,
                "licensePlate": plate,
                "acceptsWomenAndMinorsRides": acceptsWomenAndMinorsRides,
                "ecoFriendlyVehicle": ecoFriendlyVehicle,
            ])
            applicationSubmitted = true
        } catch {
            errorMessage = "Couldn’t submit your application. Check the details and try again."
        }
    }

    func setAvailability(_ available: Bool, location: CLLocationCoordinate2D?) async {
        guard available == false || location != nil else {
            errorMessage = "Allow location and tap the location button before going online."
            return
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            var data: [String: Any] = ["available": available]
            if let location {
                data["location"] = ["latitude": location.latitude, "longitude": location.longitude]
            }
            _ = try await call("setDriverAvailability", data: data)
            isAvailable = available
        } catch {
            errorMessage = "Couldn’t update driver availability."
        }
    }

    func setRidePreferences(acceptsWomenAndMinorsRides: Bool, ecoFriendlyVehicle: Bool) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            _ = try await call("setDriverRidePreferences", data: [
                "acceptsWomenAndMinorsRides": acceptsWomenAndMinorsRides,
                "ecoFriendlyVehicle": ecoFriendlyVehicle,
            ])
            self.acceptsWomenAndMinorsRides = acceptsWomenAndMinorsRides
            self.ecoFriendlyVehicle = ecoFriendlyVehicle
        } catch {
            errorMessage = "Couldn’t update your ride preferences."
        }
    }

    func updateLocation(_ location: CLLocationCoordinate2D) async {
        do {
            _ = try await call("updateDriverLocation", data: [
                "location": ["latitude": location.latitude, "longitude": location.longitude],
            ])
        } catch {
            errorMessage = "Couldn’t refresh your location. Ride offers may pause."
        }
    }

    func accept(_ offer: DriverOffer) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            _ = try await call("claimRideOffer", data: ["rideId": offer.id])
            isAvailable = false
            activeRideId = offer.id
            listenForActiveRide(offer.id)
        } catch {
            errorMessage = "This ride offer is no longer available."
        }
    }

    func advanceTrip() async {
        guard let activeRideId, let activeRideStatus else { return }
        let next: String
        switch activeRideStatus {
        case "driver_assigned": next = "en_route"
        case "en_route": next = "arrived"
        case "arrived": next = "in_progress"
        case "in_progress": next = "completed"
        default: return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await call("updateRideStatus", data: ["rideId": activeRideId, "status": next])
            if next == "completed" {
                rideListener?.remove()
                rideListener = nil
                self.activeRideId = nil
                self.activeRideStatus = nil
            }
        } catch {
            errorMessage = "Couldn’t update the trip. Please retry."
        }
    }

    private func listenForActiveRide(_ rideID: String) {
        rideListener?.remove()
        rideListener = Firestore.firestore().collection("rides").document(rideID)
            .addSnapshotListener { [weak self] snapshot, _ in
                let status = snapshot?.data()?["status"] as? String
                let rideData = snapshot?.data()
                let pickup = (rideData?["pickup"] as? [String: Any]).flatMap(Self.coordinate)
                let dropOff = (rideData?["dropOff"] as? [String: Any]).flatMap(Self.coordinate)
                Task { @MainActor in
                    if status == "cancelled" || status == "completed" {
                        self?.activeRideId = nil
                        self?.activeRideStatus = nil
                        self?.activeRidePickup = nil
                        self?.activeRideDropOff = nil
                        self?.rideListener?.remove()
                        self?.rideListener = nil
                    } else {
                        self?.activeRideStatus = status
                        self?.activeRidePickup = pickup
                        self?.activeRideDropOff = dropOff
                    }
                }
            }
    }

    private func call(_ name: String, data: [String: Any]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            Functions.functions(region: "us-central1").httpsCallable(name).call(data) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let value = result?.data as? [String: Any] {
                    continuation.resume(returning: value)
                } else {
                    continuation.resume(throwing: DriverServiceError.invalidResponse)
                }
            }
        }
    }

    private static func coordinate(_ values: [String: Any]) -> CLLocationCoordinate2D? {
        guard let latitude = (values["latitude"] as? NSNumber)?.doubleValue,
              let longitude = (values["longitude"] as? NSNumber)?.doubleValue else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }
}

private enum DriverServiceError: Error {
    case invalidResponse
}

struct FirebaseDriverView: View {
    @ObservedObject var account: FirebaseAccountStore
    @ObservedObject var locationManager: PickupLocationManager
    @StateObject private var driver = FirebaseDriverStore.shared
    @StateObject private var navigation = DriverNavigationStore.shared
    @State private var displayName = ""
    @State private var vehicle = ""
    @State private var plate = ""
    @State private var acceptsWomenAndMinorsRides = false
    @State private var ecoFriendlyVehicle = false

    var body: some View {
        Group {
            if account.isDriver {
                driverDashboard
            } else {
                driverApplication
            }
        }
        .onAppear {
            if let userID = account.userID {
                driver.start(userID: userID, isDriver: account.isDriver)
            }
            startNavigationIfNeeded()
        }
        .onChange(of: account.isDriver) { _, isDriver in
            if let userID = account.userID {
                driver.start(userID: userID, isDriver: isDriver)
            }
        }
        .onChange(of: account.userID) { _, userID in
            if let userID {
                driver.start(userID: userID, isDriver: account.isDriver)
            } else {
                driver.stop()
            }
        }
        .onChange(of: driver.activeRideStatus) { _, status in
            startNavigationIfNeeded()
        }
        .onChange(of: driver.activeRideId) { _, _ in
            startNavigationIfNeeded()
        }
        .task(id: driver.isAvailable) {
            guard driver.isAvailable else {
                locationManager.stopUpdatingLocation()
                return
            }
            locationManager.startUpdatingLocation()
            while !Task.isCancelled {
                if let location = locationManager.location,
                   abs(Date().timeIntervalSince(location.timestamp)) <= 120 {
                    await driver.updateLocation(location.coordinate)
                }
                try? await Task.sleep(for: .seconds(60))
            }
            locationManager.stopUpdatingLocation()
        }
        .onDisappear {
            driver.stop()
            navigation.stop()
        }
    }

    private var driverApplication: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Drive with Tryps")
                .font(.headline)
                .foregroundStyle(TrypsStyle.ink)
            if driver.applicationSubmitted {
                Label("Application submitted for review", systemImage: "hourglass")
                    .font(.footnote)
                    .foregroundStyle(TrypsStyle.muted)
            } else {
                TextField("Full name", text: $displayName)
                    .textContentType(.name)
                    .textFieldStyle(.roundedBorder)
                TextField("Vehicle (year, make, model)", text: $vehicle)
                    .textFieldStyle(.roundedBorder)
                TextField("License plate", text: $plate)
                    .textInputAutocapitalization(.characters)
                    .textFieldStyle(.roundedBorder)
                Toggle("Electric or hybrid vehicle", isOn: $ecoFriendlyVehicle)
                Toggle(isOn: $acceptsWomenAndMinorsRides) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Woman driver opt-in")
                        Text("I identify as a woman and opt in to requests for women and minors.")
                            .font(.caption)
                            .foregroundStyle(TrypsStyle.muted)
                    }
                }
                Button {
                    Task {
                        await driver.submitApplication(
                            displayName: displayName,
                            vehicle: vehicle,
                            plate: plate,
                            acceptsWomenAndMinorsRides: acceptsWomenAndMinorsRides,
                            ecoFriendlyVehicle: ecoFriendlyVehicle
                        )
                    }
                } label: {
                    if driver.isWorking {
                        ProgressView()
                    } else {
                        Text("Apply to drive")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(TrypsStyle.green)
                .disabled(driver.isWorking)
                Text("Applications require manual review before driver access is enabled.")
                    .font(.caption)
                    .foregroundStyle(TrypsStyle.muted)
            }
            if let error = driver.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 10)
    }

    private var driverDashboard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Driver mode").font(.headline).foregroundStyle(TrypsStyle.ink)
                    Text(driver.isAvailable ? "Online · receiving offers" : "Offline")
                        .font(.footnote)
                        .foregroundStyle(TrypsStyle.muted)
                }
                Spacer()
                Button {
                    let currentLocation = locationManager.location.flatMap {
                        abs(Date().timeIntervalSince($0.timestamp)) <= 60 ? $0.coordinate : nil
                    }
                    if !driver.isAvailable && currentLocation == nil {
                        locationManager.requestLocation()
                        driver.errorMessage = "Fetching location. Tap Go online again when your pickup is visible."
                    } else {
                        Task {
                            await driver.setAvailability(
                                !driver.isAvailable,
                                location: driver.isAvailable ? nil : currentLocation
                            )
                        }
                    }
                } label: {
                    Text(driver.isAvailable ? "Go offline" : "Go online")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(driver.isAvailable ? TrypsStyle.muted : TrypsStyle.green)
                .disabled(driver.isWorking)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("RIDE PREFERENCES")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TrypsStyle.muted)
                Toggle(isOn: Binding(
                    get: { driver.acceptsWomenAndMinorsRides },
                    set: { value in
                        Task {
                            await driver.setRidePreferences(
                                acceptsWomenAndMinorsRides: value,
                                ecoFriendlyVehicle: driver.ecoFriendlyVehicle
                            )
                        }
                    }
                )) {
                    Text("Opt in to women and minors requests")
                }
                Toggle(isOn: Binding(
                    get: { driver.ecoFriendlyVehicle },
                    set: { value in
                        Task {
                            await driver.setRidePreferences(
                                acceptsWomenAndMinorsRides: driver.acceptsWomenAndMinorsRides,
                                ecoFriendlyVehicle: value
                            )
                        }
                    }
                )) {
                    Text("Electric or hybrid vehicle")
                }
            }
            .disabled(!driver.preferencesLoaded || driver.isWorking)

            if let status = driver.activeRideStatus {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current trip · \(status.replacingOccurrences(of: "_", with: " ").capitalized)")
                        .font(.subheadline.weight(.semibold))
                    if navigation.isNavigating {
                        DriverNavigationPanel(navigation: navigation)
                    }
                    Button(nextTripAction(for: status)) {
                        Task { await driver.advanceTrip() }
                    }
                    .buttonStyle(.bordered)
                    .tint(TrypsStyle.green)
                    .disabled(driver.isWorking)
                }
                .padding(12)
                .background(TrypsStyle.paleGreen, in: RoundedRectangle(cornerRadius: 14))
            } else {
                ForEach(driver.offers) { offer in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(offer.rideType.capitalized) ride offer")
                            .font(.subheadline.weight(.semibold))
                        Text("Pickup \(offer.pickup.latitude.formatted(.number.precision(.fractionLength(3)))), \(offer.pickup.longitude.formatted(.number.precision(.fractionLength(3))))")
                            .font(.caption)
                            .foregroundStyle(TrypsStyle.muted)
                        Button("Accept ride") {
                            Task { await driver.accept(offer) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(TrypsStyle.green)
                        .disabled(driver.isWorking)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(TrypsStyle.paleGreen, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            if let error = driver.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 10)
    }

    private func nextTripAction(for status: String) -> String {
        switch status {
        case "driver_assigned": "Start driving"
        case "en_route": "Arrived at pickup"
        case "arrived": "Start trip"
        case "in_progress": "Complete trip"
        default: "Update trip"
        }
    }

    private func startNavigationIfNeeded() {
        guard let rideID = driver.activeRideId,
              let pickup = driver.activeRidePickup,
              let dropOff = driver.activeRideDropOff,
              let status = driver.activeRideStatus else {
            navigation.stop()
            return
        }
        navigation.start(rideID: rideID, pickup: pickup, dropOff: dropOff, status: status)
    }
}
#elseif canImport(SwiftUI)
import SwiftUI

struct FirebaseDriverView: View {
    @ObservedObject var account: FirebaseAccountStore
    @ObservedObject var locationManager: PickupLocationManager

    var body: some View {
        Text("Driver tools are available in the Firebase-configured Xcode app.")
            .font(.footnote)
            .foregroundStyle(TrypsStyle.muted)
            .padding(.vertical, 10)
    }
}
#endif
