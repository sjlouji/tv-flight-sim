import MapKit
import SwiftUI

/// The start page: choose where the flight starts, where it goes, the weather and the time, then fly.
struct LandingView: View {
    let airport: Airport
    let database: NavDatabase
    let onStart: (FlightSetup) -> Void

    enum StartKind: String, CaseIterable, Identifiable {
        case runway = "On the runway"
        case approach = "Final approach"
        case airborne = "In flight"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .runway: "road.lanes"
            case .approach: "airplane.arrival"
            case .airborne: "cloud.sun.fill"
            }
        }
    }

    // Choices are remembered between launches (and launch arguments such as `-timeOfDay sunset` set them,
    // which the UI tests use).
    @AppStorage("aircraft") private var aircraftType: AircraftType = .b737
    @AppStorage("startKind") private var startKind: StartKind = .runway
    @AppStorage("runway") private var runway: String = ""
    @AppStorage("approachDistance") private var approachDistance = 6.0
    @AppStorage("altitude") private var altitude = 10_000.0
    @AppStorage("offsetDistance") private var offsetDistance = 25.0
    @AppStorage("offsetBearing") private var offsetBearing = 270.0
    @AppStorage("destination") private var destinationICAO = ""
    @AppStorage("weather") private var weatherPreset: WeatherPreset = .fewClouds
    @AppStorage("windFrom") private var windFrom = 280.0
    @AppStorage("windSpeed") private var windSpeed = 10.0
    @AppStorage("timeOfDay") private var timeOfDay: TimeOfDay = .now
    @State private var query = ""
    @FocusState private var startFocused: Bool

    private var destination: NavAirport? { destinationICAO.isEmpty ? nil : database.airport(icao: destinationICAO) }
    private var aircraft: AircraftProfile { .profile(aircraftType) }
    /// The chosen altitude, or the highest this aircraft can start at if it is above that.
    private var startAltitude: Double { min(altitude, aircraft.startAltitudes.last ?? altitude) }
    private var weather: WeatherSettings {
        WeatherSettings(preset: weatherPreset, windFromDegrees: windFrom, windSpeedKnots: windSpeed)
    }

    static let popularDestinations = ["KSFO", "KLAX", "KSEA", "KLAS", "KDEN", "KJFK", "PHNL", "CYVR", "EGLL", "RJTT"]
    static let approachDistances: [Double] = [3, 6, 10, 15]
    static let offsets: [Double] = [10, 25, 50]
    static let bearings: [(String, Double)] = [("North", 0), ("East", 90), ("South", 180), ("West", 270)]

    /// The categories down the left of the start page.
    enum Page: String, CaseIterable, Identifiable {
        case route = "Route"
        case aircraft = "Aircraft"
        case start = "Takeoff / landing"
        case weather = "Weather"
        case time = "Date / time"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .route: "map.fill"
            case .aircraft: "airplane"
            case .start: "airplane.departure"
            case .weather: "cloud.sun.fill"
            case .time: "clock.fill"
            }
        }
    }

    /// The section last open, remembered like the other choices.
    @AppStorage("startPage") private var page: Page = .route
    @FocusState private var focusedPage: Page?

    var body: some View {
        ZStack {
            SkyBackdrop(timeOfDay: timeOfDay, weather: weather.preset)
            VStack(spacing: 24) {
                HStack(alignment: .top, spacing: 28) {
                    sidebar
                    pageContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                bottomBar
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 44)
        }
        .onAppear {
            if !runwayNames.contains(runway) { runway = suggestedRunway }
            startFocused = true
        }
        .onChange(of: focusedPage) { if let focusedPage { page = focusedPage } }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Flight Sim").font(.system(size: 52, weight: .bold)).tracking(-1)
                Text("\(aircraft.name) · \(airport.icao)").font(.callout).foregroundStyle(.secondary)
            }
            .padding(.bottom, 18)
            ForEach(Page.allCases) { item in
                Button { page = item } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(item.rawValue, systemImage: item.symbol).font(.headline)
                        Text(summary(for: item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(width: 340, alignment: .leading)
                }
                .focused($focusedPage, equals: item)
                .tint(item == page ? .accentColor : nil)
            }
            Spacer()
        }
        .frame(width: 400)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .route: routeSection
        case .aircraft: AircraftPage(selection: $aircraftType, airport: airport)
        case .start: ScrollView { startSection.padding(30) }.overlayGlass(in: .rect(cornerRadius: 32))
        case .weather: ScrollView { weatherSection.padding(30) }.overlayGlass(in: .rect(cornerRadius: 32))
        case .time: ScrollView { timeSection.padding(30) }.overlayGlass(in: .rect(cornerRadius: 32))
        }
    }

    /// Route, start conditions and the Start button along the bottom.
    private var bottomBar: some View {
        HStack(spacing: 24) {
            Label(routeSummary, systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill")
                .font(.headline)
            Text(setup.scenario.title).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button {
                onStart(setup)
            } label: {
                Label("Start flight", systemImage: "play.fill")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 24)
            }
            .buttonStyle(.borderedProminent)
            .focused($startFocused)
            .accessibilityIdentifier("Start flight")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .overlayGlass(in: .rect(cornerRadius: 26))
    }

    private func summary(for page: Page) -> String {
        switch page {
        case .route: destination.map { "\(airport.icao) → \($0.icao)" } ?? "Local flight from \(airport.icao)"
        case .aircraft: aircraft.name
        case .start: setup.scenario.title
        case .weather: "\(weather.preset.title), \(Int(weather.windSpeedKnots)) kt"
        case .time: "\(timeOfDay.title), \(localTime(timeOfDay))"
        }
    }

    private var routeSummary: String {
        guard let destination else { return "\(airport.icao) local flight" }
        return "\(airport.icao) → \(destination.icao) · \(Int(routeDistanceNM)) nm · EFT \(Self.flightTime(routeDistanceNM, aircraft: aircraft))"
    }

    private var routeDistanceNM: Double {
        guard let destination else { return 0 }
        let home = GeoPoint(latitude: airport.reference.latitude, longitude: airport.reference.longitude)
        return Navigation.distanceMeters(home, destination.position) / Navigation.metersPerNauticalMile
    }

    /// Estimated flight time: the aircraft's cruise true airspeed over the ground, plus 15 minutes to climb and descend.
    static func flightTime(_ distanceNM: Double, aircraft: AircraftProfile) -> String {
        let minutes = Int(distanceNM / aircraft.cruiseTrueAirspeed * 60) + 15
        return String(format: "%d:%02d h", minutes / 60, minutes % 60)
    }

    // MARK: - Sections

    private var startSection: some View {
        Section(title: "Start", subtitle: setup.scenario.title) {
            Picker("Start", selection: $startKind) {
                ForEach(StartKind.allCases) { kind in Label(kind.rawValue, systemImage: kind.symbol).tag(kind) }
            }
            .pickerStyle(.segmented)
            switch startKind {
            case .runway, .approach:
                OptionRow(title: "Runway") {
                    ForEach(runwayNames, id: \.self) { name in
                        Choice(name, detail: name == suggestedRunway ? "Into wind" : nil, selected: runway == name) { runway = name }
                    }
                }
                if startKind == .approach {
                    OptionRow(title: "Distance") {
                        ForEach(Self.approachDistances, id: \.self) { distance in
                            Choice("\(Int(distance)) nm", selected: approachDistance == distance) { approachDistance = distance }
                        }
                    }
                }
            case .airborne:
                OptionRow(title: "Altitude") {
                    ForEach(aircraft.startAltitudes, id: \.self) { value in
                        Choice(Scenario.altitudeText(value), selected: startAltitude == value) { altitude = value }
                    }
                }
                OptionRow(title: "Position") {
                    ForEach(Self.offsets, id: \.self) { value in
                        Choice("\(Int(value)) nm", selected: offsetDistance == value) { offsetDistance = value }
                    }
                    ForEach(Self.bearings, id: \.1) { name, value in
                        Choice(name, selected: offsetBearing == value) { offsetBearing = value }
                    }
                }
            }
        }
    }

    private var routeSection: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Destination").font(.title2.weight(.bold))
                Text(destinationSummary).font(.callout).foregroundStyle(.secondary)
                TextField("Search by code, name or city", text: $query)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Choice("None", detail: "Local flight", selected: destination == nil) { destinationICAO = "" }
                        ForEach(destinationChoices) { airport in
                            Choice(airport.icao, detail: "\(airport.city), \(airport.country)", selected: destinationICAO == airport.icao) {
                                destinationICAO = airport.icao
                            }
                        }
                    }
                    .padding(8)
                }
            }
            .padding(26)
            .frame(width: 420)
            .overlayGlass(in: .rect(cornerRadius: 32))
            RoutePlanner(airport: airport, destination: destination, distanceNM: routeDistanceNM, aircraft: aircraft)
        }
    }

    private var weatherSection: some View {
        Section(title: "Weather", subtitle: "\(weather.preset.title), wind \(Int(weather.windFromDegrees))° at \(Int(weather.windSpeedKnots)) kt") {
            OptionRow(title: "Sky") {
                ForEach(WeatherPreset.allCases) { preset in
                    Choice(preset.title, symbol: preset.symbol, selected: weatherPreset == preset) { weatherPreset = preset }
                }
            }
            OptionRow(title: "Wind") {
                ForEach(WeatherSettings.windSpeeds, id: \.self) { speed in
                    Choice(speed == 0 ? "Calm" : "\(Int(speed)) kt", selected: windSpeed == speed) {
                        windSpeed = speed
                        runway = suggestedRunway
                    }
                }
                ForEach([0.0, 90, 180, 270, 300], id: \.self) { direction in
                    Choice(String(format: "From %03d°", Int(direction)), selected: windFrom == direction) {
                        windFrom = direction
                        runway = suggestedRunway
                    }
                }
            }
        }
    }

    private var timeSection: some View {
        Section(title: "Time", subtitle: "Sun, moon and stars follow the real sky over \(airport.icao)") {
            OptionRow(title: nil) {
                ForEach(TimeOfDay.allCases) { time in
                    Choice(time.title, symbol: time.symbol, detail: localTime(time), selected: timeOfDay == time) { timeOfDay = time }
                }
            }
        }
    }

    // MARK: - Derived values

    var setup: FlightSetup {
        let scenario: Scenario = switch startKind {
        case .runway: .takeoff(runway: runway)
        case .approach: .approach(runway: runway, distanceNM: approachDistance)
        case .airborne: .airborne(altitudeFeet: startAltitude, bearingDegrees: offsetBearing, distanceNM: offsetDistance,
                                  headingDegrees: airborneHeading)
        }
        return FlightSetup(aircraft: aircraftType, scenario: scenario, destinationICAO: destination?.icao, weather: weather, timeOfDay: timeOfDay)
    }

    /// In flight, head for the destination if there is one, otherwise back toward the airport.
    private var airborneHeading: Double {
        let home = GeoPoint(latitude: airport.reference.latitude, longitude: airport.reference.longitude)
        let start = Navigation.destination(from: home, bearingDegrees: offsetBearing, distanceMeters: offsetDistance * Navigation.metersPerNauticalMile)
        let target = destination?.position ?? home
        return Navigation.bearingDegrees(start, target).rounded()
    }

    private var runwayNames: [String] { airport.runwayEnds().map(\.designator).sorted() }

    /// The runway end most into the wind; in calm air, the longest.
    private var suggestedRunway: String {
        func score(_ end: RunwayEnd) -> Double {
            let headwind = cos((end.trueHeadingDegrees - weather.windFromDegrees) * .pi / 180) * weather.windSpeedKnots
            return headwind * 1_000 + Double(end.length) / 1_000
        }
        return airport.runwayEnds().max { score($0) < score($1) }?.designator ?? ""
    }

    private var destinationChoices: [NavAirport] {
        if query.isEmpty { return Self.popularDestinations.compactMap(database.airport(icao:)) }
        return database.search(query, limit: 12)
    }

    private var destinationSummary: String {
        guard let destination else { return "None, a local flight" }
        let home = GeoPoint(latitude: airport.reference.latitude, longitude: airport.reference.longitude)
        let nm = Navigation.distanceMeters(home, destination.position) / Navigation.metersPerNauticalMile
        return "\(destination.name), \(Int(nm)) nm"
    }

    private func localTime(_ time: TimeOfDay) -> String {
        let date = time.date(today: Date(), latitude: airport.reference.latitude, longitude: airport.reference.longitude)
        // Local solar time at the airport: what the sun is doing there.
        let solar = date.addingTimeInterval(airport.reference.longitude / 15 * 3_600)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let parts = calendar.dateComponents([.hour, .minute], from: solar)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

// MARK: - Building blocks

private struct Section<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.bold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            content
        }
    }
}

