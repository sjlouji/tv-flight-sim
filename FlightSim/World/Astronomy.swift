import Foundation
import simd

/// Where the sun, moon and stars are for a place and time, so the sky matches the real latitude,
/// longitude and clock. Solar position follows the NOAA algorithm (about 0.01 degree); the moon uses
/// Meeus's low-precision series (about 0.5 degree), plenty for drawing.
enum Astronomy {
    /// A direction in the sky.
    struct SkyPosition: Equatable, Sendable {
        /// Degrees clockwise from true north.
        var azimuthDegrees: Double
        /// Degrees above the horizon.
        var elevationDegrees: Double

        /// Unit vector in scene axes (+x east, +y up, -z north).
        var sceneDirection: SIMD3<Float> {
            let az = azimuthDegrees * .pi / 180
            let el = elevationDegrees * .pi / 180
            return SIMD3(Float(sin(az) * cos(el)), Float(sin(el)), Float(-cos(az) * cos(el)))
        }
    }

    static func julianDay(_ date: Date) -> Double { date.timeIntervalSince1970 / 86_400 + 2_440_587.5 }

    /// Days since J2000.0 (2000-01-01 12:00 UTC).
    private static func daysSinceJ2000(_ date: Date) -> Double { julianDay(date) - 2_451_545.0 }

    static func sun(at date: Date, latitude: Double, longitude: Double) -> SkyPosition {
        let (rightAscension, declination) = sunEquatorial(date)
        return horizontal(rightAscensionDegrees: rightAscension, declinationDegrees: declination,
                          date: date, latitude: latitude, longitude: longitude)
    }

    /// Sun right ascension and declination in degrees.
    static func sunEquatorial(_ date: Date) -> (Double, Double) {
        let t = daysSinceJ2000(date) / 36_525
        let meanLongitude = normalize(280.46646 + t * (36_000.76983 + t * 0.0003032))
        let meanAnomaly = radians(357.52911 + t * (35_999.05029 - 0.0001537 * t))
        let center = sin(meanAnomaly) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(2 * meanAnomaly) * (0.019993 - 0.000101 * t) + sin(3 * meanAnomaly) * 0.000289
        let omega = radians(125.04 - 1_934.136 * t)
        let apparentLongitude = radians(meanLongitude + center - 0.00569 - 0.00478 * sin(omega))
        let obliquity = radians(23.439291 - 0.0130042 * t + 0.00256 * cos(omega))
        let rightAscension = atan2(cos(obliquity) * sin(apparentLongitude), cos(apparentLongitude))
        let declination = asin(sin(obliquity) * sin(apparentLongitude))
        return (normalize(degrees(rightAscension)), degrees(declination))
    }

    static func moon(at date: Date, latitude: Double, longitude: Double) -> SkyPosition {
        let (rightAscension, declination) = moonEquatorial(date)
        return horizontal(rightAscensionDegrees: rightAscension, declinationDegrees: declination,
                          date: date, latitude: latitude, longitude: longitude)
    }

    /// Moon right ascension and declination in degrees (geocentric).
    static func moonEquatorial(_ date: Date) -> (Double, Double) {
        let d = daysSinceJ2000(date)
        let meanLongitude = radians(218.316 + 13.176396 * d)
        let meanAnomaly = radians(134.963 + 13.064993 * d)
        let distanceArgument = radians(93.272 + 13.229350 * d)
        let eclipticLongitude = meanLongitude + radians(6.289) * sin(meanAnomaly)
        let eclipticLatitude = radians(5.128) * sin(distanceArgument)
        let obliquity = radians(23.4397)
        let rightAscension = atan2(sin(eclipticLongitude) * cos(obliquity) - tan(eclipticLatitude) * sin(obliquity),
                                   cos(eclipticLongitude))
        let declination = asin(sin(eclipticLatitude) * cos(obliquity)
                               + cos(eclipticLatitude) * sin(obliquity) * sin(eclipticLongitude))
        return (normalize(degrees(rightAscension)), degrees(declination))
    }

