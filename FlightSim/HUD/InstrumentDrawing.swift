import CoreGraphics
import CoreText
import Foundation
import Observation
import UIKit

/// Draws Boeing-style glass displays with Core Graphics. The same images go on the flight deck's
/// display units and in the 2D glass-cockpit overlay, so each instrument is drawn by one piece of code.
/// Drawing happens off the main thread.
enum InstrumentDrawing {
    // Boeing display colors.
    static let white = UIColor.white.cgColor
    static let green = UIColor(red: 0.2, green: 1, blue: 0.3, alpha: 1).cgColor
    static let magenta = UIColor(red: 1, green: 0.3, blue: 1, alpha: 1).cgColor
    static let cyan = UIColor(red: 0.2, green: 0.9, blue: 1, alpha: 1).cgColor
    static let amber = UIColor(red: 1, green: 0.75, blue: 0.1, alpha: 1).cgColor
    static let red = UIColor(red: 1, green: 0.2, blue: 0.15, alpha: 1).cgColor
    static let gray = UIColor(white: 0.35, alpha: 1).cgColor
    static let sky = UIColor(red: 0.18, green: 0.47, blue: 0.85, alpha: 1).cgColor
    static let ground = UIColor(red: 0.55, green: 0.33, blue: 0.16, alpha: 1).cgColor