private struct OptionRow<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase) }
            ScrollView(.horizontal) {
                HStack(spacing: 18) { content }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 6)
            }
            .scrollClipDisabled()
        }
    }
}

/// One option: shows a checkmark and the accent tint when selected.
private struct Choice: View {
    let title: String
    var symbol: String?
    var detail: String?
    let selected: Bool
    let action: () -> Void

    init(_ title: String, symbol: String? = nil, detail: String? = nil, selected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.detail = detail
        self.selected = selected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.title2).symbolRenderingMode(.multicolor) }
                HStack(spacing: 8) {
                    if selected { Image(systemName: "checkmark.circle.fill") }
                    Text(title).font(.headline)
                }
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
            .frame(minWidth: 130)
            .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .tint(selected ? .accentColor : nil)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The fleet as a grid of cards, each with the aircraft's top view drawn from its own proportions, and
/// the selected aircraft's figures beside it.
private struct AircraftPage: View {
    @Binding var selection: AircraftType
    let airport: Airport

    private let columns = Array(repeating: GridItem(.fixed(212), spacing: 16), count: 3)

    var body: some View {
        let profile = AircraftProfile.profile(selection)
        HStack(alignment: .top, spacing: 24) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(AircraftProfile.all) { aircraft in
                        Button { selection = aircraft.type } label: {
                            VStack(spacing: 10) {
                                AircraftSilhouette(aircraft: aircraft)
                                    .fill(.primary.opacity(0.85))
                                    .frame(width: 120, height: 90)
                                    .padding(.top, 6)
                                HStack(spacing: 6) {
                                    if aircraft.type == selection { Image(systemName: "checkmark.circle.fill") }
                                    Text(aircraft.name).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
                                        .minimumScaleFactor(0.8)
                                }
                            }
                            .frame(width: 176, height: 158)
                        }
                        .buttonStyle(.bordered)
                        .tint(aircraft.type == selection ? .accentColor : nil)
                        .accessibilityIdentifier(aircraft.type.rawValue)
                        .accessibilityAddTraits(aircraft.type == selection ? .isSelected : [])
                    }
                }
                .padding(20)
            }
            .scrollClipDisabled()
            .frame(width: 708)
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name).font(.title2.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
                    Text(profile.summary).font(.callout).foregroundStyle(.secondary)
                    Text(profile.engineDescription).font(.caption).foregroundStyle(.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
                    GridRow { spec("Wingspan", meters(profile.wingspanMeters)); spec("Carries", profile.capacity) }
                    GridRow { spec("Length", meters(profile.lengthMeters)); spec("Max takeoff weight", "\(profile.maxTakeoffWeightKg.formatted()) kg") }
                    GridRow { spec("Height", meters(profile.heightMeters)); spec("Range", "\(profile.rangeKm.formatted()) km") }
                    GridRow { spec("Cruise", profile.cruiseDescription); spec("Ceiling", "\(Int(profile.ceiling).formatted()) ft") }
                    GridRow {
                        spec("Takeoff", "Flaps \(profile.flaps[profile.takeoffFlapDetent].label) · VR \(Int(profile.vr))")
                        spec("Approach", "Flaps \(profile.flaps[profile.landingFlapDetent].label) · \(Int(profile.approachSpeed)) kt")
                    }
                    GridRow {
                        spec("Systems", systems(profile))
                        spec("Departs", "\(airport.icao), \(airport.runways.count) runways")
                    }
                }
                Spacer()
            }
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlayGlass(in: .rect(cornerRadius: 32))
        }
    }

    private func meters(_ value: Float) -> String { String(format: "%.1f m", value) }

    private func systems(_ profile: AircraftProfile) -> String {
        var parts: [String] = [profile.retractableGear ? "Retractable gear" : "Fixed gear"]
        if profile.hasReversers { parts.append("reversers") }
        if profile.carrierCapable { parts.append("catapult and hook") }
        return parts.joined(separator: ", ")
    }

    private func spec(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// An aircraft seen from above, nose up, drawn from its real length, span and wing layout, so a Cessna, a
/// 747 and a Phantom look different at a glance. Each aircraft fills the frame at its own scale.
struct AircraftSilhouette: Shape {
    let aircraft: AircraftProfile

    func path(in rect: CGRect) -> Path {
        let length = CGFloat(aircraft.lengthMeters), span = CGFloat(aircraft.wingspanMeters)
        let scale = min(rect.height / length, rect.width / span) * 0.95
        let width = CGFloat(aircraft.fuselageRadius) * 2 * scale
        let top = rect.midY - length * scale / 2
        let cx = rect.midX
        let (sweep, wingAt, rootChord, tipChord, tailSpan): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = switch aircraft.airframe {
        case .jetAirliner: (0.5, 0.36, 0.2, 0.05, 0.38)
        case .businessJet: (0.6, 0.4, 0.2, 0.06, 0.34)
        case .highWingTurboprop: (0.04, 0.33, 0.13, 0.07, 0.36)
        case .lightSingle: (0, 0.3, 0.2, 0.15, 0.31)
        case .fighter: (0.9, 0.45, 0.42, 0.1, 0.47)
        }
        var path = Path()
        // Fuselage: a rounded body tapering to the tail.
        path.addRoundedRect(in: CGRect(x: cx - width / 2, y: top, width: width, height: length * scale * 0.86),
                            cornerSize: CGSize(width: width / 2, height: width * 1.2))
        path.move(to: CGPoint(x: cx - width / 2, y: top + length * scale * 0.8))
        path.addLine(to: CGPoint(x: cx - width * 0.12, y: top + length * scale))
        path.addLine(to: CGPoint(x: cx + width * 0.12, y: top + length * scale))
        path.addLine(to: CGPoint(x: cx + width / 2, y: top + length * scale * 0.8))
        // Wings and stabilizer: trapezoids swept back.
        func surface(rootY: CGFloat, halfSpan: CGFloat, root: CGFloat, tip: CGFloat) {
            for side: CGFloat in [-1, 1] {
                path.move(to: CGPoint(x: cx, y: rootY))
                path.addLine(to: CGPoint(x: cx + side * halfSpan, y: rootY + halfSpan * sweep))
                path.addLine(to: CGPoint(x: cx + side * halfSpan, y: rootY + halfSpan * sweep + tip))
                path.addLine(to: CGPoint(x: cx, y: rootY + root))
                path.closeSubpath()
            }
        }
        let halfSpan = span * scale / 2
        surface(rootY: top + length * scale * wingAt, halfSpan: halfSpan, root: length * scale * rootChord, tip: length * scale * tipChord)
        let tailRoot = top + length * scale * (aircraft.airframe == .fighter ? 0.8 : 0.84)
        surface(rootY: tailRoot, halfSpan: halfSpan * tailSpan, root: length * scale * 0.12, tip: length * scale * 0.05)
        return path
    }
}

/// The route on a map: departure and destination tags, the great-circle path, and the flight time card.
private struct RoutePlanner: View {
    let airport: Airport
    let destination: NavAirport?
    let distanceNM: Double
    let aircraft: AircraftProfile

    var body: some View {
        let home = CLLocationCoordinate2D(latitude: airport.reference.latitude, longitude: airport.reference.longitude)
        let away = destination.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        ZStack(alignment: .bottomTrailing) {
            Map(position: .constant(camera(home, away)), interactionModes: []) {
                Marker(airport.icao, systemImage: "airplane.departure", coordinate: home).tint(.green)
                if let destination, let away {
                    Marker(destination.icao, systemImage: "airplane.arrival", coordinate: away).tint(.red)
                    MapPolyline(coordinates: [home, away], contourStyle: .geodesic)
                        .stroke(Color(red: 1, green: 0.3, blue: 1), lineWidth: 5)
                }
            }
            .mapStyle(.hybrid(elevation: .flat))
            .clipShape(.rect(cornerRadius: 32))
            if let destination {
                VStack(alignment: .leading, spacing: 10) {
                    Text("EFT \(LandingView.flightTime(distanceNM, aircraft: aircraft))  ·  \(Int(distanceNM)) nm").font(.headline.monospacedDigit())
                    Text(aircraft.name).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        tag(airport.icao, airport.name, .green)
                        Image(systemName: "arrow.right")
                        tag(destination.icao, destination.city, .red)
                    }
                }
                .padding(20)
                .overlayGlass(in: .rect(cornerRadius: 22))
                .padding(24)
            }
        }
    }

    private func tag(_ code: String, _ name: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(code).font(.title3.weight(.bold))
            Text(name).font(.caption2).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(width: 210, alignment: .leading)
        .background(color.opacity(0.8), in: .rect(cornerRadius: 10))
    }

    /// Frames both airports with a margin, or the departure area for a local flight.
    private func camera(_ home: CLLocationCoordinate2D, _ away: CLLocationCoordinate2D?) -> MapCameraPosition {
        guard let away else { return .camera(MapCamera(centerCoordinate: home, distance: 120_000)) }
        let center = CLLocationCoordinate2D(latitude: (home.latitude + away.latitude) / 2, longitude: (home.longitude + away.longitude) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(abs(home.latitude - away.latitude) * 1.6, 1),
                                    longitudeDelta: max(abs(home.longitude - away.longitude) * 1.6, 1))
        return .region(MKCoordinateRegion(center: center, span: span))
    }
}

/// A sky gradient for the chosen time and weather, behind the glass.
private struct SkyBackdrop: View {
    let timeOfDay: TimeOfDay
    let weather: WeatherPreset

    var body: some View {
        LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
            .overlay(Color.gray.opacity(weather.daylightTransmission < 0.6 ? 0.35 : 0))
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.6), value: timeOfDay)
            .animation(.easeInOut(duration: 0.6), value: weather)
    }

    private var colors: [Color] {
        switch timeOfDay {
        case .dawn: [Color(red: 0.16, green: 0.2, blue: 0.42), Color(red: 0.93, green: 0.55, blue: 0.42)]
        case .sunset: [Color(red: 0.2, green: 0.22, blue: 0.48), Color(red: 0.98, green: 0.5, blue: 0.25)]
        case .night: [Color(red: 0.01, green: 0.02, blue: 0.08), Color(red: 0.06, green: 0.08, blue: 0.2)]
        case .now, .morning, .noon, .afternoon: [Color(red: 0.1, green: 0.32, blue: 0.7), Color(red: 0.55, green: 0.75, blue: 0.95)]
        }
    }
}
