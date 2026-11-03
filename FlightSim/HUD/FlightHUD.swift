import MapKit
import SwiftUI

/// Everything drawn over the 3D view: status, the selected display, the indicator rails, the flight bar,
/// the flight-deck panel and the pause menu.
struct FlightHUD: View {
    let session: FlightSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let mode = session.displayMode
        ZStack {
            switch mode {
            case .headUp:
                if !session.cameraInCabin { HeadUpDisplay(display: session.display, inCockpit: session.cameraInCockpit) }
            case .map: RouteMap(session: session).padding(.horizontal, 150).padding(.top, 90).padding(.bottom, 130)
            case .glass:
                if !session.cameraInCockpit {
                    VStack {
                        Spacer()
                        GlassDisplays(instruments: session.instruments).padding(.bottom, 130)
                    }
                }
            case .clean: EmptyView()
            }
            if mode != .clean {
                HStack(alignment: .center) {
                    if session.panel == nil { LeftRail(display: session.display) }
                    Spacer()
                    RightRail(display: session.display)
                }
                .padding(.top, 80)
                .padding(.bottom, 120)
                VStack {
                    Spacer()
                    FlightBar(display: session.display)
                }
            }
            VStack(spacing: 10) {
                TopBar(session: session)
                Spacer()
            }
            if session.panel != nil {
                FlightDeckPanel(session: session)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            if session.isPaused {
                PauseMenu(session: session)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 28)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 1), value: session.panel != nil)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 1), value: session.displayMode)
        .animation(.easeInOut(duration: 0.2), value: session.isPaused)
    }
}

// MARK: - Shared styling

/// The overlay's glass: a dark tint so text stays legible over bright sky, cloud or map.
extension View {
    func overlayGlass<S: Shape>(in shape: S) -> some View {
        glassEffect(.regular.tint(.black.opacity(0.38)), in: shape)
    }
}

enum IndicatorState {
    case normal, active, caution, warning

    var color: Color {
        switch self {
        case .normal: .white
        case .active: Color(red: 0.3, green: 1, blue: 0.45)
        case .caution: .orange
        case .warning: .red
        }
    }
}

// MARK: - Top: camera, phase, next waypoint, messages, credit

private struct TopBar: View {
    let session: FlightSession

    var body: some View {
        let display = session.display
        HStack(alignment: .top, spacing: 14) {
            Chip(symbol: "video.fill", text: session.cameraTitle)
            Chip(symbol: "airplane.departure", text: display.phase.rawValue)
            Spacer()
            VStack(spacing: 8) {
                if let nav = display.navigation {
                    // The next waypoint, as a magenta flight-plan tag.
                    Text("\(nav.activeWaypoint)  ·  \(Int(nav.distanceToGoNM.rounded())) nm to \(nav.plan.destination.icao)")
                        .font(.callout.weight(.bold).monospacedDigit())
                        .foregroundStyle(Color(red: 1, green: 0.35, blue: 1))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .overlayGlass(in: .capsule)
                }
                if let message = session.message {
                    Chip(symbol: "info.circle.fill", text: message, tint: .yellow).transition(.opacity)
                }
                if let problem = session.terrain.problem {
                    Chip(symbol: "mountain.2.fill", text: problem, tint: .orange)
                }
                if display.telemetry.stallWarning {
                    Chip(symbol: "exclamationmark.octagon.fill", text: "STALL", tint: .red).font(.title3.bold())
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                if !session.controllerConnected {
                    Chip(symbol: "gamecontroller.fill", text: "Connect a controller to fly", tint: .orange)
                }
                // Map data credit, required by the OpenStreetMap license.
                Text("\(session.airport.attribution) · Terrain: Mapzen Terrain Tiles (AWS)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.8), radius: 3)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session.message)
    }
}

struct Chip: View {
    let symbol: String
    let text: String
    var tint: Color = .white

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .overlayGlass(in: .capsule)
    }
}

// MARK: - Indicator rails

/// One indicator: a small caption over a value, lit when its system is active or in alarm.
private struct Indicator: View {
    let title: String
    let value: String
    var state: IndicatorState = .normal

    var body: some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.65))
            Text(value).font(.callout.weight(.bold).monospacedDigit()).foregroundStyle(state.color).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(width: 150, height: 62)
        .overlayGlass(in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(state.color.opacity(state == .normal ? 0 : 0.8), lineWidth: 2))
    }
}

