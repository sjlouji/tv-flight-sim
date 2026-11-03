import SwiftUI

@main
struct FlightSimApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Loads the airport and the worldwide airport list, shows the start page, and runs one flight at a time.
struct RootView: View {
    static let airportCode = "KSFO"

    private struct Data {
        let airport: Airport
        let database: NavDatabase
    }

    @State private var data: Result<Data, Error>?
    @State private var session: FlightSession?

    var body: some View {
        Group {
            switch data {
            case nil:
                ProgressView("Loading airports")
            case .failure(let error):
                ErrorView(title: "Airport data could not be loaded", detail: error.localizedDescription)
            case .success(let data):
                if let session {
                    GameControllerHost(allowsSystemNavigation: session.phase.isFailure || session.isPaused) { FlightView(session: session) }
                        .ignoresSafeArea()
                } else {
                    LandingView(airport: data.airport, database: data.database) { setup in
                        let session = FlightSession(airport: data.airport, setup: setup, database: data.database)
                        session.onExit = { self.session = nil }
                        self.session = session
                    }
                }
            }
        }
        .task {
            guard data == nil else { return }
            data = Result { Data(airport: try Airport.load(icao: Self.airportCode), database: try NavDatabase.load()) }
        }
    }
}

struct ErrorView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.yellow)
            Text(title).font(.title3.bold())
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(80)
    }
}