    @concurrent
    static func render(_ display: InstrumentDisplay, _ state: CockpitDisplay) async throws -> CGImage {
        let size = display.pixelSize
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: size.width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw SkyError.imageCreation
        }
        // Top-left origin, y down, like a screen.
        context.translateBy(x: 0, y: CGFloat(size.height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        let canvas = Canvas(context: context, width: CGFloat(size.width), height: CGFloat(size.height))
        switch display {
        case .pfd: drawPFD(canvas, state)
        case .nd: drawND(canvas, state)
        case .upperEICAS: drawUpperEICAS(canvas, state)
        case .lowerEICAS: drawLowerEICAS(canvas, state)
        case .mcp: drawMCP(canvas, state)
        }
        guard let image = context.makeImage() else { throw SkyError.imageCreation }
        return image
    }

    /// A Core Graphics context with a top-left origin, plus text and shape helpers.
    struct Canvas {
        let context: CGContext
        let width: CGFloat
        let height: CGFloat

        enum Align { case left, center, right }

        func text(_ string: String, _ point: CGPoint, size: CGFloat, color: CGColor, align: Align = .left, bold: Bool = false) {
            let font = CTFontCreateWithName((bold ? "HelveticaNeue-Bold" : "HelveticaNeue-Medium") as CFString, size, nil)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            let x: CGFloat = switch align {
            case .left: point.x
            case .center: point.x - bounds.width / 2
            case .right: point.x - bounds.width
            }
            context.saveGState()
            // The context is flipped; flip the text back so it reads upright. `point.y` is the text's vertical center.
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = CGPoint(x: x, y: point.y + size * 0.35)
            CTLineDraw(line, context)
            context.restoreGState()
        }

        func line(_ points: [CGPoint], color: CGColor, width: CGFloat = 2) {
            guard let first = points.first else { return }
            context.setStrokeColor(color)
            context.setLineWidth(width)
            context.move(to: first)
            points.dropFirst().forEach { context.addLine(to: $0) }
            context.strokePath()
        }

        func box(_ rect: CGRect, color: CGColor, width: CGFloat = 2, fill: CGColor? = nil) {
            if let fill {
                context.setFillColor(fill)
                context.fill(rect)
            }
            context.setStrokeColor(color)
            context.setLineWidth(width)
            context.stroke(rect)
        }
    }

    // MARK: - Primary flight display

    static func drawPFD(_ c: Canvas, _ s: CockpitDisplay) {
        let t = s.telemetry
        let center = CGPoint(x: 250, y: 255)
        let pixelsPerDegree: CGFloat = 7
        // Attitude: sky and ground rotate with roll and move with pitch.
        let attitudeRect = CGRect(x: 120, y: 95, width: 260, height: 300)
        c.context.saveGState()
        c.context.clip(to: attitudeRect)
        c.context.translateBy(x: center.x, y: center.y)
        c.context.rotate(by: -CGFloat(t.rollRadians))
        c.context.translateBy(x: 0, y: CGFloat(t.pitchRadians * 180 / .pi) * pixelsPerDegree)
        c.context.setFillColor(sky)
        c.context.fill(CGRect(x: -600, y: -1200, width: 1200, height: 1200))
        c.context.setFillColor(ground)
        c.context.fill(CGRect(x: -600, y: 0, width: 1200, height: 1200))
        let local = Canvas(context: c.context, width: c.width, height: c.height)
        local.line([CGPoint(x: -600, y: 0), CGPoint(x: 600, y: 0)], color: white, width: 2)
        for degrees in stride(from: -30, through: 30, by: 5) where degrees != 0 {
            let y = -CGFloat(degrees) * pixelsPerDegree
            let half: CGFloat = degrees % 10 == 0 ? 40 : 18
            local.line([CGPoint(x: -half, y: y), CGPoint(x: half, y: y)], color: white, width: 2)
            if degrees % 10 == 0 {
                local.text("\(abs(degrees))", CGPoint(x: -half - 24, y: y), size: 15, color: white)
                local.text("\(abs(degrees))", CGPoint(x: half + 8, y: y), size: 15, color: white)
            }
        }
        c.context.restoreGState()
        // Roll scale and pointer.
        c.context.saveGState()
        c.context.translateBy(x: center.x, y: center.y)
        for degrees in [-60, -45, -30, -20, -10, 0, 10, 20, 30, 45, 60] {
            let angle = CGFloat(degrees) * .pi / 180
            let inner: CGFloat = degrees % 30 == 0 ? 128 : 135
            c.context.saveGState()
            c.context.rotate(by: angle)
            Canvas(context: c.context, width: 0, height: 0).line([CGPoint(x: 0, y: -inner), CGPoint(x: 0, y: -145)], color: white, width: 2)
            c.context.restoreGState()
        }
        c.context.rotate(by: -CGFloat(t.rollRadians))
        c.context.setFillColor(white)
        c.context.move(to: CGPoint(x: 0, y: -126))
        c.context.addLine(to: CGPoint(x: -9, y: -112))
        c.context.addLine(to: CGPoint(x: 9, y: -112))
        c.context.fillPath()
        c.context.restoreGState()
        // Fixed aircraft symbol.
        c.box(CGRect(x: center.x - 85, y: center.y - 4, width: 55, height: 9), color: white, width: 2, fill: UIColor.black.cgColor)
        c.box(CGRect(x: center.x + 30, y: center.y - 4, width: 55, height: 9), color: white, width: 2, fill: UIColor.black.cgColor)
        c.box(CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10), color: white, width: 2, fill: UIColor.black.cgColor)

        drawSpeedTape(c, s)
        drawAltitudeTape(c, s)
        drawHeadingScale(c, s, center: CGPoint(x: center.x, y: 470))
        drawModes(c, s)

        // Radio altitude near the ground.
        let height = t.radioAltitudeFeet
        if height < 2_500 {
            c.text("\(Int(max(height, 0)))", CGPoint(x: center.x, y: 380), size: 22, color: white, align: .center, bold: true)
        }
        // ILS deviation on final: localizer below the attitude, glideslope on its right.
        if let nav = s.navigation, let loc = nav.localizerDeviationDegrees, let gs = nav.glideslopeDeviationDegrees {
            let dot: CGFloat = 26
            for i in [-2, -1, 1, 2] {
                c.box(CGRect(x: center.x + CGFloat(i) * dot - 4, y: 400, width: 8, height: 8), color: white, width: 1.5)
                c.box(CGRect(x: 392, y: center.y + CGFloat(i) * dot - 4, width: 8, height: 8), color: white, width: 1.5)
            }
            let locX = center.x + CGFloat((-loc / LandingSystem.localizerFullScaleDegrees * 2).clamped(-2.3, 2.3)) * dot
            let gsY = center.y + CGFloat((gs / LandingSystem.glideslopeFullScaleDegrees * 2).clamped(-2.3, 2.3)) * dot
            diamond(c, CGPoint(x: locX, y: 404), color: magenta)
            diamond(c, CGPoint(x: 396, y: gsY), color: magenta)
        }
        if t.stallWarning {
            c.text("STALL", CGPoint(x: center.x, y: 140), size: 28, color: red, align: .center, bold: true)
        }
    }

    private static func diamond(_ c: Canvas, _ p: CGPoint, color: CGColor) {
        c.context.setFillColor(color)
        c.context.move(to: CGPoint(x: p.x, y: p.y - 9))
        c.context.addLine(to: CGPoint(x: p.x + 7, y: p.y))
        c.context.addLine(to: CGPoint(x: p.x, y: p.y + 9))
        c.context.addLine(to: CGPoint(x: p.x - 7, y: p.y))
        c.context.fillPath()
    }