    /// Fraction of the moon's disc that is lit, 0 new ... 1 full.
    static func moonIllumination(at date: Date) -> Double {
        let (sunRA, sunDec) = sunEquatorial(date)
        let (moonRA, moonDec) = moonEquatorial(date)
        let elongation = acos(sin(radians(sunDec)) * sin(radians(moonDec))
                              + cos(radians(sunDec)) * cos(radians(moonDec)) * cos(radians(sunRA - moonRA)))
        return (1 - cos(elongation)) / 2
    }

    /// Greenwich mean sidereal time in degrees.
    static func greenwichSiderealDegrees(_ date: Date) -> Double {
        let d = daysSinceJ2000(date)
        return normalize(280.46061837 + 360.98564736629 * d)
    }

    static func horizontal(rightAscensionDegrees: Double, declinationDegrees: Double, date: Date,
                           latitude: Double, longitude: Double) -> SkyPosition {
        let hourAngle = radians(greenwichSiderealDegrees(date) + longitude - rightAscensionDegrees)
        let phi = radians(latitude)
        let delta = radians(declinationDegrees)
        let elevation = asin(sin(phi) * sin(delta) + cos(phi) * cos(delta) * cos(hourAngle))
        let azimuth = atan2(-sin(hourAngle) * cos(delta), cos(phi) * sin(delta) - sin(phi) * cos(delta) * cos(hourAngle))
        return SkyPosition(azimuthDegrees: normalize(degrees(azimuth)), elevationDegrees: degrees(elevation))
    }

    /// Rotation from the celestial frame (x toward the vernal equinox, y toward RA 6h, z toward the north
    /// celestial pole) into scene axes at a place and time. Stars built in the celestial frame use it.
    static func celestialToScene(date: Date, latitude: Double, longitude: Double) -> simd_quatf {
        let localSidereal = radians(greenwichSiderealDegrees(date) + longitude)
        let phi = radians(latitude)
        // Columns: where the celestial x, y and z axes point in east-north-up, then in scene axes.
        func enu(_ ra: Double, _ dec: Double) -> SIMD3<Double> {
            let hourAngle = localSidereal - ra
            let east = -cos(dec) * sin(hourAngle)
            let north = cos(phi) * sin(dec) - sin(phi) * cos(dec) * cos(hourAngle)
            let up = sin(phi) * sin(dec) + cos(phi) * cos(dec) * cos(hourAngle)
            return SIMD3(east, up, -north)
        }
        let x = enu(0, 0), y = enu(.pi / 2, 0), z = enu(0, .pi / 2)
        return simd_quatf(simd_float3x3(columns: (SIMD3<Float>(x), SIMD3<Float>(y), SIMD3<Float>(z))))
    }

    /// Sunrise and sunset (sun center 0.833 degree below the horizon) around `date`, searched over the
    /// 24 hours starting at local solar midnight. Nil in polar day or night.
    static func sunriseSunset(near date: Date, latitude: Double, longitude: Double) -> (rise: Date, set: Date)? {
        let midnight = localSolarMidnight(near: date, longitude: longitude)
        func elevation(_ seconds: Double) -> Double {
            sun(at: midnight.addingTimeInterval(seconds), latitude: latitude, longitude: longitude).elevationDegrees + 0.833
        }
        var rise: Double?
        var set: Double?
        let step = 600.0
        var t = 0.0
        while t < 86_400 {
            let a = elevation(t), b = elevation(t + step)
            if a < 0 && b >= 0 && rise == nil { rise = bisect(t, t + step, elevation) }
            if a >= 0 && b < 0 && set == nil { set = bisect(t, t + step, elevation) }
            t += step
        }
        guard let rise, let set else { return nil }
        return (midnight.addingTimeInterval(rise), midnight.addingTimeInterval(set))
    }

