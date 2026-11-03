import RealityKit
import SwiftUI

/// The 3D view plus cockpit displays for one flight.
struct FlightView: View {
    let session: FlightSession

    var body: some View {
        ZStack {
            RealityView { content in
                do {
                    let geometry = try session.loadAircraft()
                    await session.prepareTerrain()
                    let start = try session.startCondition()
                    let scene = try await FlightScene.build(airport: session.airport, setup: session.setup,
                                                            aircraft: session.aircraft, geometry: geometry, start: start,
                                                            date: session.simulationDate, instruments: session.instruments,
                                                            terrain: session.terrain)
                    content.add(scene.root)
                    content.renderingEffects.antialiasing = .multisample4X
                    session.cameraChanged(title: scene.cameraTitle, all: scene.cameraTitles, inCockpit: scene.cameraInCockpit,
                                          inCabin: scene.cameraInCabin)
                    session.setListener(scene.listener)
                    session.start()
                    session.sceneSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
                        MainActor.assumeIsolated {
                            guard let result = session.frame(deltaTime: event.deltaTime) else { return }
                            scene.update(result, display: session.display, overlay: session.displayMode.overlayDisplays)
                            if result.camera != nil {
                                session.cameraChanged(title: scene.cameraTitle, all: scene.cameraTitles, inCockpit: scene.cameraInCockpit,
                                                      inCabin: scene.cameraInCabin)
                                session.setListener(scene.listener)
                            }
                        }
                    }
                } catch {
                    session.fail(error)
                }
            }
            .ignoresSafeArea()

            switch session.phase {
            case .loading:
                LoadingCard(title: "Preparing the \(session.aircraft.name) at \(session.airport.icao)", detail: session.setup.scenario.title)
            case .failed(let reason):
                VStack(spacing: 24) {
                    ErrorView(title: "The flight stopped", detail: reason)
                    Button("Back to start") { session.end() }
                }
                .padding(.bottom, 40)
                .glassEffect(.regular, in: .rect(cornerRadius: 32))
            case .flying:
                FlightHUD(session: session)
            }
        }
    }
}

extension DisplayMode {
    /// Displays the 2D overlay needs drawn.
    var overlayDisplays: [InstrumentDisplay] {
        switch self {
        case .glass: [.pfd, .nd, .upperEICAS]
        case .headUp, .map, .clean: []
        }
    }
}

private struct LoadingCard: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 40)
        .glassEffect(.regular, in: .rect(cornerRadius: 32))
    }
}