    private static func drawSpeedTape(_ c: Canvas, _ s: CockpitDisplay) {
        let speed = s.telemetry.calibratedAirspeedKnots
        let rect = CGRect(x: 18, y: 95, width: 84, height: 320)
        let mid = rect.midY
        let pixelsPerKnot: CGFloat = 4
        c.box(rect, color: gray, width: 1, fill: UIColor(white: 0.25, alpha: 1).cgColor)
        c.context.saveGState()
        c.context.clip(to: rect)
        let lowest = Int((speed - 45) / 10) * 10
        for value in stride(from: max(lowest, 0), through: Int(speed + 45), by: 10) {
            let y = mid - CGFloat(Double(value) - speed) * pixelsPerKnot
            c.line([CGPoint(x: rect.maxX - 14, y: y), CGPoint(x: rect.maxX, y: y)], color: white)
            if value % 20 == 0 { c.text("\(value)", CGPoint(x: rect.maxX - 18, y: y), size: 17, color: white, align: .right) }
        }
        // Bugs: selected speed (magenta), takeoff speeds (green) while on the ground.
        let bugY = mid - CGFloat(s.autopilot.mcp.speedKnots - speed) * pixelsPerKnot
        c.box(CGRect(x: rect.maxX - 8, y: bugY - 9, width: 10, height: 18), color: magenta, width: 3)
        if s.telemetry.weightOnWheels {
            for (label, value) in [("1", s.aircraft.v1), ("R", s.aircraft.vr)] {
                let y = mid - CGFloat(value - speed) * pixelsPerKnot
                c.text(label, CGPoint(x: rect.maxX + 2, y: y), size: 14, color: green)
            }
        }
        if speed > s.aircraft.maxSpeed - 45 {
            let y = mid - CGFloat(s.aircraft.maxSpeed - speed) * pixelsPerKnot
            c.box(CGRect(x: rect.maxX - 6, y: rect.minY, width: 6, height: max(y - rect.minY, 0)), color: red, width: 0, fill: red)
        }
        c.context.restoreGState()
        c.box(CGRect(x: rect.minX - 2, y: mid - 17, width: rect.width - 6, height: 34), color: white, width: 2, fill: UIColor.black.cgColor)
        c.text("\(Int(speed.rounded()))", CGPoint(x: rect.maxX - 14, y: mid), size: 24, color: white, align: .right, bold: true)
        c.text("\(Int(s.autopilot.mcp.speedKnots))", CGPoint(x: rect.midX, y: 80), size: 18, color: magenta, align: .center)
        c.text(String(format: "M.%03d", Int(s.telemetry.mach * 1000)), CGPoint(x: rect.midX, y: 432), size: 16, color: white, align: .center)
    }

    private static func drawAltitudeTape(_ c: Canvas, _ s: CockpitDisplay) {
        let altitude = s.telemetry.altitudeMSLFeet
        let rect = CGRect(x: 398, y: 95, width: 84, height: 320)
        let mid = rect.midY
        let pixelsPerFoot: CGFloat = 0.4
        c.box(rect, color: gray, width: 1, fill: UIColor(white: 0.25, alpha: 1).cgColor)
        c.context.saveGState()
        c.context.clip(to: rect)
        let lowest = Int((altitude - 420) / 100) * 100
        for value in stride(from: lowest, through: Int(altitude + 420), by: 100) {
            let y = mid - CGFloat(Double(value) - altitude) * pixelsPerFoot
            c.line([CGPoint(x: rect.minX, y: y), CGPoint(x: rect.minX + 12, y: y)], color: white)
            if value % 200 == 0 { c.text("\(value)", CGPoint(x: rect.minX + 16, y: y), size: 15, color: white) }
        }
        let bugY = mid - CGFloat(s.autopilot.mcp.altitudeFeet - altitude) * pixelsPerFoot
        c.box(CGRect(x: rect.minX - 2, y: bugY - 10, width: 10, height: 20), color: magenta, width: 3)
        c.context.restoreGState()
        c.box(CGRect(x: rect.minX + 4, y: mid - 17, width: rect.width - 2, height: 34), color: white, width: 2, fill: UIColor.black.cgColor)
        c.text("\(Int(altitude.rounded()))", CGPoint(x: rect.maxX - 2, y: mid), size: 21, color: white, align: .right, bold: true)
        c.text("\(Int(s.autopilot.mcp.altitudeFeet))", CGPoint(x: rect.midX, y: 80), size: 18, color: magenta, align: .center)
        // Vertical speed: needle on a non-linear scale, readout above or below.
        let vs = s.telemetry.verticalSpeedFeetPerMinute
        let scale = CGRect(x: 488, y: 135, width: 20, height: 240)
        c.box(scale, color: gray, width: 1, fill: UIColor(white: 0.2, alpha: 1).cgColor)
        let deflection = CGFloat(copysign(min(sqrt(abs(vs) / 6_000), 1), vs)) * scale.height / 2
        c.line([CGPoint(x: scale.maxX + 4, y: scale.midY), CGPoint(x: scale.minX, y: scale.midY - deflection)], color: white, width: 3)
        if abs(vs) > 400 {
            c.text("\(Int((vs / 50).rounded()) * 50)", CGPoint(x: 506, y: vs > 0 ? 122 : 390), size: 14, color: white, align: .right)
        }
    }

