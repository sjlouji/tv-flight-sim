import SwiftUI

/// The flight-deck panel (left stick click): a compact autopilot panel on the left, or the checklists.
/// It is driven by the D-pad through the session, so the sticks keep flying the aircraft while it is open.
struct FlightDeckPanel: View {
    let session: FlightSession

    var body: some View {
        if let panel = session.panel {
            HStack {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        ForEach(PanelState.Tab.allCases, id: \.self) { tab in
                            Text(tab.rawValue.uppercased())
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(tab == panel.tab ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(.clear), in: .capsule)
                                .foregroundStyle(tab == panel.tab ? .primary : .secondary)
                        }
                    }
                    switch panel.tab {
                    case .autopilot: AutopilotPanel(display: session.display, selected: panel.controlIndex)
                    case .checklist: ChecklistPanel(display: session.display, phase: panel.checklistPhase, selected: panel.checklistItem)
                    }
                    Text(hint(for: panel.tab)).font(.caption2).foregroundStyle(.secondary)
                }
                .padding(22)
                .frame(width: panel.tab == .autopilot ? 440 : 760, alignment: .leading)
                .overlayGlass(in: .rect(cornerRadius: 28))
                Spacer()
            }
            .padding(.top, 80)
            .padding(.bottom, 120)
        }
    }

    private func hint(for tab: PanelState.Tab) -> String {
        switch tab {
        case .autopilot: "▲▼ choose · ◀▶ set · A press · LB RB tabs · B close"
        case .checklist: "◀▶ checklist · ▲▼ item · A check · LB RB tabs · B close"
        }
    }
}

private struct AutopilotPanel: View {
    let display: CockpitDisplay
    let selected: Int

    var body: some View {
        let ap = display.autopilot
        VStack(spacing: 6) {
            ForEach(Array(PanelState.controls(for: display.aircraft).enumerated()), id: \.offset) { index, control in
                HStack {
                    Text(control.title).font(.callout.weight(.bold))
                    Spacer()
                    if control.isValue {
                        Text(value(control, ap))
                            .font(.system(size: 26, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.orange)
                    } else {
                        Capsule()
                            .fill(lit(control, ap) ? Color(red: 0.3, green: 1, blue: 0.45) : Color.white.opacity(0.15))
                            .frame(width: 46, height: 8)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(index == selected ? AnyShapeStyle(.white.opacity(0.2)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(index == selected ? 0.9 : 0), lineWidth: 2))
                .animation(.spring(response: 0.3, dampingFraction: 1), value: selected)
            }
        }
    }

    private func value(_ control: PanelState.Control, _ ap: Autopilot) -> String {
        switch control {
        case .speed: "\(Int(ap.mcp.speedKnots))"
        case .heading: String(format: "%03d", Int(ap.mcp.headingDegrees) % 360)
        case .altitude: "\(Int(ap.mcp.altitudeFeet))"
        case .verticalSpeed: String(format: "%+d", Int(ap.mcp.verticalSpeedFPM))
        case .autobrake: display.autobrake.label
        case .button: ""
        }
    }

    private func lit(_ control: PanelState.Control, _ ap: Autopilot) -> Bool {
        guard case .button(let button) = control else { return false }
        switch button {
        case .autopilot: return ap.autopilotEngaged
        case .autothrottle: return ap.autothrottleArmed
        case .n1: return ap.thrustMode == .climb
        case .speed: return ap.thrustMode == .speed
        case .levelChange: return ap.autopilotEngaged && ap.pitchMode == .levelChange
        case .heading: return ap.autopilotEngaged && ap.rollMode == .heading
        case .lnav: return ap.autopilotEngaged && ap.rollMode == .lnav
        case .approach: return ap.localizerArmed || ap.glideslopeArmed || ap.rollMode == .localizer
        case .altitudeHold: return ap.autopilotEngaged && ap.pitchMode == .altitudeHold
        case .verticalSpeed: return ap.autopilotEngaged && ap.pitchMode == .verticalSpeed
        }
    }
}

private struct ChecklistPanel: View {
    let display: CockpitDisplay
    let phase: FlightPhase
    let selected: Int

    var body: some View {
        let checklist = Checklists.checklist(for: phase, aircraft: display.aircraft)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(checklist.title.uppercased()).font(.title3.weight(.bold))
                if phase == display.phase {
                    Text("Current phase").font(.caption.weight(.semibold)).foregroundStyle(.green)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.green.opacity(0.18), in: .capsule)
                }
                Spacer()
                if let context = display.checklistContext {
                    let done = display.checklistProgress.completedCount(checklist, context)
                    Text("\(done) of \(checklist.items.count)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(done == checklist.items.count ? .green : .secondary)
                }
            }
            ForEach(Array(checklist.items.enumerated()), id: \.element.id) { index, item in
                let done = display.checklistContext.map { display.checklistProgress.isDone(item, $0) } ?? false
                HStack(spacing: 14) {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(done ? .green : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                    Text(item.challenge).font(.headline)
                    Spacer()
                    Text(item.response).font(.headline).foregroundStyle(done ? .green : .primary)
                    if item.isSatisfied == nil { Text("manual").font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(index == selected ? AnyShapeStyle(.white.opacity(0.16)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 12))
            }
        }
    }
}

/// The pause menu: categories on the left, their options on the right, navigated with tvOS focus
/// (Siri Remote or controller). Menu resumes.
struct PauseMenu: View {
    let session: FlightSession

    enum Category: String, CaseIterable, Identifiable {
        case flight = "Flight"
        case camera = "Camera"
        case display = "Display"
        case controls = "Controls"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .flight: "airplane"
            case .camera: "video.fill"
            case .display: "rectangle.on.rectangle"
            case .controls: "gamecontroller.fill"
            }
        }
    }

    @State private var category: Category = .flight
    @FocusState private var focused: Category?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Paused").font(.title.weight(.bold)).padding(.bottom, 10)
                ForEach(Category.allCases) { item in
                    Button { category = item } label: {
                        Label(item.rawValue, systemImage: item.symbol).frame(width: 300, alignment: .leading)
                    }
                    .focused($focused, equals: item)
                    .tint(item == category ? .accentColor : nil)
                }
                Spacer()
            }
            .padding(36)
            .frame(width: 420)
            .background(.black.opacity(0.25))
            VStack(alignment: .leading, spacing: 18) {
                Text(category.rawValue).font(.title2.weight(.bold))
                Text(session.setup.scenario.title).foregroundStyle(.secondary)
                content
                Spacer()
            }
            .padding(40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 1400, height: 760)
        .overlayGlass(in: .rect(cornerRadius: 40))
        .clipShape(.rect(cornerRadius: 40))
        .onAppear { focused = .flight }
        .onChange(of: focused) { if let focused { category = focused } }
        .onExitCommand { session.resume() }
    }

