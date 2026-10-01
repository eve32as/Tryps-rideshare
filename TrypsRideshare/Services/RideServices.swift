import AuthenticationServices
import Combine
import CryptoKit
import CoreLocation
import Security
import StripePaymentSheet
import SwiftUI
import UIKit

enum AccountRole: String, CaseIterable, Identifiable {
    case rider
    case driver

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }
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
}

struct RideRequestResponse: Decodable {
    let rideId: String
    let status: String
    let paymentIntentClientSecret: String
    let amountCents: Int
    let currency: String
}

struct PendingPayment: Identifiable {
    let id: String
    let clientSecret: String
    let pickup: String
    let destination: String
    let rideName: String
    let fare: String
}

enum RideAPIError: LocalizedError {
    case configuration
    case response
    case server(String)

    var errorDescription: String? {
        switch self {
        case .configuration:
            "Set TRYPS_API_BASE_URL in the Xcode build settings to your HTTPS API URL."
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
    }

    static func signIn(identityToken: String, nonce: String, role: AccountRole) async throws -> String {
        let request = AppleSignInRequest(identityToken: identityToken, nonce: nonce, role: role.rawValue)
        let response: AppleSignInResponse = try await send("/v1/auth/apple", method: "POST", body: request)
        return response.sessionToken
    }

    static func requestRide(token: String, request: RideRequest) async throws -> RideRequestResponse {
        try await send("/v1/rides", method: "POST", body: request, token: token)
    }

    static func cancelRide(token: String, rideID: String) async throws {
        let _: CancellationResponse = try await send(
            "/v1/rides/\(rideID)",
            method: "DELETE",
            body: EmptyBody(),
            token: token
        )
    }

    private static func send<Response: Decodable, Body: Encodable>(
        _ path: String,
        method: String,
        body: Body,
        token: String? = nil
    ) async throws -> Response {
        guard
            let configuredURL = Bundle.main.object(forInfoDictionaryKey: "TRYPS_API_BASE_URL") as? String,
            let baseURL = URL(string: configuredURL),
            baseURL.scheme == "https",
            let url = URL(string: path, relativeTo: baseURL)
        else {
            throw RideAPIError.configuration
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bear" + "er " + token, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)

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

private struct EmptyBody: Encodable {}

struct PaymentSheetPresenter: UIViewControllerRepresentable {
    let clientSecret: String
    let onCompletion: (PaymentSheetResult) -> Void

    func makeUIViewController(context: Context) -> PaymentSheetPresenterController {
        let controller = PaymentSheetPresenterController()
        controller.presentPayment = { [clientSecret, onCompletion] presenter in
            guard
                let key = Bundle.main.object(forInfoDictionaryKey: "STRIPE_PUBLISHABLE_KEY") as? String,
                key.hasPrefix("pk_")
            else {
                onCompletion(.failed(error: RideAPIError.configuration))
                return
            }
            StripeAPI.defaultPublishableKey = key
            var configuration = PaymentSheet.Configuration()
            configuration.merchantDisplayName = "Tryps"
            configuration.allowsDelayedPaymentMethods = false
            let sheet = PaymentSheet(paymentIntentClientSecret: clientSecret, configuration: configuration)
            sheet.present(from: presenter, completion: onCompletion)
        }
        return controller
    }

    func updateUIViewController(_ controller: PaymentSheetPresenterController, context: Context) {}
}

final class PaymentSheetPresenterController: UIViewController {
    var presentPayment: ((UIViewController) -> Void)?
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
    private static let account = "api-token"

    static func loadToken() -> String? {
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

    static func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
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
            try SessionStore.saveToken(session)
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

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
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

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestLocation()
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
}
