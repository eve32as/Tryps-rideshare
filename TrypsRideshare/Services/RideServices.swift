import AuthenticationServices
import Combine
import CryptoKit
import CoreLocation
import Security
import StripePaymentSheet
import SwiftUI
import UIKit
import UserNotifications

extension Notification.Name {
    static let trypsAPNsTokenRegistered = Notification.Name("trypsAPNsTokenRegistered")
    static let trypsRideNotificationOpened = Notification.Name("trypsRideNotificationOpened")
}

final class TrypsAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let deviceTokenDefaultsKey = "trypsAPNsDeviceToken"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: Self.deviceTokenDefaultsKey)
        NotificationCenter.default.post(name: .trypsAPNsTokenRegistered, object: token)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("APNs registration failed: \(error.localizedDescription)")
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let rideID = response.notification.request.content.userInfo["rideId"] as? String
        NotificationCenter.default.post(name: .trypsRideNotificationOpened, object: rideID)
        completionHandler()
    }
}

enum AccountRole: String, CaseIterable, Identifiable {
    case rider
    case driver

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }
}

struct DriverRide: Decodable, Identifiable {
    let id: String
    let pickup: String
    let destination: String
    let pickupLatitude: Double?
    let pickupLongitude: Double?
    let destinationLatitude: Double?
    let destinationLongitude: Double?
    let rideType: String
    let status: String
    let hasRated: Bool?