    @ViewBuilder
    private var content: some View {
        switch category {
        case .flight:
            HStack(spacing: 20) {
                Button { session.resume() } label: { Label("Resume", systemImage: "play.fill") }
                Button { session.restartFromMenu() } label: { Label("Restart", systemImage: "arrow.counterclockwise") }
                Button(role: .destructive) { session.end() } label: { Label("End flight", systemImage: "xmark") }
            }
        case .camera:
            LazyVGrid(columns: [GridItem(.fixed(290)), GridItem(.fixed(290)), GridItem(.fixed(290))], alignment: .leading, spacing: 16) {
                ForEach(session.cameraTitles, id: \.self) { title in
                    Button { session.selectCamera(title) } label: {
                        Label(title, systemImage: title == session.cameraTitle ? "checkmark" : "video").frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .display:
            HStack(spacing: 20) {
                ForEach(DisplayMode.allCases, id: \.self) { mode in
                    Button { session.selectDisplayMode(mode) } label: {
                        Label(mode.rawValue, systemImage: mode == session.displayMode ? "checkmark" : "rectangle")
                    }
                }
            }
        case .controls:
            ControlsReference()
        }
    }
}

private struct ControlsReference: View {
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
            row("Left stick", "Pitch and roll")
            row("LB / RB", "Rudder and nosewheel steering")
            row("RT / LT", "Thrust levers forward / back (harder = faster)")
            row("D-pad ▲ ▼", "Flaps up / down")
            row("D-pad ◀ ▶", "Speedbrake: DOWN, ARM, FLT, UP")
            row("A · X · Y · B", "Brakes · parking brake · gear · reversers")
            row("Left stick click", "Autopilot and checklists panel")
            row("Right stick click", "Tap: display · hold + D-pad: trim")
            row("Right stick · View", "Look around · next camera")
        }
        .font(.callout)
    }

    private func row(_ control: String, _ action: String) -> some View {
        GridRow {
            Text(control).fontWeight(.semibold)
            Text(action).foregroundStyle(.secondary)
        }
    }
}