    private static func drawHeadingScale(_ c: Canvas, _ s: CockpitDisplay, center: CGPoint) {
        let heading = s.telemetry.headingDegrees
        let pixelsPerDegree: CGFloat = 5
        let rect = CGRect(x: center.x - 130, y: center.y - 22, width: 260, height: 44)
        c.box(rect, color: gray, width: 1, fill: UIColor(white: 0.2, alpha: 1).cgColor)
        c.context.saveGState()
        c.context.clip(to: rect)
        for value in stride(from: Int(heading) - 30, through: Int(heading) + 30, by: 1) where value % 5 == 0 {
            let x = center.x + CGFloat(Double(value) - heading) * pixelsPerDegree
            let normalized = (value + 360) % 360
            c.line([CGPoint(x: x, y: rect.minY), CGPoint(x: x, y: rect.minY + (normalized % 10 == 0 ? 12 : 7))], color: white)
            if normalized % 10 == 0 {
                c.text(String(format: "%02d", normalized / 10), CGPoint(x: x, y: rect.minY + 24), size: 15, color: white, align: .center)
            }
        }
        let bug = Navigation.angleDifference(s.autopilot.mcp.headingDegrees, heading)
        let bugX = center.x + CGFloat(bug.clamped(-26, 26)) * pixelsPerDegree
        c.box(CGRect(x: bugX - 7, y: rect.minY, width: 14, height: 7), color: magenta, width: 3)
        let track = Navigation.angleDifference(s.telemetry.trackDegrees, heading)
        let trackX = center.x + CGFloat(track.clamped(-26, 26)) * pixelsPerDegree
        c.line([CGPoint(x: trackX, y: rect.minY), CGPoint(x: trackX, y: rect.maxY)], color: green, width: 2)
        c.context.restoreGState()
        c.box(CGRect(x: center.x - 26, y: rect.minY - 30, width: 52, height: 28), color: white, width: 2, fill: UIColor.black.cgColor)
        c.text(String(format: "%03d", Int(heading.rounded()) % 360), CGPoint(x: center.x, y: rect.minY - 16), size: 19, color: white, align: .center, bold: true)
    }

    /// Flight mode annunciations across the top: thrust, roll and pitch modes, armed modes, autopilot status.
    private static func drawModes(_ c: Canvas, _ s: CockpitDisplay) {
        let ap = s.autopilot
        let columns: [CGFloat] = [85, 250, 415]
        for x in columns.dropLast() { c.line([CGPoint(x: x + 82, y: 8), CGPoint(x: x + 82, y: 52)], color: gray, width: 1) }
        c.text(ap.thrustMode.rawValue, CGPoint(x: columns[0], y: 22), size: 19, color: green, align: .center, bold: true)
        if ap.autopilotEngaged {
            c.text(ap.rollMode.rawValue, CGPoint(x: columns[1], y: 22), size: 19, color: green, align: .center, bold: true)
            c.text(ap.pitchMode.rawValue, CGPoint(x: columns[2], y: 22), size: 19, color: green, align: .center, bold: true)
            if ap.localizerArmed { c.text("VOR/LOC", CGPoint(x: columns[1], y: 44), size: 15, color: white, align: .center) }
            if ap.glideslopeArmed { c.text("G/S", CGPoint(x: columns[2], y: 44), size: 15, color: white, align: .center) }
            c.text("CMD", CGPoint(x: 250, y: 78), size: 20, color: green, align: .center, bold: true)
        }
    }

    // MARK: - Navigation display (MAP mode, heading up)

    static let rangesNM: [Double] = [5, 10, 20, 40, 80, 160, 320, 640]

