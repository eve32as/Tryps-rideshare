#if canImport(SwiftUI)
import SwiftUI

private enum TrypsStyle {
    static let ink = Color(red: 0.10, green: 0.15, blue: 0.14)
    static let muted = Color(red: 0.47, green: 0.52, blue: 0.50)
    static let green = Color(red: 0.10, green: 0.45, blue: 0.34)
    static let paleGreen = Color(red: 0.90, green: 0.95, blue: 0.92)
    static let line = Color(red: 0.91, green: 0.93, blue: 0.92)
}

private struct Destination: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let symbol: String

    static let suggestions = [
        Destination(id: "mission", name: "Mission Dolores Park", subtitle: "Dolores St, San Francisco", symbol: "leaf"),
        Destination(id: "sfo", name: "San Francisco Airport", subtitle: "San Francisco International", symbol: "airplane"),
        Destination(id: "ferry", name: "Ferry Building", subtitle: "1 Ferry Building, San Francisco", symbol: "water.waves"),
        Destination(id: "chase", name: "Chase Center", subtitle: "1 Warriors Way, San Francisco", symbol: "basketball"),
        Destination(id: "painted", name: "Painted Ladies", subtitle: "Steiner St, San Francisco", symbol: "house"),
    ]
}

private struct Ride: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let symbol: String
    let seats: Int
    let fare: Int

    static let options = [
        Ride(id: "everyday", name: "Everyday", detail: "4 min away", symbol: "car.side.fill", seats: 4, fare: 18),
        Ride(id: "comfort", name: "Comfort", detail: "6 min away", symbol: "car.side.fill", seats: 4, fare: 26),
        Ride(id: "xl", name: "XL", detail: "8 min away", symbol: "car.2.fill", seats: 6, fare: 32),
    ]
}

struct ContentView: View {
    @State private var destination = Destination.suggestions[0]
    @State private var selectedRide = Ride.options[0]
    @State private var isChoosingDestination = false
    @State private var isRideRequested = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                MapPreview()
                    .frame(height: geometry.size.height * 0.55)
                    .ignoresSafeArea(edges: .top)

                VStack(spacing: 0) {
                    header
                        .padding(.top, geometry.safeAreaInsets.top + 10)
                        .padding(.horizontal, 22)

                    Spacer(minLength: 0)

                    bookingPanel
                        .frame(height: geometry.size.height * 0.70)
                }
            }
            .background(TrypsStyle.paleGreen)
            .ignoresSafeArea(edges: .top)
        }
        .preferredColorScheme(.light)
        .sheet(isPresented: $isChoosingDestination) {
            DestinationPicker(selectedDestination: $destination)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert("Your ride is on its way", isPresented: $isRideRequested) {
            Button("Done", role: .cancel) { }
        } message: {
            Text("\(selectedRide.name) to \(destination.name) · about \(selectedRide.fare) dollars")
        }
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

            Button { } label: {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(TrypsStyle.ink)
                    .padding(5)
                    .background(.white.opacity(0.92), in: Circle())
            }
            .accessibilityLabel("Your profile")
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
                        Button { } label: {
                            Label("Now", systemImage: "clock")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(TrypsStyle.ink)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(Color(red: 0.96, green: 0.97, blue: 0.96), in: Capsule())
                        }
                    }

                    locationCard

                    HStack {
                        Text("RIDE OPTIONS")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1.1)
                            .foregroundStyle(TrypsStyle.muted)
                        Spacer()
                        Text("Upfront pricing")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(TrypsStyle.green)
                    }
                    .padding(.top, 1)

                    VStack(spacing: 8) {
                        ForEach(Ride.options) { ride in
                            RideOptionRow(
                                ride: ride,
                                fare: fare(for: ride),
                                isSelected: ride == selectedRide
                            ) {
                                selectedRide = ride
                            }
                        }
                    }

                    HStack(spacing: 12) {
                        Image(systemName: "creditcard.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(TrypsStyle.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Personal ·••• 2048")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(TrypsStyle.ink)
                            Text("Visa")
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
                    .accessibilityLabel("Payment method, Personal Visa ending in 2048")
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 14)
            }

            Button {
                isRideRequested = true
            } label: {
                HStack {
                    Text("Confirm \(selectedRide.name)")
                        .font(.system(size: 16, weight: .bold))
                    Spacer()
                    Text("$\(fare(for: selectedRide))")
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pickup")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(TrypsStyle.muted)
                        Text("Current location")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(TrypsStyle.ink)
                    }
                    Spacer()
                    Image(systemName: "location.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(TrypsStyle.green)
                }

                Rectangle()
                    .fill(TrypsStyle.line)
                    .frame(height: 1)
                    .padding(.vertical, 9)

                Button {
                    isChoosingDestination = true
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

    private func fare(for ride: Ride) -> Int {
        ride.fare + (destination.id == "sfo" ? 24 : destination.id == "chase" ? 4 : 0)
    }
}

private struct RideOptionRow: View {
    let ride: Ride
    let fare: Int
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
                    Text(ride.detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TrypsStyle.muted)
                }

                Spacer()

                Text("$\(fare)")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(TrypsStyle.ink)

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
        .accessibilityLabel("\(ride.name), \(ride.detail), \(ride.seats) seats, \(fare) dollars")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct DestinationPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedDestination: Destination
    @State private var searchText = ""

    private var results: [Destination] {
        guard !searchText.isEmpty else { return Destination.suggestions }
        return Destination.suggestions.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.subtitle.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List(results) { destination in
                Button {
                    selectedDestination = destination
                    dismiss()
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
            .searchable(text: $searchText, prompt: "Search places")
            .navigationTitle("Choose a destination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .tint(TrypsStyle.green)
                }
            }
        }
    }
}