    var pickupCoordinate: CLLocationCoordinate2D? {
        guard let latitude = pickupLatitude, let longitude = pickupLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var destinationCoordinate: CLLocationCoordinate2D? {
        guard let latitude = destinationLatitude, let longitude = destinationLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct DriverHeatCell: Decodable, Identifiable {
    let latitude: Double
    let longitude: Double
    let count: Int

    var id: String { "\(latitude)-\(longitude)" }
}

struct SignedInSession {
    let sessionToken: String
    let role: AccountRole
}

struct DriverProfile: Decodable {
    let onboardingComplete: Bool
    let available: Bool
}

struct SavedPlace: Codable, Identifiable {
    let id: String
    let name: String
    let label: String
    let latitude: Double
    let longitude: Double
}

struct TripStatus: Decodable, Identifiable {
    let id: String
    let pickup: String
    let destination: String
    let pickupLatitude: Double?
    let pickupLongitude: Double?
    let destinationLatitude: Double?
    let destinationLongitude: Double?
    let rideType: String
    let amountCents: Int
    let currency: String
    let status: String
    let scheduledAt: String?
    let createdAt: String
    let paymentReady: Bool
    let paymentIntentClientSecret: String?
    let driverLatitude: Double?
    let driverLongitude: Double?
    let hasRated: Bool

    var pickupCoordinate: CLLocationCoordinate2D? {
        guard let latitude = pickupLatitude, let longitude = pickupLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var destinationCoordinate: CLLocationCoordinate2D? {
        guard let latitude = destinationLatitude, let longitude = destinationLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct TripShare: Decodable {
    let rideId: String
    let status: String
    let scheduledAt: String?
    let amountCents: Int
    let currency: String
    let paymentIntentClientSecret: String?
    let shareUrl: URL
}

private struct RideListResponse: Decodable {
    let rides: [TripStatus]
}

private struct SavedPlacesResponse: Decodable {
    let places: [SavedPlace]
}

struct RideLocation: Encodable {
    let label: String
    let latitude: Double
    let longitude: Double

    init(label: String, coordinate: CLLocationCoordinate2D) {
        self.label = label
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }
}

struct RideRequest: Encodable {
    let pickup: RideLocation
    let destination: RideLocation
    let rideType: String
    let scheduledAt: String?
    let fareQuoteToken: String?
}

struct FareEstimateRequest: Encodable {
    let pickup: RideLocation
    let destination: RideLocation
    let rideTypes: [String]
}

private struct FareEstimatesResponse: Decodable {
    let estimates: [String: FareEstimate]
}

struct RideRequestResponse: Decodable {
    let rideId: String
    let status: String
    let paymentIntentClientSecret: String?
    let amountCents: Int
    let currency: String
    let shareUrl: URL
}

struct FareEstimate: Decodable {
    let amountCents: Int
    let estimatedDistanceKm: Double
    let currency: String
    let baseFareCents: Int
    let distanceChargeCents: Int
    let subtotalCents: Int
    let multipliedFareCents: Int
    let perKmCents: Int
    let rideTypeMultiplier: Double
    let minimumFareCents: Int
    let minimumApplied: Bool
    let fareQuoteToken: String
    let expiresAt: String

    var formattedFare: String {
        formatted(amountCents)
    }

    func formatted(_ cents: Int) -> String {
        (Double(cents) / 100).formatted(.currency(code: currency.uppercased()))
    }
}

struct PendingPayment: Identifiable {
    let id: String
    let clientSecret: String
    let pickup: String
    let destination: String
    let rideName: String
    let fare: String
    let shareURL: URL?
}

enum RideAPIError: LocalizedError {
    case configuration
    case paymentConfiguration
    case response
    case server(String)

    var errorDescription: String? {
        switch self {
        case .configuration:
            "Set TRYPS_API_BASE_URL in the Xcode build settings to your HTTPS API URL."
        case .paymentConfiguration:
            "Set STRIPE_PUBLISHABLE_KEY in the Xcode build settings."
        case .response:
            "The server returned an invalid response."
        case .server(let message):
            message
        }
    }
}

enum RideAPI {
    private struct AppleSignInRequest: Encodable {
        let identityToken: String
        let nonce: String
        let role: String
    }

    private struct AppleSignInResponse: Decodable {
        let sessionToken: String
        let role: String
    }

    static func signIn(identityToken: String, nonce: String, role: AccountRole) async throws -> SignedInSession {
        let request = AppleSignInRequest(identityToken: identityToken, nonce: nonce, role: role.rawValue)
        let response: AppleSignInResponse = try await send("/v1/auth/apple", method: "POST", body: request)
        guard let role = AccountRole(rawValue: response.role) else { throw RideAPIError.response }
        return SignedInSession(sessionToken: response.sessionToken, role: role)
    }

    static func registerDeviceToken(token: String, deviceToken: String) async throws {
        let _: DeviceTokenResponse = try await send(
            "/v1/notifications/device",
            method: "PUT",
            body: DeviceTokenRequest(deviceToken: deviceToken),
            token: token
        )
    }

    static func requestRide(token: String, request: RideRequest) async throws -> RideRequestResponse {
        try await send("/v1/rides", method: "POST", body: request, token: token)
    }

    static func fareEstimates(request: FareEstimateRequest) async throws -> [String: FareEstimate] {
        let response: FareEstimatesResponse = try await send("/v1/fare-estimate", method: "POST", body: request)
        return response.estimates
    }

    static func rides(token: String) async throws -> [TripStatus] {
        let response: RideListResponse = try await send("/v1/rides", method: "GET", token: token)
        return response.rides
    }

    static func ride(token: String, id: String) async throws -> TripStatus {
        try await send("/v1/rides/\(id)", method: "GET", token: token)
    }

    static func rateRide(token: String, rideID: String, stars: Int, comment: String) async throws {
        let _: RatingResponse = try await send(
            "/v1/rides/\(rideID)/ratings",
            method: "POST",
            body: RatingRequest(stars: stars, comment: comment),
            token: token
        )
    }

    static func savedPlaces(token: String) async throws -> [SavedPlace] {
        let response: SavedPlacesResponse = try await send("/v1/saved-places", method: "GET", token: token)
        return response.places
    }

    static func savePlace(token: String, name: String, location: RideLocation) async throws -> SavedPlace {
        try await send("/v1/saved-places", method: "POST", body: SavePlaceRequest(name: name, location: location), token: token)
    }

    static func deleteSavedPlace(token: String, id: String) async throws {
        let _: DeletedPlaceResponse = try await send("/v1/saved-places/\(id)", method: "DELETE", token: token)
    }

    static func cancelRide(token: String, rideID: String) async throws {
        let _: CancellationResponse = try await send(
            "/v1/rides/\(rideID)",
            method: "DELETE",
            body: EmptyBody(),
            token: token
        )
    }

    static func refundRide(token: String, rideID: String) async throws {
        let _: RefundResponse = try await send(
            "/v1/rides/\(rideID)/refund",
            method: "POST",
            body: EmptyBody(),
            token: token
        )
    }

    static func driverOnboarding(token: String) async throws -> URL {
        let response: DriverOnboardingResponse = try await send(
            "/v1/driver/connect-onboarding",
            method: "POST",
            body: EmptyBody(),
            token: token
        )
        return response.onboardingUrl
    }

    static func driverProfile(token: String) async throws -> DriverProfile {
        try await send("/v1/driver/profile", method: "GET", token: token)
    }

    static func updateDriverLocation(token: String, coordinate: CLLocationCoordinate2D) async throws {
        let location = DriverCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let _: DriverLocationResponse = try await send(
            "/v1/driver/location",
            method: "PUT",
            body: location,
            token: token
        )
    }

    static func setDriverAvailability(token: String, available: Bool) async throws {
        let _: DriverAvailabilityResponse = try await send(
            "/v1/driver/availability",
            method: "PATCH",
            body: DriverAvailabilityRequest(available: available),
            token: token
        )
    }

    static func driverHeartbeat(token: String) async throws -> Bool {
        let response: DriverAvailabilityResponse = try await send(
            "/v1/driver/heartbeat",
            method: "POST",
            body: EmptyBody(),
            token: token
        )
        return response.available
    }

    static func assignedRides(token: String) async throws -> [DriverRide] {
        let response: DriverRidesResponse = try await send(
            "/v1/driver/rides",
            method: "GET",
            token: token
        )
        return response.rides
    }

    static func driverHeatmap(token: String, center: CLLocationCoordinate2D) async throws -> [DriverHeatCell] {
        let latitude = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), center.latitude)
        let longitude = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), center.longitude)
        let path = "/v1/driver-heatmap?latitude=\(latitude)&longitude=\(longitude)"
        let response: DriverHeatmapResponse = try await send(path, method: "GET", token: token)
        return response.cells
    }

    static func completeRide(token: String, rideID: String) async throws {
        let _: RideCompletedResponse = try await send(
            "/v1/driver/rides/\(rideID)/complete",
            method: "POST",
            body: EmptyBody(),
            token: token
        )
    }

    private static func send<Response: Decodable>(
        _ path: String,
        method: String,
        token: String? = nil
    ) async throws -> Response {
        var request = try makeRequest(path, method: method, token: token)
        return try await perform(&request)
    }

    private static func send<Response: Decodable, Body: Encodable>(
        _ path: String,
        method: String,
        body: Body,
        token: String? = nil
    ) async throws -> Response {
        var request = try makeRequest(path, method: method, token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(&request)
    }

    private static func makeRequest(_ path: String, method: String, token: String?) throws -> URLRequest {
        guard
            let configuredURL = Bundle.main.object(forInfoDictionaryKey: "TRYPS_API_BASE_URL") as? String,
            let baseURL = URL(string: configuredURL),
            baseURL.scheme == "https",
            baseURL.host?.hasSuffix(".invalid") == false,
            let url = URL(string: path, relativeTo: baseURL)
        else {
            throw RideAPIError.configuration
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token {
            request.setValue("Bear" + "er " + token, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func perform<Response: Decodable>(_ request: inout URLRequest) async throws -> Response {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw RideAPIError.response }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(APIErrorResponse.self, from: data).error)
                ?? "The request failed. Please try again."
            throw RideAPIError.server(message)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

private struct APIErrorResponse: Decodable {
    let error: String
}

private struct CancellationResponse: Decodable {
    let cancelled: Bool
}

private struct RefundResponse: Decodable {
    let cancelled: Bool
    let refunded: Bool
    let refundId: String
}

private struct DeviceTokenRequest: Encodable {
    let deviceToken: String
}

private struct DeviceTokenResponse: Decodable {
    let registered: Bool
}

private struct RatingRequest: Encodable {
    let stars: Int
    let comment: String
}

private struct RatingResponse: Decodable {
    let rated: Bool
}

private struct SavePlaceRequest: Encodable {
    let name: String
    let location: RideLocation
}

private struct DeletedPlaceResponse: Decodable {
    let deleted: Bool
}

private struct DriverOnboardingResponse: Decodable {
    let onboardingUrl: URL
}

private struct DriverCoordinate: Encodable {
    let latitude: Double
    let longitude: Double
}

private struct DriverLocationResponse: Decodable {
    let updated: Bool
}

private struct DriverAvailabilityRequest: Encodable {
    let available: Bool
}

private struct DriverAvailabilityResponse: Decodable {
    let available: Bool
}

private struct DriverRidesResponse: Decodable {
    let rides: [DriverRide]
}

private struct DriverHeatmapResponse: Decodable {
    let cells: [DriverHeatCell]
}

private struct RideCompletedResponse: Decodable {
    let completed: Bool
}

private struct EmptyBody: Encodable {}

struct PaymentSheetPresenter: UIViewControllerRepresentable {
    let clientSecret: String
    let onCompletion: (PaymentSheetResult) -> Void

    func makeUIViewController(context: Context) -> PaymentSheetPresenterController {
        let controller = PaymentSheetPresenterController()
        controller.presentPayment = { [clientSecret, onCompletion] presenter in
            guard
                let key = Bundle.main.object(forInfoDictionaryKey: "STRIPE_PUBLISHABLE_KEY") as? String,
                key.hasPrefix("pk_"),
                !key.contains("replace_me")
            else {
                onCompletion(.failed(error: RideAPIError.paymentConfiguration))
                return
            }
            StripeAPI.defaultPublishableKey = key
            var configuration = PaymentSheet.Configuration()
            configuration.merchantDisplayName = "Tryps"
            configuration.allowsDelayedPaymentMethods = false
            let sheet = PaymentSheet(paymentIntentClientSecret: clientSecret, configuration: configuration)
            presenter.paymentSheet = sheet
            sheet.present(from: presenter, completion: onCompletion)
        }
        return controller
    }

    func updateUIViewController(_ controller: PaymentSheetPresenterController, context: Context) {}
}

final class PaymentSheetPresenterController: UIViewController {
    var presentPayment: ((UIViewController) -> Void)?
    var paymentSheet: PaymentSheet?
    private var didPresent = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didPresent else { return }
        didPresent = true
        presentPayment?(self)
    }
}

enum SessionStore {
    private static let service = "com.tryps.rideshare.session"
    private static let tokenAccount = "api-token"
    private static let roleAccount = "account-role"

    static func loadToken() -> String? {
        load(account: tokenAccount)
    }

    static func loadRole() -> AccountRole? {
        guard let value = load(account: roleAccount) else { return nil }
        return AccountRole(rawValue: value)
    }

    static func save(sessionToken: String, role: AccountRole) throws {
        try save(sessionToken, account: tokenAccount)
        try save(role.rawValue, account: roleAccount)
    }

    private static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw RideAPIError.server("Could not securely save your session.")
        }
    }
}

struct AppleSignInSheet: View {
    let onSignedIn: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var role: AccountRole = .rider
    @State private var rawNonce = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "arrow.trianglehead.branch")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(TrypsStyle.accent, in: RoundedRectangle(cornerRadius: 20))
                .padding(.top, 24)

            VStack(spacing: 6) {
                Text("Welcome to tryps")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundStyle(TrypsStyle.ink)
                Text("Choose how you’ll use Tryps.")
                    .font(.system(size: 14))
                    .foregroundStyle(TrypsStyle.muted)
            }

            Picker("Account type", selection: $role) {
                ForEach(AccountRole.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)

            SignInWithAppleButton(.signIn) { request in
                do {
                    rawNonce = try Self.makeNonce()
                    request.nonce = Self.sha256(rawNonce)
                    request.requestedScopes = [.email, .fullName]
                } catch {
                    errorMessage = "Could not start secure sign-in. Please try again."
                }
            } onCompletion: { result in
                Task { await completeSignIn(result) }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 52)
            .disabled(isSigningIn)

            if isSigningIn {
                ProgressView("Signing in…")
                    .tint(TrypsStyle.accent)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .background(TrypsStyle.canvas.ignoresSafeArea())
    }

    @MainActor
    private func completeSignIn(_ result: Result<ASAuthorization, Error>) async {
        guard !rawNonce.isEmpty else {
            errorMessage = "Restart sign-in and try again."
            return
        }
        isSigningIn = true
        defer { isSigningIn = false }

        do {
            let authorization = try result.get()
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let identityToken = credential.identityToken,
                let token = String(data: identityToken, encoding: .utf8)
            else {
                throw RideAPIError.response
            }
            let session = try await RideAPI.signIn(identityToken: token, nonce: rawNonce, role: role)
            try SessionStore.save(sessionToken: session.sessionToken, role: session.role)
            onSignedIn()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func makeNonce() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw RideAPIError.response
        }
        return Data(bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

final class PickupLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var address: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var geofenceMessage: String?

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var tracksContinuously = false
    private var assignedRidesForGeofencing: [DriverRide] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 50
    }

    func requestLocation() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            errorMessage = "Enable location access in Settings to use your current pickup."
        @unknown default:
            errorMessage = "Location access is unavailable."
        }
    }

    func startTracking() {
        tracksContinuously = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways:
            manager.allowsBackgroundLocationUpdates = true
            manager.pausesLocationUpdatesAutomatically = false
            manager.showsBackgroundLocationIndicator = true
            manager.startUpdatingLocation()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
            errorMessage = "Allow Tryps location access Always to keep your driver location updated while the app is in the background."
        case .denied, .restricted:
            errorMessage = "Enable location access in Settings to go online."
        @unknown default:
            errorMessage = "Location access is unavailable."
        }
    }

    func stopTracking() {
        tracksContinuously = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
    }

    func syncRideGeofences(for rides: [DriverRide]) {
        assignedRidesForGeofencing = rides
        let activeRides = rides.filter { $0.status == "confirmed" }
        let desiredRegions = activeRides.flatMap { ride -> [CLCircularRegion] in
            [
                makeRegion(
                    rideID: ride.id,
                    kind: "pickup",
                    latitude: ride.pickupLatitude,
                    longitude: ride.pickupLongitude
                ),
                makeRegion(
                    rideID: ride.id,
                    kind: "destination",
                    latitude: ride.destinationLatitude,
                    longitude: ride.destinationLongitude
                ),
            ].compactMap { $0 }
        }
        let desiredIdentifiers = Set(desiredRegions.map(\.identifier))
        for region in manager.monitoredRegions where
            region.identifier.hasPrefix("tryps-ride-") && !desiredIdentifiers.contains(region.identifier) {
            manager.stopMonitoring(for: region)
        }
        guard manager.authorizationStatus == .authorizedAlways,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            if !activeRides.isEmpty {
                geofenceMessage = "Allow Always location access to get pickup and destination proximity alerts."
            }
            return
        }
        let activeIdentifiers = Set(manager.monitoredRegions.map(\.identifier))
        for region in desiredRegions where !activeIdentifiers.contains(region.identifier) {
            manager.startMonitoring(for: region)
        }
    }

    private func makeRegion(
        rideID: String,
        kind: String,
        latitude: Double?,
        longitude: Double?
    ) -> CLCircularRegion? {
        guard let latitude, let longitude,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            return nil
        }
        let region = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            radius: 150,
            identifier: "tryps-ride-\(rideID)-\(kind)"
        )
        region.notifyOnEntry = true
        region.notifyOnExit = false
        return region
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways {
            if tracksContinuously {
                manager.allowsBackgroundLocationUpdates = true
                manager.pausesLocationUpdatesAutomatically = false
                manager.showsBackgroundLocationIndicator = true
                manager.startUpdatingLocation()
            } else {
                manager.requestLocation()
            }
            syncRideGeofences(for: assignedRidesForGeofencing)
        } else if manager.authorizationStatus == .authorizedWhenInUse {
            if tracksContinuously {
                manager.requestAlwaysAuthorization()
                errorMessage = "Allow Tryps location access Always to keep your driver location updated while the app is in the background."
            } else {
                manager.requestLocation()
            }
        } else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            errorMessage = "Enable location access in Settings to use your current pickup."
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        coordinate = location.coordinate
        errorMessage = nil
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            guard let place = placemarks?.first else { return }
            let label = [place.name, place.locality].compactMap { $0 }.joined(separator: ", ")
            DispatchQueue.main.async {
                self?.address = label.isEmpty ? nil : label
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        errorMessage = "Couldn’t determine your location. Try again or enter a pickup."
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier.hasPrefix("tryps-ride-") else { return }
        let place = region.identifier.hasSuffix("-pickup") ? "pickup" : "destination"
        let message = "You’re near the ride \(place) location."
        geofenceMessage = message
        let content = UNMutableNotificationContent()
        content.title = "Tryps ride update"
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: region.identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