    static func drawND(_ c: Canvas, _ s: CockpitDisplay) {
        let t = s.telemetry
        let heading = t.headingDegrees
        let aircraft = CGPoint(x: 256, y: 420)
        let radius: CGFloat = 340
        let position = GeoPoint(latitude: t.latitude, longitude: t.longitude)
        let rangeNM = rangesNM.first { $0 >= (s.navigation?.distanceToGoNM ?? 40) * 0.6 } ?? 640
        func screen(_ point: GeoPoint) -> CGPoint {
            let distance = Navigation.distanceMeters(position, point) / Navigation.metersPerNauticalMile
            let bearing = (Navigation.bearingDegrees(position, point) - heading) * .pi / 180
            let r = CGFloat(distance / rangeNM) * radius
            return CGPoint(x: aircraft.x + r * CGFloat(sin(bearing)), y: aircraft.y - r * CGFloat(cos(bearing)))
        }
        // Compass arc with ticks every 5 degrees, labels every 30.
        c.context.saveGState()
        c.context.addArc(center: aircraft, radius: radius, startAngle: -.pi / 2 - 0.85, endAngle: -.pi / 2 + 0.85, clockwise: false)
        c.context.setStrokeColor(white)
        c.context.setLineWidth(2)
        c.context.strokePath()
        c.context.restoreGState()
        for value in stride(from: 0, to: 360, by: 5) {
            let relative = Navigation.angleDifference(Double(value), heading)
            guard abs(relative) < 48 else { continue }
            let angle = CGFloat(relative * .pi / 180)
            let length: CGFloat = value % 10 == 0 ? 14 : 8
            let outer = CGPoint(x: aircraft.x + radius * sin(angle), y: aircraft.y - radius * cos(angle))
            let inner = CGPoint(x: aircraft.x + (radius - length) * sin(angle), y: aircraft.y - (radius - length) * cos(angle))
            c.line([inner, outer], color: white)
            if value % 30 == 0 {
                let label = CGPoint(x: aircraft.x + (radius - 30) * sin(angle), y: aircraft.y - (radius - 30) * cos(angle))
                c.text("\(value / 10)", label, size: 16, color: white, align: .center)
            }
        }
        // Half-range ring.
        c.context.saveGState()
        c.context.setLineDash(phase: 0, lengths: [6, 8])
        c.context.addArc(center: aircraft, radius: radius / 2, startAngle: -.pi / 2 - 0.85, endAngle: -.pi / 2 + 0.85, clockwise: false)
        c.context.setStrokeColor(white)
        c.context.setLineWidth(1)
        c.context.strokePath()
        c.context.restoreGState()
        c.text(String(format: "%g", rangeNM / 2), CGPoint(x: aircraft.x - radius / 2 * 0.72 - 18, y: aircraft.y - radius / 2 * 0.7), size: 14, color: white)
        // Heading bug and track line.
        let bug = CGFloat(Navigation.angleDifference(s.autopilot.mcp.headingDegrees, heading).clamped(-48, 48) * .pi / 180)
        c.line([CGPoint(x: aircraft.x + (radius + 2) * sin(bug), y: aircraft.y - (radius + 2) * cos(bug)),
                CGPoint(x: aircraft.x + (radius + 14) * sin(bug), y: aircraft.y - (radius + 14) * cos(bug))], color: magenta, width: 6)
        let track = CGFloat(Navigation.angleDifference(t.trackDegrees, heading) * .pi / 180)
        c.line([aircraft, CGPoint(x: aircraft.x + radius * sin(track), y: aircraft.y - radius * cos(track))], color: white, width: 1)

        // Route, waypoints, top of descent.
        c.context.saveGState()
        c.context.clip(to: CGRect(x: 0, y: 60, width: c.width, height: c.height - 60))
        if let nav = s.navigation {
            let points = nav.plan.waypoints.map { screen($0.position) }
            c.line(points, color: magenta, width: 3)
            for (waypoint, point) in zip(nav.plan.waypoints, points) {
                c.box(CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10), color: waypoint.name == nav.activeWaypoint ? magenta : white, width: 2)
                c.text(waypoint.name, CGPoint(x: point.x + 10, y: point.y), size: 14, color: waypoint.name == nav.activeWaypoint ? magenta : white)
            }
            let airport = screen(nav.plan.destination.position)
            c.context.setStrokeColor(cyan)
            c.context.setLineWidth(2)
            c.context.strokeEllipse(in: CGRect(x: airport.x - 9, y: airport.y - 9, width: 18, height: 18))
            c.text(nav.plan.destination.icao, CGPoint(x: airport.x + 12, y: airport.y + 14), size: 14, color: cyan)
            if let topOfDescent = nav.topOfDescentNM, topOfDescent < rangeNM {
                let angle = CGFloat(Navigation.angleDifference(nav.desiredTrackDegrees, heading) * .pi / 180)
                let r = CGFloat(topOfDescent / rangeNM) * radius
                let p = CGPoint(x: aircraft.x + r * sin(angle), y: aircraft.y - r * cos(angle))
                c.context.setStrokeColor(green)
                c.context.strokeEllipse(in: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12))
                c.text("T/D", CGPoint(x: p.x + 10, y: p.y), size: 14, color: green)
            }
        }
        c.context.restoreGState()
        // Aircraft symbol.
        c.context.setStrokeColor(white)
        c.context.setLineWidth(3)
        c.context.move(to: CGPoint(x: aircraft.x, y: aircraft.y - 18))
        c.context.addLine(to: CGPoint(x: aircraft.x - 12, y: aircraft.y + 12))
        c.context.addLine(to: CGPoint(x: aircraft.x + 12, y: aircraft.y + 12))
        c.context.closePath()
        c.context.strokePath()

        // Corner data: speeds and wind top left, next waypoint top right.
        c.text("GS", CGPoint(x: 10, y: 18), size: 14, color: white)
        c.text("\(Int(t.groundSpeedKnots))", CGPoint(x: 36, y: 18), size: 20, color: white, bold: true)
        c.text("TAS", CGPoint(x: 92, y: 18), size: 14, color: white)
        c.text("\(Int(t.trueAirspeedKnots))", CGPoint(x: 126, y: 18), size: 20, color: white, bold: true)
        c.text(String(format: "%03d° / %d", Int(t.windFromDegrees), Int(t.windSpeedKnots)), CGPoint(x: 10, y: 44), size: 16, color: white)
        if t.windSpeedKnots >= 1 {
            let wind = CGFloat((t.windFromDegrees + 180 - heading) * .pi / 180)
            let base = CGPoint(x: 30, y: 84)
            c.line([CGPoint(x: base.x - 16 * sin(wind), y: base.y + 16 * cos(wind)), CGPoint(x: base.x + 16 * sin(wind), y: base.y - 16 * cos(wind))],
                   color: white, width: 2)
        }
        if let nav = s.navigation {
            c.text(nav.activeWaypoint, CGPoint(x: 500, y: 18), size: 18, color: magenta, align: .right, bold: true)
            if let seconds = nav.timeToGoSeconds {
                let eta = s.simulationDate.addingTimeInterval(seconds)
                c.text(Self.zuluTime(eta), CGPoint(x: 500, y: 42), size: 16, color: white, align: .right)
            }
            c.text(String(format: "%.0f NM", nav.distanceToGoNM), CGPoint(x: 500, y: 64), size: 16, color: white, align: .right)
        } else {
            c.text("NO ROUTE", CGPoint(x: 500, y: 18), size: 16, color: amber, align: .right)
        }
        c.text(String(format: "%g", rangeNM), CGPoint(x: 256, y: 498), size: 14, color: white, align: .center)
    }

    static func zuluTime(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d%02dZ", parts.hour ?? 0, parts.minute ?? 0)
    }

    // MARK: - Engine displays

    static func drawUpperEICAS(_ c: Canvas, _ s: CockpitDisplay) {
        let t = s.telemetry
        // One dial per engine across the top: N1 for turbines, RPM for a piston engine.
        let kind = s.aircraft.engineKind
        let count = t.engineSpool.count
        let spacing = c.width / CGFloat(max(count, 1))
        let radius: CGFloat = count > 2 ? 48 : 78
        let textSize: CGFloat = count > 2 ? 15 : 18
        for engine in 0..<count {
            let center = CGPoint(x: spacing * (CGFloat(engine) + 0.5), y: 130)
            let reading = kind == .piston ? String(format: "%.0f", t.engineRPM[engine]) : String(format: "%.1f", t.engineSpool[engine] * 100)
            dial(c, center: center, radius: radius, value: t.engineSpool[engine] / 1.1, label: reading,
                 color: s.controls.reversers ? amber : white, commanded: s.controls.throttle)
            let secondary = switch kind {
            case .turbofan: "N2 \(String(format: "%.1f", t.engineN2[engine]))"
            case .turbojet: "RPM %"
            case .turboprop: t.engineRPM[engine] > 0 ? "PROP \(String(format: "%.0f", t.engineRPM[engine]))"
                : "N2 \(String(format: "%.1f", t.engineN2[engine]))"
            case .piston: "RPM"
            }
            c.text(secondary, CGPoint(x: center.x, y: 248), size: textSize, color: white, align: .center)
            // Fuel flow: thousands of pounds per hour on turbines, pounds per hour on the piston engine.
            let flow = t.fuelFlowPoundsPerHour[engine]
            let fuelFlow = kind == .piston ? String(format: "FF %.0f", flow) : String(format: "FF %.2f", flow / 1_000)
            c.text(fuelFlow, CGPoint(x: center.x, y: 276), size: textSize, color: white, align: .center)
            if s.controls.reversers {
                c.text("REV", CGPoint(x: center.x, y: 60), size: textSize, color: green, align: .center, bold: true)
            }
        }
        if count == 2 { c.text(kind == .turbojet ? "RPM" : "N1", CGPoint(x: 256, y: 130), size: 18, color: cyan, align: .center) }
        // Flaps gauge.
        let flapRect = CGRect(x: 60, y: 320, width: 26, height: 150)
        c.box(flapRect, color: white, width: 2)
        let flapFill = CGFloat(t.flapPosition) * flapRect.height
        c.box(CGRect(x: flapRect.minX + 3, y: flapRect.minY + 3, width: flapRect.width - 6, height: max(flapFill - 6, 0)),
              color: green, width: 0, fill: green)
        c.text("FLAPS", CGPoint(x: 100, y: 330), size: 16, color: cyan)
        c.text(s.flapLabel, CGPoint(x: 100, y: 360), size: 26, color: green, bold: true)
        // Gear (fixed-gear aircraft show it always down).
        let gear: (String, CGColor) = t.gearPosition > 0.99 ? ("DOWN", green) : (t.gearPosition < 0.01 ? ("UP", white) : ("TRANSIT", amber))
        c.text("GEAR", CGPoint(x: 260, y: 330), size: 16, color: cyan)
        for index in 0..<3 {
            let rect = CGRect(x: 240 + CGFloat(index) * 66, y: 350, width: 58, height: 34)
            c.box(rect, color: gear.1, width: 2, fill: gear.0 == "DOWN" ? UIColor(red: 0, green: 0.25, blue: 0.05, alpha: 1).cgColor : nil)
            c.text(gear.0 == "DOWN" ? "DN" : gear.0, CGPoint(x: rect.midX, y: rect.midY), size: 15, color: gear.1, align: .center, bold: true)
        }
        // Alerts.
        var alerts: [(String, CGColor)] = []
        if t.stallWarning { alerts.append(("STALL", red)) }
        if s.controls.parkingBrake { alerts.append(("PARKING BRAKE", amber)) }
        if t.speedbrakePosition > 0.05 && !t.weightOnWheels { alerts.append(("SPEEDBRAKE EXTENDED", amber)) }
        if s.speedbrakeLabel == "ARM" { alerts.append(("SPEEDBRAKE ARMED", green)) }
        if s.autobrakeActive { alerts.append(("AUTOBRAKE", green)) }
        for (index, alert) in alerts.prefix(3).enumerated() {
            c.text(alert.0, CGPoint(x: 240, y: 420 + CGFloat(index) * 26), size: 17, color: alert.1, bold: true)
        }
    }

    /// A Boeing round dial: arc from 0 to 0.9 of a turn, needle, digital box, and the commanded thrust tick.
    private static func dial(_ c: Canvas, center: CGPoint, radius: CGFloat, value: Double, label: String, color: CGColor, commanded: Double) {
        let start: CGFloat = .pi * 0.75
        let sweep: CGFloat = .pi * 1.5
        c.context.saveGState()
        c.context.addArc(center: center, radius: radius, startAngle: start, endAngle: start + sweep, clockwise: false)
        c.context.setStrokeColor(white)
        c.context.setLineWidth(3)
        c.context.strokePath()
        let fraction = CGFloat(value.clamped(0, 1))
        c.context.move(to: center)
        c.context.addArc(center: center, radius: radius - 3, startAngle: start, endAngle: start + sweep * fraction, clockwise: false)
        c.context.closePath()
        c.context.setFillColor(UIColor(white: 0.3, alpha: 1).cgColor)
        c.context.fillPath()
        c.context.restoreGState()
        let angle = start + sweep * fraction
        c.line([center, CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)], color: color, width: 4)
        let target = start + sweep * CGFloat((commanded * 1.04).clamped(0, 1))
        c.line([CGPoint(x: center.x + cos(target) * (radius + 2), y: center.y + sin(target) * (radius + 2)),
                CGPoint(x: center.x + cos(target) * (radius + 14), y: center.y + sin(target) * (radius + 14))], color: magenta, width: 4)
        c.box(CGRect(x: center.x - 10, y: center.y - 52, width: 90, height: 32), color: white, width: 2, fill: UIColor.black.cgColor)
        c.text(label, CGPoint(x: center.x + 76, y: center.y - 36), size: 22, color: color, align: .right, bold: true)
    }

    static func drawLowerEICAS(_ c: Canvas, _ s: CockpitDisplay) {
        let t = s.telemetry
        func row(_ index: Int, _ label: String, _ value: String, _ color: CGColor = white) {
            let y = 40 + CGFloat(index) * 44
            c.text(label, CGPoint(x: 30, y: y), size: 20, color: cyan)
            c.text(value, CGPoint(x: 482, y: y), size: 24, color: color, align: .right, bold: true)
        }
        row(0, "FUEL", String(format: "%.1f klb", t.fuelPounds / 1_000), t.fuelPounds < 3_000 ? amber : white)
        row(1, "GROSS WT", String(format: "%.1f klb", t.grossWeightPounds / 1_000))
        row(2, "OAT", String(format: "%+.0f °C", t.outsideAirTemperatureC))
        // Positive pitch trim is nose down in JSBSim's convention; Boeing shows units, nose up larger.
        row(3, "STAB TRIM", String(format: "%.1f u", 7.5 - s.controls.pitchTrim * 7.5))
        row(4, "RUDDER TRIM", String(format: "%@ %.1f", s.controls.rudderTrim >= 0 ? "R" : "L", abs(s.controls.rudderTrim) * 10))
        row(5, "AUTOBRAKE", s.aircraft.hasAutobrake ? s.autobrake.label : "—", s.autobrakeActive ? green : white)
        row(6, "SPEEDBRAKE", s.aircraft.hasSpeedbrake ? s.speedbrakeLabel : "—",
            s.speedbrakeLabel == "DOWN" ? white : (s.speedbrakeLabel == "ARM" ? green : amber))
        row(7, "PHASE", s.phase.rawValue.uppercased(), green)
        row(8, "TIME", zuluTime(s.simulationDate))
        row(9, "G LOAD", String(format: "%.2f", t.loadFactor))
    }

    // MARK: - Mode control panel

    static func drawMCP(_ c: Canvas, _ s: CockpitDisplay) {
        c.box(CGRect(x: 0, y: 0, width: c.width, height: c.height), color: gray, width: 2, fill: UIColor(white: 0.22, alpha: 1).cgColor)
        let ap = s.autopilot
        func window(_ x: CGFloat, _ label: String, _ value: String) {
            c.text(label, CGPoint(x: x + 60, y: 14), size: 14, color: white, align: .center)
            c.box(CGRect(x: x, y: 26, width: 120, height: 44), color: gray, width: 2, fill: UIColor.black.cgColor)
            c.text(value, CGPoint(x: x + 112, y: 48), size: 28, color: amber, align: .right, bold: true)
        }
        func button(_ x: CGFloat, _ label: String, lit: Bool) {
            c.box(CGRect(x: x, y: 30, width: 70, height: 38), color: white, width: 1.5, fill: UIColor(white: 0.12, alpha: 1).cgColor)
            c.text(label, CGPoint(x: x + 35, y: 56), size: 13, color: white, align: .center)
            if lit { c.box(CGRect(x: x + 10, y: 34, width: 50, height: 6), color: green, width: 0, fill: green) }
        }
        button(10, "A/T", lit: ap.autothrottleArmed)
        window(90, "IAS/MACH", "\(Int(ap.mcp.speedKnots))")
        button(220, "LVL CHG", lit: ap.autopilotEngaged && ap.pitchMode == .levelChange)
        window(300, "HEADING", String(format: "%03d", Int(ap.mcp.headingDegrees) % 360))
        button(430, "LNAV", lit: ap.autopilotEngaged && ap.rollMode == .lnav)
        button(505, "APP", lit: ap.localizerArmed || ap.rollMode == .localizer)
        window(585, "ALTITUDE", "\(Int(ap.mcp.altitudeFeet))")
        window(715, "VERT SPEED", ap.pitchMode == .verticalSpeed && ap.autopilotEngaged ? String(format: "%+d", Int(ap.mcp.verticalSpeedFPM)) : "")
        button(845, "ALT HLD", lit: ap.autopilotEngaged && ap.pitchMode == .altitudeHold)
        button(925, "CMD A", lit: ap.autopilotEngaged)
    }
}