private struct MapPreview: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.91, green: 0.94, blue: 0.91)))

                    let blocks: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                        (0.04, 0.17, 0.20, 0.14), (0.34, 0.06, 0.22, 0.13), (0.68, 0.14, 0.24, 0.12),
                        (0.11, 0.43, 0.21, 0.11), (0.41, 0.35, 0.21, 0.12), (0.75, 0.42, 0.20, 0.14),
                        (0.06, 0.72, 0.24, 0.13), (0.40, 0.70, 0.19, 0.14), (0.73, 0.74, 0.23, 0.12),
                    ]
                    for (x, y, width, height) in blocks {
                        let rect = CGRect(x: size.width * x, y: size.height * y, width: size.width * width, height: size.height * height)
                        context.fill(Path(roundedRect: rect, cornerRadius: 8), with: .color(Color.white.opacity(0.64)))
                    }

                    for index in 0..<5 {
                        var road = Path()
                        let offset = CGFloat(index) * size.width * 0.22
                        road.move(to: CGPoint(x: offset - size.width * 0.15, y: 0))
                        road.addCurve(
                            to: CGPoint(x: offset + size.width * 0.18, y: size.height),
                            control1: CGPoint(x: offset + size.width * 0.14, y: size.height * 0.34),
                            control2: CGPoint(x: offset - size.width * 0.08, y: size.height * 0.61)
                        )
                        context.stroke(road, with: .color(.white.opacity(0.95)), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        context.stroke(road, with: .color(Color(red: 0.82, green: 0.87, blue: 0.83)), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
                    }

                    for index in 0..<4 {
                        var road = Path()
                        let y = size.height * (0.17 + CGFloat(index) * 0.23)
                        road.move(to: CGPoint(x: 0, y: y))
                        road.addCurve(
                            to: CGPoint(x: size.width, y: y + size.height * 0.12),
                            control1: CGPoint(x: size.width * 0.37, y: y - size.height * 0.09),
                            control2: CGPoint(x: size.width * 0.61, y: y + size.height * 0.17)
                        )
                        context.stroke(road, with: .color(.white.opacity(0.92)), lineWidth: 9)
                    }

                    var route = Path()
                    route.move(to: CGPoint(x: size.width * 0.27, y: size.height * 0.63))
                    route.addCurve(
                        to: CGPoint(x: size.width * 0.65, y: size.height * 0.39),
                        control1: CGPoint(x: size.width * 0.41, y: size.height * 0.59),
                        control2: CGPoint(x: size.width * 0.53, y: size.height * 0.35)
                    )
                    context.stroke(route, with: .color(TrypsStyle.green), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                }

                mapMarker(symbol: "circle.fill", tint: TrypsStyle.green)
                    .position(x: geometry.size.width * 0.27, y: geometry.size.height * 0.63)
                mapMarker(symbol: "mappin.and.ellipse", tint: Color(red: 0.91, green: 0.56, blue: 0.29))
                    .position(x: geometry.size.width * 0.65, y: geometry.size.height * 0.39)

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button { } label: {
                            Image(systemName: "location.north.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(TrypsStyle.ink)
                                .frame(width: 42, height: 42)
                                .background(.white, in: Circle())
                                .shadow(color: .black.opacity(0.10), radius: 9, y: 3)
                        }
                        .accessibilityLabel("Center map on your location")
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 24)
                }
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    private func mapMarker(symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(tint, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
    }
}
#endif
