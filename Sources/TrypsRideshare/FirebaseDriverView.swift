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
    @Published private(set) var isAvailable = false
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    private var offerListener: ListenerRegistration?
    private var applicationListener: ListenerRegistration?
    private var driverListener: ListenerRegistration?
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
                let available = snapshot?.data()?["available"] as? Bool ?? false
                Task { @MainActor in self?.isAvailable = available }
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
        offerListener?.remove()
        applicationListener?.remove()
        driverListener?.remove()
        rideListener?.remove()
        offerListener = nil
        applicationListener = nil
        driverListener = nil
        rideListener = nil
        listeningUserID = nil
        listeningAsDriver = false
        offers = []
    }

    func submitApplication(displayName: String, vehicle: String, plate: String) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            _ = try await call("applyToDrive", data: [
                "displayName": displayName,
                "vehicleDescription": vehicle,
                "licensePlate": plate,
            ])
            applicationSubmitted = true
        } catch {
            errorMessage = "Couldn’t submit your application. Check the details and try again."
        }
    }

    func setAvailability(_ available: Bool, location: CLLocationCoordinate2D?) async {
        guard let location else {
            errorMessage = "Allow location and tap the location button before going online."
            return
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            _ = try await call("setDriverAvailability", data: [
                "available": available,
                "location": ["latitude": location.latitude, "longitude": location.longitude],
            ])
            isAvailable = available
        } catch {
            errorMessage = "Couldn’t update driver availability."
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
                Task { @MainActor in
                    if status == "cancelled" || status == "completed" {
                        self?.activeRideId = nil
                        self?.activeRideStatus = nil
                        self?.rideListener?.remove()
                        self?.rideListener = nil
                    } else {
                        self?.activeRideStatus = status
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
    @State private var displayName = ""
    @State private var vehicle = ""
    @State private var plate = ""

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
        }
        .onChange(of: account.isDriver) { _, isDriver in
            if let userID = account.userID {
                driver.start(userID: userID, isDriver: isDriver)
            }
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
                Button {
                    Task {
                        await driver.submitApplication(
                            displayName: displayName,
                            vehicle: vehicle,
                            plate: plate
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
                    if !driver.isAvailable && locationManager.location == nil {
                        locationManager.requestLocation()
                        driver.errorMessage = "Fetching location. Tap Go online again when your pickup is visible."
                    } else {
                        Task {
                            await driver.setAvailability(
                                !driver.isAvailable,
                                location: driver.isAvailable ? nil : locationManager.location?.coordinate
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

            if let status = driver.activeRideStatus {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current trip · \(status.replacingOccurrences(of: "_", with: " ").capitalized)")
                        .font(.subheadline.weight(.semibold))
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
