#if canImport(SwiftUI) && canImport(FirebaseFirestore) && canImport(FirebaseFunctions)
import SwiftUI
import MapKit
@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseFunctions

struct RideQuote: Identifiable {
    let id: String
    let rideType: String
    let rideLabel: String
    let amountCents: Int
    let currency: String
    let distanceKm: Double
    let baseFareCents: Int
    let distanceFareCents: Int
    let surgeMultiplier: Double
    let surgeAdjustmentCents: Int
    let bookingFeeCents: Int
    let minimumFareAdjustmentCents: Int
    let estimatedDurationSeconds: Int

    var formattedAmount: String {
        (Double(amountCents) / 100).formatted(.currency(code: currency.uppercased()))
    }

    var formattedFareBreakdown: String {
        let base = (Double(baseFareCents) / 100).formatted(.currency(code: currency.uppercased()))
        let distance = (Double(distanceFareCents) / 100).formatted(.currency(code: currency.uppercased()))
        let surge = (Double(surgeAdjustmentCents) / 100).formatted(.currency(code: currency.uppercased()))
        let booking = (Double(bookingFeeCents) / 100).formatted(.currency(code: currency.uppercased()))
        let surgeLine = surgeAdjustmentCents > 0
            ? " + \(surge) demand adjustment (\(surgeMultiplier.formatted(.number.precision(.fractionLength(2))))×)"
            : ""
        let minimum = minimumFareAdjustmentCents > 0
            ? " · minimum fare adjustment \((Double(minimumFareAdjustmentCents) / 100).formatted(.currency(code: currency.uppercased())))"
            : ""
        return "\(base) base + \(distance) route distance\(surgeLine) + \(booking) booking fee\(minimum)"
    }
}

struct RidePaymentSession: Identifiable {
    let id: String
    let clientSecret: String
    let publishableKey: String
}

struct RiderDriverInfo {
    let displayName: String
    let vehicleDescription: String
    let licensePlate: String
}

@MainActor
final class FirebaseRideStore: ObservableObject {
    static let shared = FirebaseRideStore()

    @Published private(set) var quotes: [String: RideQuote] = [:]
    @Published private(set) var paymentSession: RidePaymentSession?
    @Published private(set) var rideId: String?
    @Published private(set) var rideStatus: String?
    @Published private(set) var paymentStatus: String?
    @Published private(set) var dispatchMessage: String?
    @Published private(set) var driverInfo: RiderDriverInfo?
    @Published private(set) var driverLocation: CLLocationCoordinate2D?
    @Published private(set) var driverLocationUpdatedAt: Date?
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    private var rideListener: ListenerRegistration?

    private init() { }

    func loadQuotes(pickup: CLLocationCoordinate2D, dropOff: CLLocationCoordinate2D, rideTypes: [String]) async {
        quotes = [:]
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }

        do {
            let result = try await call("createRideQuote", data: [
                "pickup": ["latitude": pickup.latitude, "longitude": pickup.longitude],
                "dropOff": ["latitude": dropOff.latitude, "longitude": dropOff.longitude],
                "rideTypes": rideTypes,
            ])
            guard let responseQuotes = result["quotes"] as? [[String: Any]] else {
                throw RideServiceError.invalidResponse
            }
            for values in responseQuotes {
                guard let quoteId = values["quoteId"] as? String,
                      let rideType = values["rideType"] as? String,
                      let label = values["rideLabel"] as? String,
                      let amount = values["amountCents"] as? Int,
                      let currency = values["currency"] as? String,
                      let distanceKm = values["distanceKm"] as? Double,
                      let baseFare = values["baseFareCents"] as? Int,
                      let distanceFare = values["distanceFareCents"] as? Int,
                      let surgeMultiplier = values["surgeMultiplier"] as? Double,
                      let surgeAdjustment = values["surgeAdjustmentCents"] as? Int,
                      let bookingFee = values["bookingFeeCents"] as? Int,
                      let minimumFareAdjustment = values["minimumFareAdjustmentCents"] as? Int,
                      let duration = values["estimatedDurationSeconds"] as? Int else {
                    throw RideServiceError.invalidResponse
                }
                quotes[rideType] = RideQuote(
                    id: quoteId,
                    rideType: rideType,
                    rideLabel: label,
                    amountCents: amount,
                    currency: currency,
                    distanceKm: distanceKm,
                    baseFareCents: baseFare,
                    distanceFareCents: distanceFare,
                    surgeMultiplier: surgeMultiplier,
                    surgeAdjustmentCents: surgeAdjustment,
                    bookingFeeCents: bookingFee,
                    minimumFareAdjustmentCents: minimumFareAdjustment,
                    estimatedDurationSeconds: duration
                )
            }
        } catch {
            quotes = [:]
            errorMessage = "Couldn’t get ride prices. Check your connection and try again."
        }
    }

    func requestRide(
        quote: RideQuote,
        womanDriverForWomenAndMinors: Bool,
        ecoFriendlyVehicle: Bool
    ) async {
        guard rideId == nil else {
            await startPayment(for: rideId!)
            return
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let booking = try await call("createRideBooking", data: [
                "quoteId": quote.id,
                "preferences": [
                    "womanDriverForWomenAndMinors": womanDriverForWomenAndMinors,
                    "ecoFriendlyVehicle": ecoFriendlyVehicle,
                ],
            ])
            guard let newRideId = booking["rideId"] as? String else {
                throw RideServiceError.invalidResponse
            }
            rideId = newRideId
            listenForRide(id: newRideId)
            try await createPaymentSession(for: newRideId)
        } catch {
            errorMessage = "Couldn’t start your booking. Please try again."
        }
    }

    func retryPayment() async {
        guard let rideId else { return }
        await startPayment(for: rideId)
    }

    private func startPayment(for rideId: String) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await createPaymentSession(for: rideId)
        } catch {
            errorMessage = "Couldn’t start payment. Please try again."
        }
    }

    private func createPaymentSession(for rideId: String) async throws {
        let result = try await call("createRidePaymentIntent", data: ["rideId": rideId])
        guard let clientSecret = result["clientSecret"] as? String,
              let publishableKey = result["publishableKey"] as? String else {
            throw RideServiceError.invalidResponse
        }
        paymentSession = RidePaymentSession(
            id: UUID().uuidString,
            clientSecret: clientSecret,
            publishableKey: publishableKey
        )
    }

    func paymentFinished(_ result: RidePaymentResult) {
        paymentSession = nil
        switch result {
        case .completed:
            errorMessage = nil
        case .cancelled:
            errorMessage = "Payment was cancelled. You can try again."
        case .failed:
            errorMessage = "Payment didn’t go through. Please try another payment method."
        }
    }

    func cancelRide() async {
        guard let rideId else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await call("cancelRideBooking", data: ["rideId": rideId])
            errorMessage = nil
        } catch {
            errorMessage = "Couldn’t cancel this ride. Please try again."
        }
    }

    func resetRide() {
        rideListener?.remove()
        rideListener = nil
        rideId = nil
        rideStatus = nil
        paymentStatus = nil
        dispatchMessage = nil
        driverInfo = nil
        driverLocation = nil
        driverLocationUpdatedAt = nil
        quotes = [:]
        errorMessage = nil
    }

    private func listenForRide(id: String) {
        rideListener?.remove()
        rideListener = Firestore.firestore().collection("rides").document(id)
            .addSnapshotListener { [weak self] snapshot, error in
                let data = snapshot?.data()
                let status = data?["status"] as? String
                let paymentStatus = data?["paymentStatus"] as? String
                let message = data?["dispatchMessage"] as? String
                let driverValues = data?["driverInfo"] as? [String: Any]
                let driverInfo = driverValues.flatMap { values -> RiderDriverInfo? in
                    guard let displayName = values["displayName"] as? String,
                          let vehicleDescription = values["vehicleDescription"] as? String,
                          let licensePlate = values["licensePlate"] as? String else { return nil }
                    return RiderDriverInfo(
                        displayName: displayName,
                        vehicleDescription: vehicleDescription,
                        licensePlate: licensePlate
                    )
                }
                let locationValues = data?["driverLocation"] as? [String: Any]
                let driverLocation: CLLocationCoordinate2D? = {
                    guard let latitude = (locationValues?["latitude"] as? NSNumber)?.doubleValue,
                          let longitude = (locationValues?["longitude"] as? NSNumber)?.doubleValue else {
                        return nil
                    }
                    let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                    return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
                }()
                let locationUpdatedAt = (data?["driverLocationUpdatedAt"] as? Timestamp)?.dateValue()
                Task { @MainActor in
                    guard let self else { return }
                    if error != nil {
                        self.errorMessage = "Couldn’t refresh your ride status."
                    }
                    self.rideStatus = status
                    self.paymentStatus = paymentStatus
                    self.dispatchMessage = message
                    self.driverInfo = driverInfo
                    self.driverLocation = driverLocation
                    self.driverLocationUpdatedAt = locationUpdatedAt
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
                    continuation.resume(throwing: RideServiceError.invalidResponse)
                }
            }
        }
    }
}

private enum RideServiceError: Error {
    case invalidResponse
}

#if canImport(StripePaymentSheet) && canImport(UIKit)
import StripePaymentSheet
import UIKit

enum RidePaymentResult {
    case completed
    case cancelled
    case failed
}