    /// Solar noon is when the sun crosses the meridian, about 12:00 minus longitude / 15 hours UTC.
    static func localSolarMidnight(near date: Date, longitude: Double) -> Date {
        let offset = longitude / 15 * 3_600
        let local = date.timeIntervalSince1970 + offset
        let midnight = (local / 86_400).rounded(.down) * 86_400
        return Date(timeIntervalSince1970: midnight - offset)
    }

    private static func bisect(_ a: Double, _ b: Double, _ f: (Double) -> Double) -> Double {
        var (lo, hi) = (a, b)
        let rising = f(lo) < 0
        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            if (f(mid) < 0) == rising { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
    static func normalize(_ degrees: Double) -> Double {
        let d = degrees.truncatingRemainder(dividingBy: 360)
        return d < 0 ? d + 360 : d
    }
}

/// Times of day offered on the start page, worked out from the real sun at the airport.
enum TimeOfDay: String, CaseIterable, Identifiable, Sendable {
    case now, dawn, morning, noon, afternoon, sunset, night

    var id: String { rawValue }

    var title: String {
        switch self {
        case .now: "Now"
        case .dawn: "Dawn"
        case .morning: "Morning"
        case .noon: "Midday"
        case .afternoon: "Afternoon"
        case .sunset: "Sunset"
        case .night: "Night"
        }
    }

    var symbol: String {
        switch self {
        case .now: "clock.fill"
        case .dawn: "sunrise.fill"
        case .morning: "sun.haze.fill"
        case .noon: "sun.max.fill"
        case .afternoon: "sun.min.fill"
        case .sunset: "sunset.fill"
        case .night: "moon.stars.fill"
        }
    }

    /// The moment this choice means today at a place. "Now" is the real clock, so the sky matches
    /// what someone standing at the airport sees.
    func date(today now: Date, latitude: Double, longitude: Double) -> Date {
        if self == .now { return now }
        let midnight = Astronomy.localSolarMidnight(near: now, longitude: longitude)
        let solarNoon = midnight.addingTimeInterval(12 * 3_600)
        guard let times = Astronomy.sunriseSunset(near: now, latitude: latitude, longitude: longitude) else {
            // Polar day or night: the sun never crosses the horizon, so use solar time.
            let hour: Double = switch self {
            case .now, .noon: 12
            case .dawn: 6
            case .morning: 9
            case .afternoon: 15
            case .sunset: 18
            case .night: 23
            }
            return midnight.addingTimeInterval(hour * 3_600)
        }
        switch self {
        case .now: return now
        case .dawn: return times.rise.addingTimeInterval(-15 * 60)
        case .morning: return times.rise.addingTimeInterval(2.5 * 3_600)
        case .noon: return solarNoon
        case .afternoon: return solarNoon.addingTimeInterval(3.5 * 3_600)
        case .sunset: return times.set.addingTimeInterval(-10 * 60)
        case .night: return times.set.addingTimeInterval(2.5 * 3_600)
        }
    }
}

/// The brightest stars (right ascension in hours, declination and visual magnitude), so the night sky
/// shows the real constellations' anchors. Fainter stars are added procedurally.
enum StarCatalog {
    struct Star: Sendable {
        let rightAscensionHours: Double
        let declinationDegrees: Double
        let magnitude: Double
    }

    static let bright: [Star] = [
        Star(rightAscensionHours: 6.752, declinationDegrees: -16.716, magnitude: -1.46),  // Sirius
        Star(rightAscensionHours: 6.399, declinationDegrees: -52.696, magnitude: -0.74),  // Canopus
        Star(rightAscensionHours: 14.660, declinationDegrees: -60.834, magnitude: -0.27), // Alpha Centauri
        Star(rightAscensionHours: 14.261, declinationDegrees: 19.182, magnitude: -0.05),  // Arcturus
        Star(rightAscensionHours: 18.616, declinationDegrees: 38.784, magnitude: 0.03),   // Vega
        Star(rightAscensionHours: 5.278, declinationDegrees: 45.998, magnitude: 0.08),    // Capella
        Star(rightAscensionHours: 5.242, declinationDegrees: -8.202, magnitude: 0.13),    // Rigel
        Star(rightAscensionHours: 7.655, declinationDegrees: 5.225, magnitude: 0.34),     // Procyon
        Star(rightAscensionHours: 1.629, declinationDegrees: -57.237, magnitude: 0.46),   // Achernar
        Star(rightAscensionHours: 5.919, declinationDegrees: 7.407, magnitude: 0.50),     // Betelgeuse
        Star(rightAscensionHours: 14.064, declinationDegrees: -60.373, magnitude: 0.61),  // Hadar
        Star(rightAscensionHours: 19.846, declinationDegrees: 8.868, magnitude: 0.76),    // Altair
        Star(rightAscensionHours: 12.443, declinationDegrees: -63.099, magnitude: 0.77),  // Acrux
        Star(rightAscensionHours: 4.599, declinationDegrees: 16.509, magnitude: 0.86),    // Aldebaran
        Star(rightAscensionHours: 13.420, declinationDegrees: -11.161, magnitude: 0.97),  // Spica
        Star(rightAscensionHours: 16.490, declinationDegrees: -26.432, magnitude: 1.06),  // Antares
        Star(rightAscensionHours: 7.755, declinationDegrees: 28.026, magnitude: 1.14),    // Pollux
        Star(rightAscensionHours: 22.961, declinationDegrees: -29.622, magnitude: 1.16),  // Fomalhaut
        Star(rightAscensionHours: 20.690, declinationDegrees: 45.280, magnitude: 1.25),   // Deneb
        Star(rightAscensionHours: 12.795, declinationDegrees: -59.689, magnitude: 1.25),  // Mimosa
        Star(rightAscensionHours: 10.139, declinationDegrees: 11.967, magnitude: 1.35),   // Regulus
        Star(rightAscensionHours: 6.977, declinationDegrees: -28.972, magnitude: 1.50),   // Adhara
        Star(rightAscensionHours: 7.577, declinationDegrees: 31.888, magnitude: 1.58),    // Castor
        Star(rightAscensionHours: 17.560, declinationDegrees: -37.104, magnitude: 1.62),  // Shaula
        Star(rightAscensionHours: 5.418, declinationDegrees: 6.350, magnitude: 1.64),     // Bellatrix
        Star(rightAscensionHours: 5.438, declinationDegrees: 28.608, magnitude: 1.65),    // Elnath
        Star(rightAscensionHours: 5.604, declinationDegrees: -1.202, magnitude: 1.69),    // Alnilam
        Star(rightAscensionHours: 5.679, declinationDegrees: -1.943, magnitude: 1.74),    // Alnitak
        Star(rightAscensionHours: 12.900, declinationDegrees: 55.960, magnitude: 1.77),   // Alioth
        Star(rightAscensionHours: 11.062, declinationDegrees: 61.751, magnitude: 1.79),   // Dubhe
        Star(rightAscensionHours: 3.405, declinationDegrees: 49.861, magnitude: 1.79),    // Mirfak
        Star(rightAscensionHours: 13.792, declinationDegrees: 49.313, magnitude: 1.86),   // Alkaid
        Star(rightAscensionHours: 2.530, declinationDegrees: 89.264, magnitude: 1.98),    // Polaris
        Star(rightAscensionHours: 5.920, declinationDegrees: 44.947, magnitude: 1.90),    // Menkalinan
        Star(rightAscensionHours: 2.120, declinationDegrees: 23.462, magnitude: 2.00),    // Hamal
        Star(rightAscensionHours: 0.140, declinationDegrees: 29.091, magnitude: 2.06),    // Alpheratz
        Star(rightAscensionHours: 11.818, declinationDegrees: 14.572, magnitude: 2.14),   // Denebola
        Star(rightAscensionHours: 5.796, declinationDegrees: -9.670, magnitude: 2.06),    // Saiph
        Star(rightAscensionHours: 0.675, declinationDegrees: 56.537, magnitude: 2.24),    // Schedar
        Star(rightAscensionHours: 0.153, declinationDegrees: 59.150, magnitude: 2.27),    // Caph
    ]
}