/// Thrust lever position as a filled gauge.
private struct ThrustGauge: View {
    let throttle: Double
    let reversers: Bool

    var body: some View {
        VStack(spacing: 6) {
            Text("THR").font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.65))
            ZStack(alignment: .bottom) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(reversers ? Color.orange : Color(red: 0.3, green: 1, blue: 0.45))
                    .frame(height: max(8, 150 * throttle))
            }
            .frame(width: 22, height: 150)
            Text(reversers ? "REV" : "\(Int((throttle * 100).rounded()))%").font(.callout.weight(.bold).monospacedDigit())
        }
        .frame(width: 150)
        .padding(.vertical, 12)
        .overlayGlass(in: .rect(cornerRadius: 14))
    }
}

private struct LeftRail: View {
    let display: CockpitDisplay

    var body: some View {
        let ap = display.autopilot
        VStack(spacing: 10) {
            Indicator(title: "TRIM", value: String(format: "%.1f u", 7.5 - display.controls.pitchTrim * 7.5))
            Indicator(title: "A/P", value: ap.autopilotEngaged ? ap.rollMode.rawValue : "OFF", state: ap.autopilotEngaged ? .active : .normal)
            if ap.autopilotEngaged {
                Indicator(title: "PITCH", value: ap.pitchMode.rawValue, state: .active)
            }
            Indicator(title: "A/T", value: ap.autothrottleArmed ? ap.thrustMode.rawValue : "OFF", state: ap.autothrottleArmed ? .active : .normal)
            ThrustGauge(throttle: display.controls.throttle, reversers: display.controls.reversers)
        }
    }
}

private struct RightRail: View {
    let display: CockpitDisplay

    var body: some View {
        let t = display.telemetry
        let gear: (String, IndicatorState) = t.gearPosition > 0.99 ? ("DOWN", .active) : (t.gearPosition < 0.01 ? ("UP", .normal) : ("TRANSIT", .caution))
        let caution = t.stallWarning || (display.controls.parkingBrake && !t.weightOnWheels)
            || (t.speedbrakePosition > 0.05 && !t.weightOnWheels && t.altitudeAGLFeet < 1_000)
        VStack(spacing: 10) {
            Indicator(title: "MASTER", value: caution ? "CAUTION" : "NORMAL", state: caution ? .caution : .normal)
            Indicator(title: "FLAPS", value: display.flapLabel,
                      state: display.flapLabel == display.aircraft.flaps[0].label ? .normal : .active)
            if display.aircraft.retractableGear {
                Indicator(title: "GEAR", value: gear.0, state: gear.1)
            }
            if display.aircraft.hasSpeedbrake {
                Indicator(title: "SPOILERS", value: display.speedbrakeLabel,
                          state: display.speedbrakeLabel == "DOWN" ? .normal : (display.speedbrakeLabel == "ARM" ? .active : .caution))
            }
            if display.aircraft.hasAutobrake {
                Indicator(title: "AUTOBRAKE", value: display.autobrake.label, state: display.autobrakeActive ? .active : .normal)
            }
            Indicator(title: "PARK BRK", value: display.controls.parkingBrake ? "SET" : "OFF", state: display.controls.parkingBrake ? .warning : .normal)
            if display.controls.reversers { Indicator(title: "REVERSE", value: "DEPLOYED", state: .caution) }
        }
    }
}

// MARK: - Flight bar

/// The figures across the bottom: value over caption, full width. Secondary figures give way on narrow screens.
private struct FlightBar: View {
    let display: CockpitDisplay