struct StripePaymentSheetPresenter: UIViewControllerRepresentable {
    let session: RidePaymentSession
    let completion: (RidePaymentResult) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> PaymentSheetPresentationController {
        let controller = PaymentSheetPresentationController()
        context.coordinator.completion = completion
        context.coordinator.present(session, from: controller)
        controller.onAppear = { [weak coordinator = context.coordinator] controller in
            coordinator?.present(session, from: controller)
        }
        return controller
    }

    func updateUIViewController(_ controller: PaymentSheetPresentationController, context: Context) {
        context.coordinator.completion = completion
        context.coordinator.present(session, from: controller)
    }

    final class Coordinator {
        var completion: ((RidePaymentResult) -> Void)?
        private var presentedSessionID: String?

        func present(_ session: RidePaymentSession, from controller: UIViewController) {
            guard presentedSessionID != session.id, controller.viewIfLoaded?.window != nil else { return }
            presentedSessionID = session.id
            STPAPIClient.shared.publishableKey = session.publishableKey
            var configuration = PaymentSheet.Configuration()
            configuration.merchantDisplayName = "Tryps"
            let paymentSheet = PaymentSheet(
                paymentIntentClientSecret: session.clientSecret,
                configuration: configuration
            )
            paymentSheet.present(from: controller) { [weak self] result in
                switch result {
                case .completed:
                    self?.completion?(.completed)
                case .canceled:
                    self?.completion?(.cancelled)
                case .failed:
                    self?.completion?(.failed)
                }
            }
        }
    }
}

final class PaymentSheetPresentationController: UIViewController {
    var onAppear: ((UIViewController) -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onAppear?(self)
    }
}
#else
enum RidePaymentResult {
    case completed
    case cancelled
    case failed
}
#endif
#elseif canImport(SwiftUI)
import SwiftUI
import MapKit

enum RidePaymentResult {
    case completed
    case cancelled
    case failed
}

struct RidePaymentSession: Identifiable {
    let id: String
    let clientSecret: String
    let publishableKey: String
}

struct RideQuote: Identifiable {
    let id: String
    let rideType: String
    let rideLabel: String
    let amountCents: Int
    let currency: String
    let distanceKm: Double
    let baseFareCents: Int
    let distanceFareCents: Int
    let surgeMultiplier: Double
    let surgeAdjustmentCents: Int
    let bookingFeeCents: Int
    let minimumFareAdjustmentCents: Int
    let estimatedDurationSeconds: Int

    var formattedAmount: String {
        (Double(amountCents) / 100).formatted(.currency(code: currency.uppercased()))
    }

    var formattedFareBreakdown: String {
        let base = (Double(baseFareCents) / 100).formatted(.currency(code: currency.uppercased()))
        let distance = (Double(distanceFareCents) / 100).formatted(.currency(code: currency.uppercased()))
        let surge = (Double(surgeAdjustmentCents) / 100).formatted(.currency(code: currency.uppercased()))
        let booking = (Double(bookingFeeCents) / 100).formatted(.currency(code: currency.uppercased()))
        let surgeLine = surgeAdjustmentCents > 0
            ? " + \(surge) demand adjustment (\(surgeMultiplier.formatted(.number.precision(.fractionLength(2))))×)"
            : ""
        let minimum = minimumFareAdjustmentCents > 0
            ? " · minimum adjustment \((Double(minimumFareAdjustmentCents) / 100).formatted(.currency(code: currency.uppercased())))"
            : ""
        return "\(base) base + \(distance) route distance\(surgeLine) + \(booking) booking fee\(minimum)"
    }
}

@MainActor
final class FirebaseRideStore: ObservableObject {
    static let shared = FirebaseRideStore()
    @Published private(set) var quotes: [String: RideQuote] = [:]
    @Published private(set) var paymentSession: RidePaymentSession?
    @Published private(set) var rideId: String?
    @Published private(set) var rideStatus: String?
    @Published private(set) var paymentStatus: String?
    @Published private(set) var dispatchMessage: String?
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    private init() { }

    func loadQuotes(pickup: CLLocationCoordinate2D, dropOff: CLLocationCoordinate2D, rideTypes: [String]) async {
        errorMessage = "Add Firebase Firestore and Functions to the Swift package to enable ride quotes."
    }

    func requestRide(
        quote: RideQuote,
        womanDriverForWomenAndMinors: Bool,
        ecoFriendlyVehicle: Bool
    ) async {
        errorMessage = "Ride booking is available in the configured Xcode app."
    }

    func retryPayment() async { }
    func paymentFinished(_ result: RidePaymentResult) { }
    func cancelRide() async { }
    func resetRide() {
        rideId = nil
        rideStatus = nil
        paymentStatus = nil
        dispatchMessage = nil
        quotes = [:]
        errorMessage = nil
    }
}
#endif
