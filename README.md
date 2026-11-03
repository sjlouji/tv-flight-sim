# Flight Sim for Apple TV

A flight simulator for Apple TV 4K, flown with an Xbox or PlayStation controller. Nine aircraft: Boeing
737-300, 747-400 and 787-8, Airbus A320, Lockheed C-130 Hercules, Cessna 172P, de Havilland Twin Otter,
Bombardier Global 5000 and the F-4N Phantom II.
Flight physics come from [JSBSim](https://github.com/JSBSim-Team/jsbsim); the departure airport is built from
real OpenStreetMap data (San Francisco International, KSFO), and about 2,500 airports worldwide are available
as destinations.

## What it does

- **Start page**: categories down the side (route, aircraft, takeoff and landing, weather, date and time); a map route planner with flight time and distance; start on the runway, on final approach (3 to 15 nm) or in flight anywhere around the airport
  (3,000 ft up to each aircraft's ceiling); an aircraft page with every type drawn from above and its figures; pick a destination from a searchable worldwide list; choose the weather (clear to
  thunderstorm, wind) and the time (now, dawn, morning, midday, afternoon, sunset, night). Choices are remembered.
- **Smooth motion**: physics runs at a fixed 120 Hz and every frame draws the aircraft interpolated between the
  last two physics steps, so uneven frame times never show as stutter. The world is re-centered on the
  aircraft each frame, so precision never jitters however far the flight goes.
- **Real sky**: sun, moon (with its phase) and stars are placed for the aircraft's latitude, longitude and the
  simulation clock. The sky is a physically based atmosphere (Rayleigh and Mie scattering, ozone, the Earth's
  shadow) rendered for the observer's altitude, and it also lights the scene. Night has moonlight and stars.
- **Ocean, clouds, weather**: a curved ocean with Earth-anchored waves, Fresnel sky reflection and sun glint;
  cumulus fields and stratus decks; rain; distance haze; whiteout inside cloud; wind and turbulence in JSBSim.
- **Aircraft**: each one flies its own JSBSim model and is drawn in code from that model's geometry (wing span
  and area, wheel positions, engine positions, eye point), so the wheels, engines and pilot's view sit where
  the physics has them. Each has its own flap detents, V-speeds, approach speed, maximum speed and ceiling, and
  only the systems it really has (fixed gear on the Cessna and Twin Otter, no reversers on the C-130 or F-4).
- **Cameras**: captain, first officer, cabin crew, passenger window, wing, chase, orbit, tower, flyby; the
  seats are "Left seat / Right seat" in light aircraft and "Pilot / Back seat" in the F-4, and cabin views only
  exist where there is a cabin. Chase and orbit distances follow the aircraft's size.
- **Cockpits**: an airliner flight deck (737, 747, 787, A320, C-130, Global 5000) with live PFD, ND, engine and
  systems displays and the mode control panel, a thrust lever per engine, speedbrake, flap and gear levers and
  yokes; a light-aircraft panel (Cessna, Twin Otter) with sliding yokes; and a tandem fighter cockpit (F-4) with
  sticks, side-console throttles and a head-up display combiner. Everything moves with the controls.
- **Cabin**: rows laid out from the fuselage width (3-4-3 on the 747, 3-3-3 on the 787, 3+3 on the 737 and
  A320, single seats on the Global and Twin Otter), with passengers and windows over the wing.
- **Displays**: head-up display (default), instruments (PFD, ND, engines), or a satellite map of the route; side rails of system indicators (trim, autopilot, autothrottle, thrust, caution, flaps, gear, spoilers, autobrake, parking brake) and a bar with every figure
  (IAS, GS, TAS, Mach, altitude, height, vertical speed, heading, track, wind, OAT, N1, fuel, fuel flow,
  distance, ETE, ETA, UTC).
- **Autopilot and autothrottle**: SPD, N1, LVL CHG, HDG SEL, LNAV (great-circle route to the destination),
  APP (localizer and glideslope on a synthetic ILS, flare and touchdown), ALT HLD, V/S; stick or thrust input
  disconnects them, with the warning sounds.
- **Systems**: autobrake (RTO, 1, 2, 3, MAX), speedbrake ARM with automatic deployment on landing, parking brake,
  reversers, exterior lights by flight phase (navigation, beacon, strobes, landing lights).
- **Checklists** for each phase (before takeoff, takeoff, climb, cruise, descent, approach, landing,
  after landing); items tick themselves when the aircraft state satisfies them.
- **Sound**, synthesized live from the flight model with a voice per engine type: turbofan tone and buzzsaw
  following N1 and turbine whine (N2); turbojet roar; turboprop propeller blade tone; piston cylinder firings and
  propeller; engines on each wing in their own speaker; airflow, runway rumble, gear and flap motors, stick shaker, autopilot disconnect, and spoken
  callouts (80 knots, V1, rotate, positive rate, 2,500 down to 10 ft, minimums, sink rate, pull up, bank angle).

## Requirements

- Xcode 27 with the tvOS 27 SDK (the app targets tvOS 26 and later) and the Metal Toolchain
  (`xcodebuild -downloadComponent MetalToolchain`)
- Homebrew packages: `brew install xcodegen cmake`
- Python 3 (standard library only)
- An Apple TV 4K and an Xbox or PlayStation controller paired to it

## Setup

```sh
./scripts/build-jsbsim.sh          # compiles JSBSim for Apple TV + simulator (about 15 s)
./scripts/fetch-assets.sh          # downloads CC0 surface textures
python3 scripts/fetch_airport.py KSFO --out FlightSim/Resources/Airports/KSFO.json        # already committed
python3 scripts/fetch_world_airports.py --out FlightSim/Resources/Airports/world.json    # already committed
xcodegen generate                  # creates FlightSim.xcodeproj from project.yml
open FlightSim.xcodeproj
```