    private struct Figure: Identifiable {
        let label: String
        let value: String
        var secondary = false
        var id: String { label }
    }

    var body: some View {
        let figures = figures
        ViewThatFits(in: .horizontal) {
            row(figures)
            row(figures.filter { !$0.secondary })
            row(Array(figures.filter { !$0.secondary }.prefix(8)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .overlayGlass(in: .rect(cornerRadius: 22))
    }

    private func row(_ figures: [Figure]) -> some View {
        HStack(spacing: 22) {
            ForEach(figures) { figure in
                VStack(spacing: 2) {
                    Text(figure.value).font(.headline.monospacedDigit()).lineLimit(1)
                    Text(figure.label).font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
                }
                .fixedSize()
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var figures: [Figure] {
        let t = display.telemetry
        var figures = [
            Figure(label: "Wind", value: String(format: "%03d° / %d kt", Int(t.windFromDegrees), Int(t.windSpeedKnots))),
            Figure(label: "IAS", value: "\(Int(t.calibratedAirspeedKnots)) kt"),
            Figure(label: "GS", value: "\(Int(t.groundSpeedKnots)) kt"),
            Figure(label: "Mach", value: String(format: ".%03d", Int(t.mach * 1000)), secondary: true),
            Figure(label: "Altitude MSL", value: "\(Int(t.altitudeMSLFeet).formatted()) ft"),
            Figure(label: "Altitude AGL", value: "\(Int(t.radioAltitudeFeet).formatted()) ft"),
            Figure(label: "V/S", value: String(format: "%+d", Int((t.verticalSpeedFeetPerMinute / 10).rounded()) * 10)),
            Figure(label: "Heading", value: String(format: "%03d°", Int(t.headingDegrees.rounded()) % 360)),
            Figure(label: "OAT", value: String(format: "%+.0f °C", t.outsideAirTemperatureC), secondary: true),
            Figure(label: "Fuel", value: String(format: "%.1f klb", t.fuelPounds / 1_000)),
            Figure(label: "Flight time", value: Self.duration(display.flightTimeSeconds)),
        ]
        if let nav = display.navigation, let seconds = nav.timeToGoSeconds {
            figures.append(Figure(label: "To \(nav.plan.destination.icao)", value: "\(Int(nav.distanceToGoNM)) nm · \(Self.duration(seconds))"))
        }
        figures.append(Figure(label: "UTC", value: InstrumentDrawing.zuluTime(display.simulationDate), secondary: true))
        return figures
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return String(format: "%d:%02d h", minutes / 60, minutes % 60)
    }
}

// MARK: - Instruments, map, head-up display

/// The primary flight display, navigation display and engine display, as on the flight deck.
private struct GlassDisplays: View {
    let instruments: InstrumentRenderer

    var body: some View {
        HStack(alignment: .bottom, spacing: 18) {
            screen(.pfd, size: 320)
            screen(.nd, size: 320)
            screen(.upperEICAS, size: 260)
        }
    }

    @ViewBuilder
    private func screen(_ display: InstrumentDisplay, size: CGFloat) -> some View {
        Group {
            if let image = instruments.images[display] {
                Image(decorative: image, scale: 1).resizable().interpolation(.medium)
            } else {
                Color.black
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 12))
        .padding(6)
        .overlayGlass(in: .rect(cornerRadius: 18))
    }
}

/// The route from departure to destination on a satellite map, with the aircraft on it.
private struct RouteMap: View {
    let session: FlightSession
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        let t = session.display.telemetry
        let aircraft = CLLocationCoordinate2D(latitude: t.latitude, longitude: t.longitude)
        Map(position: $position, interactionModes: []) {
            if let plan = session.plan {
                MapPolyline(coordinates: plan.waypoints.map { CLLocationCoordinate2D(latitude: $0.position.latitude, longitude: $0.position.longitude) })
                    .stroke(Color(red: 1, green: 0.3, blue: 1), lineWidth: 5)
                Marker(plan.destination.icao, systemImage: "airplane.arrival",
                       coordinate: CLLocationCoordinate2D(latitude: plan.destination.lat, longitude: plan.destination.lon))
                    .tint(.red)
            }
            Marker(session.airport.icao, systemImage: "airplane.departure",
                   coordinate: CLLocationCoordinate2D(latitude: session.airport.reference.latitude, longitude: session.airport.reference.longitude))
                .tint(.green)
            Annotation("", coordinate: aircraft) {
                Image(systemName: "airplane")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.yellow)
                    .shadow(radius: 4)
                    .rotationEffect(.degrees(t.headingDegrees - 90))
            }
        }
        .mapStyle(.hybrid(elevation: .realistic))
        .clipShape(.rect(cornerRadius: 28))
        .onChange(of: SIMD2(Int(t.latitude * 60), Int(t.longitude * 60))) {
            // Recenter after each mile or so of travel; following every frame would keep the map redrawing.
            withAnimation(.easeInOut(duration: 1.5)) { position = camera(aircraft, altitude: t.altitudeMSLFeet) }
        }
        .onAppear { position = camera(aircraft, altitude: t.altitudeMSLFeet) }
    }

    private func camera(_ center: CLLocationCoordinate2D, altitude: Double) -> MapCameraPosition {
        .camera(MapCamera(centerCoordinate: center, distance: max(altitude.feetToMeters * 18, 25_000)))
    }
}

/// Head-up display symbology: horizon and pitch ladder, flight path vector, speed and altitude tapes,
/// heading scale, bank pointer, vertical speed and the autopilot modes. On the flight deck it is drawn for
/// the pilot's eye (conformal); outside it is centered on the screen.
private struct HeadUpDisplay: View {
    let display: CockpitDisplay
    let inCockpit: Bool
    static let symbology = Color(red: 0.35, green: 1, blue: 0.45)
    static let magenta = Color(red: 1, green: 0.35, blue: 1)

    var body: some View {
        let t = display.telemetry
        let ap = display.autopilot
        Canvas { context, size in
            // Pixels per degree near the center of the view (62 degree field of view on the flight deck).
            let fieldOfView = inCockpit ? 62.0 : 55.0
            let perDegree = (size.height / 2) / CGFloat(tan(fieldOfView / 2 * .pi / 180)) * .pi / 180
            let center = CGPoint(x: size.width / 2, y: size.height / 2 - (inCockpit ? CGFloat(14.3) * perDegree : 60))
            let color = GraphicsContext.Shading.color(Self.symbology)
            let pitch = t.pitchRadians * 180 / .pi
            let symbologyColor = Self.symbology
            func text(_ string: String, _ point: CGPoint, _ font: Font = .title3.weight(.semibold), _ shade: Color? = nil) {
                context.draw(Text(string).font(font.monospacedDigit()).foregroundStyle(shade ?? symbologyColor), at: point)
            }

            // Pitch ladder, rotating with bank.
            var ladder = context
            ladder.clip(to: Path(CGRect(x: center.x - 270, y: center.y - 240, width: 540, height: 480)))
            ladder.translateBy(x: center.x, y: center.y)
            ladder.rotate(by: .radians(-t.rollRadians))
            for degrees in stride(from: -30, through: 30, by: 5) {
                let y = CGFloat(pitch - Double(degrees)) * perDegree
                var path = Path()
                if degrees == 0 {
                    path.move(to: CGPoint(x: -260, y: y)); path.addLine(to: CGPoint(x: 260, y: y))
                } else {
                    path.move(to: CGPoint(x: -120, y: y)); path.addLine(to: CGPoint(x: -45, y: y))
                    path.move(to: CGPoint(x: 45, y: y)); path.addLine(to: CGPoint(x: 120, y: y))
                    ladder.draw(Text("\(abs(degrees))").font(.caption.bold()).foregroundStyle(Self.symbology), at: CGPoint(x: 142, y: y))
                }
                ladder.stroke(path, with: color, style: StrokeStyle(lineWidth: 2, dash: degrees < 0 ? [12, 9] : []))
            }

            // Bank scale and pointer.
            for degrees in [-30, -20, -10, 0, 10, 20, 30] {
                let angle = CGFloat(degrees) * .pi / 180 - .pi / 2
                var tick = Path()
                tick.move(to: CGPoint(x: center.x + cos(angle) * 250, y: center.y + sin(angle) * 250))
                tick.addLine(to: CGPoint(x: center.x + cos(angle) * (degrees % 30 == 0 ? 270 : 262), y: center.y + sin(angle) * (degrees % 30 == 0 ? 270 : 262)))
                context.stroke(tick, with: color, lineWidth: 2.5)
            }
            let bank = -CGFloat(t.rollRadians) - .pi / 2
            var pointer = Path()
            pointer.move(to: CGPoint(x: center.x + cos(bank) * 246, y: center.y + sin(bank) * 246))
            pointer.addLine(to: CGPoint(x: center.x + cos(bank - 0.04) * 226, y: center.y + sin(bank - 0.04) * 226))
            pointer.addLine(to: CGPoint(x: center.x + cos(bank + 0.04) * 226, y: center.y + sin(bank + 0.04) * 226))
            pointer.closeSubpath()
            context.fill(pointer, with: color)

            // Flight path vector: where the aircraft is going, offset from the nose by angle of attack and drift.
            let drift = t.weightOnWheels ? 0 : Navigation.angleDifference(t.trackDegrees, t.headingDegrees)
            let fpv = CGPoint(x: center.x + CGFloat(drift) * perDegree,
                              y: center.y + CGFloat(t.weightOnWheels ? 0 : t.angleOfAttackDegrees) * perDegree)
            var marker = Path(ellipseIn: CGRect(x: fpv.x - 13, y: fpv.y - 13, width: 26, height: 26))
            marker.move(to: CGPoint(x: fpv.x - 38, y: fpv.y)); marker.addLine(to: CGPoint(x: fpv.x - 13, y: fpv.y))
            marker.move(to: CGPoint(x: fpv.x + 13, y: fpv.y)); marker.addLine(to: CGPoint(x: fpv.x + 38, y: fpv.y))
            marker.move(to: CGPoint(x: fpv.x, y: fpv.y - 13)); marker.addLine(to: CGPoint(x: fpv.x, y: fpv.y - 28))
            context.stroke(marker, with: color, lineWidth: 3)

            // Speed tape (left) and altitude tape (right) with the selected values in magenta.
            tape(context, x: center.x - 360, center: center.y, value: t.calibratedAirspeedKnots, step: 10, labelEvery: 20,
                 pixelsPerUnit: 3.5, selected: ap.mcp.speedKnots, labelSide: -1)
            tape(context, x: center.x + 360, center: center.y, value: t.altitudeMSLFeet, step: 100, labelEvery: 500,
                 pixelsPerUnit: 0.28, selected: ap.mcp.altitudeFeet, labelSide: 1)
            text("\(Int(t.calibratedAirspeedKnots))", CGPoint(x: center.x - 415, y: center.y), .title3.weight(.bold))
            text("\(Int(t.altitudeMSLFeet))", CGPoint(x: center.x + 425, y: center.y), .title3.weight(.bold))
            text("\(Int(ap.mcp.speedKnots))", CGPoint(x: center.x - 375, y: center.y - 172), .caption.weight(.bold), Self.magenta)
            text("\(Int(ap.mcp.altitudeFeet))", CGPoint(x: center.x + 380, y: center.y - 172), .caption.weight(.bold), Self.magenta)
            text(String(format: "M %.2f  G %.1f", t.mach, t.loadFactor), CGPoint(x: center.x - 380, y: center.y + 172), .caption.weight(.semibold))
            text(String(format: "%+d fpm", Int(t.verticalSpeedFeetPerMinute / 10) * 10), CGPoint(x: center.x + 385, y: center.y + 172), .caption.weight(.semibold))
            let height = t.radioAltitudeFeet
            if height < 2_500 { text("RA \(Int(max(height, 0)))", CGPoint(x: center.x + 385, y: center.y + 200), .caption.weight(.bold)) }

            // Heading scale across the top.
            let heading = t.headingDegrees
            for value in stride(from: Int(heading) - 25, through: Int(heading) + 25, by: 1) where value % 5 == 0 {
                let x = center.x + CGFloat(Double(value) - heading) * 9
                let normalized = (value + 360) % 360
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: center.y - 330)); tick.addLine(to: CGPoint(x: x, y: center.y - (normalized % 10 == 0 ? 315 : 322)))
                context.stroke(tick, with: color, lineWidth: 2)
                if normalized % 10 == 0 { text(String(format: "%02d", normalized / 10), CGPoint(x: x, y: center.y - 345), .callout.weight(.semibold)) }
            }
            text(String(format: "%03d", Int(heading.rounded()) % 360), CGPoint(x: center.x, y: center.y - 300), .title3.weight(.bold))

            // Automation modes and ILS deviation.
            let modes = [ap.thrustMode.rawValue, ap.autopilotEngaged ? ap.rollMode.rawValue : "", ap.autopilotEngaged ? ap.pitchMode.rawValue : ""]
                .filter { !$0.isEmpty }.joined(separator: "   ")
            if !modes.isEmpty { text(modes, CGPoint(x: center.x, y: center.y + 250), .title3.weight(.bold)) }
            if let nav = display.navigation, let loc = nav.localizerDeviationDegrees, let gs = nav.glideslopeDeviationDegrees {
                let x = center.x + CGFloat((-loc / LandingSystem.localizerFullScaleDegrees * 2).clamped(-2.2, 2.2)) * 60
                let y = center.y + CGFloat((gs / LandingSystem.glideslopeFullScaleDegrees * 2).clamped(-2.2, 2.2)) * 60
                context.fill(Path(ellipseIn: CGRect(x: x - 8, y: center.y + 205, width: 16, height: 16)), with: .color(Self.magenta))
                context.fill(Path(ellipseIn: CGRect(x: center.x + 300, y: y - 8, width: 16, height: 16)), with: .color(Self.magenta))
            }
        }
        .shadow(color: .black.opacity(0.6), radius: 2)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    /// A vertical tape: ticks every `step`, labels every `labelEvery`, and a magenta bug at `selected`.
    private func tape(_ context: GraphicsContext, x: CGFloat, center: CGFloat, value: Double, step: Int, labelEvery: Int,
                      pixelsPerUnit: CGFloat, selected: Double, labelSide: CGFloat) {
        let halfHeight: CGFloat = 150
        let range = Double(halfHeight / pixelsPerUnit)
        var spine = Path()
        spine.move(to: CGPoint(x: x, y: center - halfHeight)); spine.addLine(to: CGPoint(x: x, y: center + halfHeight))
        context.stroke(spine, with: .color(Self.symbology), lineWidth: 2)
        let first = Int((value - range) / Double(step)) * step
        for mark in stride(from: first, through: Int(value + range), by: step) {
            let y = center - CGFloat(Double(mark) - value) * pixelsPerUnit
            guard abs(y - center) <= halfHeight else { continue }
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: y)); tick.addLine(to: CGPoint(x: x - labelSide * 14, y: y))
            context.stroke(tick, with: .color(Self.symbology), lineWidth: 2)
            if mark % labelEvery == 0 {
                context.draw(Text("\(mark)").font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(Self.symbology),
                             at: CGPoint(x: x - labelSide * 42, y: y))
            }
        }
        let bugY = center - CGFloat(selected - value) * pixelsPerUnit
        if abs(bugY - center) <= halfHeight {
            context.fill(Path(CGRect(x: x - 5, y: bugY - 8, width: 10, height: 16)), with: .color(Self.magenta))
        }
    }
}
