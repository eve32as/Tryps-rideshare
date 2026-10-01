import SwiftData
import SwiftUI

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

    @State private var selectedTab = AppTab.ride
    @State private var selectedRideID = RideOption.all[0].id
    @State private var pickup = "Current location"
    @State private var destination = ""
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
                selectedTab = .activity
            } label: {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(TrypsStyle.accent, Color.white)
                    .accessibilityLabel("Open ride activity")
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

                RouteMapPreview()
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .accessibilityLabel("Map preview showing a suggested route")

                routeFields
                ridePicker
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 18)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: requestRide) {
                HStack {
                    Image(systemName: "car.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Request \(selectedRide.name)")
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
            .disabled(destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1)
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(TrypsStyle.canvas)
        }
    }

    private var routeFields: some View {
        VStack(spacing: 0) {
            routeField(symbol: "circle.fill", tint: TrypsStyle.accent, placeholder: "Pickup location", text: $pickup)
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
            routeField(symbol: "mappin.and.ellipse", tint: Color(red: 0.83, green: 0.40, blue: 0.25), placeholder: "Where are you going?", text: $destination)
        }
        .padding(.vertical, 5)
        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(TrypsStyle.line.opacity(0.7), lineWidth: 1))
    }

    private func routeField(symbol: String, tint: Color, placeholder: String, text: Binding<String>) -> some View {
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

    private func requestRide() {
        let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPickup = pickup.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDestination.isEmpty, !trimmedPickup.isEmpty else { return }

        let booking = RideBooking(
            pickup: trimmedPickup,
            destination: trimmedDestination,
            rideName: selectedRide.name,
            fare: selectedRide.price
        )
        modelContext.insert(booking)
        receipt = BookingReceipt(
            pickup: booking.pickup,
            destination: booking.destination,
            rideName: booking.rideName,
            fare: booking.fare
        )
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
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Color(red: 0.89, green: 0.92, blue: 0.86)

                Path { path in
                    path.move(to: CGPoint(x: -10, y: size.height * 0.22))
                    path.addCurve(to: CGPoint(x: size.width + 10, y: size.height * 0.38), control1: CGPoint(x: size.width * 0.35, y: size.height * 0.12), control2: CGPoint(x: size.width * 0.55, y: size.height * 0.55))
                    path.move(to: CGPoint(x: -10, y: size.height * 0.76))
                    path.addCurve(to: CGPoint(x: size.width + 10, y: size.height * 0.67), control1: CGPoint(x: size.width * 0.35, y: size.height * 0.62), control2: CGPoint(x: size.width * 0.68, y: size.height * 0.87))
                    path.move(to: CGPoint(x: size.width * 0.28, y: -10))
                    path.addCurve(to: CGPoint(x: size.width * 0.49, y: size.height + 10), control1: CGPoint(x: size.width * 0.16, y: size.height * 0.35), control2: CGPoint(x: size.width * 0.58, y: size.height * 0.55))
                    path.move(to: CGPoint(x: size.width * 0.78, y: -10))
                    path.addCurve(to: CGPoint(x: size.width * 0.67, y: size.height + 10), control1: CGPoint(x: size.width * 0.91, y: size.height * 0.33), control2: CGPoint(x: size.width * 0.57, y: size.height * 0.7))
                }
                .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 13, lineCap: .round))

                Path { path in
                    path.move(to: CGPoint(x: size.width * 0.28, y: size.height * 0.76))
                    path.addCurve(to: CGPoint(x: size.width * 0.75, y: size.height * 0.27), control1: CGPoint(x: size.width * 0.43, y: size.height * 0.71), control2: CGPoint(x: size.width * 0.58, y: size.height * 0.28))
                }
                .stroke(TrypsStyle.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [1, 0]))

                mapPin(symbol: "location.fill", color: TrypsStyle.accent)
                    .position(x: size.width * 0.28, y: size.height * 0.76)
                mapPin(symbol: "mappin.and.ellipse", color: Color(red: 0.83, green: 0.40, blue: 0.25))
                    .position(x: size.width * 0.75, y: size.height * 0.27)

                VStack {
                    HStack {
                        Label("SAN FRANCISCO", systemImage: "location.north.fill")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(TrypsStyle.ink.opacity(0.72))
                        Spacer()
                        Image(systemName: "plus.magnifyingglass")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(TrypsStyle.ink)
                            .frame(width: 32, height: 32)
                            .background(.white.opacity(0.9), in: Circle())
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        Label("3.2 mi", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(TrypsStyle.ink)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .background(.white.opacity(0.94), in: Capsule())
                    }
                }
                .padding(14)
            }
        }
    }

    private func mapPin(symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(color, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
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