To run on your Apple TV: in Xcode select the FlightSim target, set your team under Signing & Capabilities,
pair the Apple TV (Apple TV Settings > Remotes and Devices > Remote App and Devices), choose it as the run destination, and press Run.

## Tests

```sh
xcodebuild -project FlightSim.xcodeproj -scheme FlightSim \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (4th generation) (at 1080p)' test
python3 -m unittest discover -s scripts
```

Unit tests cover control mapping, coordinate conversion and the floating origin, runway geometry, the ground
model, triangulation, the PAPI lights, great-circle navigation and the ILS, astronomy (sun, sunrise and sunset,
moon phase, stars), aircraft systems, checklists, and the smoothness of interpolated motion. The flight model
and autopilot tests fly the real JSBSim 737: takeoff roll, trimmed approach, heading and altitude hold, V/S
descent and capture, level-change climb, LNAV, and a full localizer and glideslope approach to touchdown.
Every one of the nine aircraft is also checked: its JSBSim file reads into a sensible geometry, it sits on the
runway with the engines idling, it takes off and climbs, and the autopilot holds its altitude, speed and a
new heading.
The UI tests start flights in different weather and times from every camera and capture screenshots.

## Controls

| Control | Xbox | PlayStation |
|---|---|---|
| Pitch and roll | Left stick | Left stick |
| Rudder and nosewheel steering | LB / RB | L1 / R1 |
| Thrust levers forward / back (harder press moves them faster; they stay where you leave them) | RT / LT | R2 / L2 |
| Flaps up / down one detent (UP, 1, 2, 5, 10, 15, 25, 30, 40) | D-pad up / down | D-pad up / down |
| Speedbrake lever (DOWN, ARM, FLT, UP) | D-pad left / right | D-pad left / right |
| Wheel brakes (hold) | A | Cross |
| Parking brake | X | Square |
| Landing gear | Y | Triangle |
| Thrust reversers (on the ground, levers at idle) | B | Circle |
| Autopilot and checklist panel | Left stick click | L3 |
| Display: head-up, instruments, map, clean | Tap right stick click | Tap R3 |
| Pitch trim and rudder trim | Hold right stick click + D-pad | Hold R3 + D-pad |
| Look around (the view drifts back when released) | Right stick | Right stick |
| Next camera | View | Create |
| Pause (cameras, display, restart, end flight) | Menu | Options |

In the panel, the D-pad moves and changes values, A presses the selected button, LB / RB switch between the
autopilot and checklists, and B closes it. The sticks and triggers keep flying the aircraft.

## How it fits together

| Folder | Contents |
|---|---|
| `FlightSim/Flight` | JSBSim bridge and flight model wrapper, aircraft profiles and JSBSim geometry reader, start scenarios, navigation (route, LNAV, ILS), autopilot, aircraft systems, checklists, weather |
| `FlightSim/Controls` | Controller reading and the pure, tested mapping from buttons to the flown aircraft's controls |
| `FlightSim/World` | Geodesy and the floating origin, airport data and scene, aircraft builder (fuselage, wings, tail, engines, gear from JSBSim geometry), cockpits, cabin, sky and atmosphere, astronomy, ocean, clouds, cameras, materials and Metal shaders |
| `FlightSim/Audio` | Sound synthesis and callouts |
| `FlightSim/HUD` | Instrument drawing (shared by the 3D flight deck and the 2D overlay), overlay, panels, pause menu |
| `FlightSim/App` | App entry, start page, flight session (input, physics, automation, pause), RealityKit view |
| `scripts` | JSBSim build, asset download, OpenStreetMap airport fetch, worldwide airport list |

JSBSim runs at a fixed 120 Hz regardless of frame rate. Each airport's scene is built on a plane tangent to the
Earth at its reference point (x east, y up, -z north, meters) and placed relative to the aircraft every frame.

## Licensing notes

- JSBSim is LGPL-2.1, linked statically. That is fine for personal use. Publishing on the App Store needs the
  LGPL relinking obligations handled, for example by shipping object files.
- JSBSim's 737 and 747 flight model files are marked GPL (the 737's also "not to be sold"). The other seven
  carry no license of their own and are distributed in the JSBSim repository. Replace the models, or confirm
  their terms, before any paid release.
- Two JSBSim data fixes are applied by `scripts/build-jsbsim.sh`: the C-130's engines drive a direct thruster
  (its file pairs a jet-style turbine with a propeller, which leaves it unable to fly level), and JSBSim is
  compiled with `NDEBUG` so its internal asserts cannot abort the app (the flight model stops with an error
  instead if the simulation ever diverges).
- Airport data is © OpenStreetMap contributors (ODbL). The credit is shown in the app and must stay.
- The worldwide airport list is from OurAirports (public domain). Surface textures (ambientCG) are CC0.

## Current limits

- Only San Francisco has airport scenery. Other airports are destinations for navigation (route, LNAV, ILS);
  there is no runway or scenery there yet. Terrain is streamed worldwide.
- Still to come in Phase 2: generated runways and detailed scenery at airports worldwide, live METAR weather,
  and carrier starts for the F-4 (catapult and arresting hook).
- The aircraft, cockpits and cabins are built in code; purchased USDZ models can replace them later. JSBSim
  eye points that disagree with their own landing gear (787, A320, C-130, Twin Otter, Global 5000, F-4) are
  replaced by measured ones in `AircraftProfile`; this changes only the view, not the physics.
- Performance has been checked in the simulator only, not yet on Apple TV hardware.
