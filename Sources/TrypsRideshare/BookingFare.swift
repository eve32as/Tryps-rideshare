import Foundation

enum BookingFare {
    static func total(baseFare: Int, pickupSurcharge: Int, dropOffSurcharge: Int) -> Int {
        baseFare + pickupSurcharge + dropOffSurcharge
    }

    static func formatted(_ amount: Int, locale: Locale = .current) -> String {
        amount.formatted(
            .currency(code: "USD")
                .precision(.fractionLength(0))
                .locale(locale)
        )
    }
}
