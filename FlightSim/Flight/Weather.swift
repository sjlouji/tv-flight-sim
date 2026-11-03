import Foundation

/// A cloud layer: puffy cumulus, or a continuous stratus deck.
struct CloudLayer: Equatable, Sendable {
    enum Kind: Sendable { case cumulus, stratus }
    var kind: Kind
    /// Fraction of the sky covered (oktas / 8).
    var coverage: Double
    var baseFeet: Double
    var thicknessFeet: Double
    var topFeet: Double { baseFeet + thicknessFeet }
}

/// Weather the pilot can pick on the start page.
enum WeatherPreset: String, CaseIterable, Identifiable, Sendable {
    case clear, fewClouds, scattered, broken, overcast, rain, fog, thunderstorm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clear: "Clear"
        case .fewClouds: "Few clouds"
        case .scattered: "Scattered"
        case .broken: "Broken"
        case .overcast: "Overcast"
        case .rain: "Rain"
        case .fog: "Fog"
        case .thunderstorm: "Thunderstorm"
        }
    }

    var symbol: String {
        switch self {
        case .clear: "sun.max.fill"
        case .fewClouds: "cloud.sun.fill"
        case .scattered: "cloud.sun.fill"
        case .broken: "cloud.fill"
        case .overcast: "smoke.fill"
        case .rain: "cloud.rain.fill"
        case .fog: "cloud.fog.fill"
        case .thunderstorm: "cloud.bolt.rain.fill"
        }
    }

    /// Cloud layers, with bases above the airport.
    var layers: [CloudLayer] {
        switch self {
        case .clear: []
        case .fewClouds: [CloudLayer(kind: .cumulus, coverage: 0.2, baseFeet: 4_500, thicknessFeet: 2_500)]
        case .scattered: [CloudLayer(kind: .cumulus, coverage: 0.45, baseFeet: 3_500, thicknessFeet: 3_500)]
        case .broken: [CloudLayer(kind: .cumulus, coverage: 0.7, baseFeet: 3_000, thicknessFeet: 4_500)]
        case .overcast: [CloudLayer(kind: .stratus, coverage: 1, baseFeet: 2_200, thicknessFeet: 3_000)]
        case .rain: [CloudLayer(kind: .stratus, coverage: 1, baseFeet: 1_400, thicknessFeet: 7_000)]
        case .fog: [CloudLayer(kind: .stratus, coverage: 1, baseFeet: 150, thicknessFeet: 900)]
        case .thunderstorm:
            [CloudLayer(kind: .stratus, coverage: 1, baseFeet: 1_800, thicknessFeet: 3_000),
             CloudLayer(kind: .cumulus, coverage: 0.6, baseFeet: 2_500, thicknessFeet: 20_000)]
        }
    }

    /// Horizontal visibility below the clouds.
    var visibilityMeters: Double {
        switch self {
        case .clear: 80_000
        case .fewClouds: 50_000
        case .scattered: 35_000
        case .broken: 25_000
        case .overcast: 15_000
        case .rain: 5_000
        case .fog: 350
        case .thunderstorm: 3_000
        }
    }

    /// 0 dry ... 1 heavy rain.
    var rainIntensity: Double {
        switch self {
        case .rain: 0.6
        case .thunderstorm: 1
        default: 0
        }
    }

    /// MIL-F-8785C severity index.
    var turbulenceSeverity: Int {
        switch self {
        case .clear, .fewClouds, .fog: 0
        case .scattered, .broken, .overcast: 3
        case .rain: 4
        case .thunderstorm: 6
        }
    }

    /// How much daylight the clouds let through to the ground (1 clear sky).
    var daylightTransmission: Double {
        switch self {
        case .clear, .fewClouds: 1
        case .scattered: 0.9
        case .broken: 0.7
        case .overcast: 0.45
        case .rain: 0.3
        case .fog: 0.4
        case .thunderstorm: 0.2
        }
    }
}

struct WeatherSettings: Equatable, Sendable {
    var preset: WeatherPreset = .fewClouds
    var windFromDegrees: Double = 280
    var windSpeedKnots: Double = 10

    /// What JSBSim simulates: wind, and turbulence from the clouds or strong wind.
    var atmosphere: AtmosphereSettings {
        let windTurbulence = windSpeedKnots >= 25 ? 4 : (windSpeedKnots >= 15 ? 3 : 0)
        return AtmosphereSettings(windFromDegrees: windFromDegrees, windSpeedKnots: windSpeedKnots,
                                  turbulenceSeverity: max(preset.turbulenceSeverity, windTurbulence), temperatureOffsetC: 0)
    }

    static let windSpeeds: [Double] = [0, 5, 10, 15, 25, 35]
}