/// Renders the visible displays round-robin, off the main thread, and publishes the newest images.
@MainActor
@Observable
final class InstrumentRenderer {
    private(set) var images: [InstrumentDisplay: CGImage] = [:]
    @ObservationIgnored private var rendering = false
    @ObservationIgnored private var nextIndex = 0
    @ObservationIgnored private var lastRender: [InstrumentDisplay: Double] = [:]
    @ObservationIgnored private var clock = 0.0

    /// Each visible display is redrawn about this often (real display units refresh at a similar rate).
    static let refreshInterval = 1.0 / 15

    /// Call every frame with the displays someone can see; draws at most one at a time.
    func update(state: CockpitDisplay, visible: [InstrumentDisplay], deltaTime dt: Double,
                deliver: @escaping @MainActor (InstrumentDisplay, CGImage) -> Void) {
        clock += dt
        guard !rendering, !visible.isEmpty else { return }
        for offset in 0..<visible.count {
            let display = visible[(nextIndex + offset) % visible.count]
            guard clock - (lastRender[display] ?? -1) >= Self.refreshInterval else { continue }
            nextIndex = (nextIndex + offset + 1) % visible.count
            lastRender[display] = clock
            rendering = true
            Task {
                defer { self.rendering = false }
                do {
                    let image = try await InstrumentDrawing.render(display, state)
                    self.images[display] = image
                    deliver(display, image)
                } catch {
                    Log.app.error("Instrument \(String(describing: display), privacy: .public) failed to draw: \(error.localizedDescription, privacy: .public)")
                }
            }
            return
        }
    }
}
