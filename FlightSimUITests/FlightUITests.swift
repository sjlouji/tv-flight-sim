import XCTest

/// Drives the real app with the Siri Remote: starts flights in different conditions and captures what is
/// on screen from every camera. Launch arguments preset the start page (it remembers choices in user
/// defaults, which launch arguments override).
final class FlightUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testStartPage() throws {
        app.launchArguments = ["-startKind", "On the runway", "-timeOfDay", "now", "-destination", "KLAX"]
        app.launch()
        XCTAssertTrue(app.buttons["Start flight"].waitForExistence(timeout: 60), "The start page did not appear")
        attachScreenshot("Start page")
    }

    func testTakeoffChaseAtMidday() throws {
        try fly(["-startKind", "On the runway", "-runway", "28L", "-timeOfDay", "noon", "-weather", "fewClouds"], camera: "chase")
        sleep(5)
        attachScreenshot("Takeoff 28L, chase, midday, few clouds")
    }

    func testCaptainOnFinalApproach() throws {
        try fly(["-startKind", "Final approach", "-runway", "28L", "-approachDistance", "<real>6</real>", "-timeOfDay", "afternoon",
                 "-weather", "scattered"], camera: "captain")
        sleep(6)
        attachScreenshot("Final approach 28L, captain, afternoon, scattered")
    }

    func testFirstOfficerHeadUpDisplay() throws {
        try fly(["-startKind", "Final approach", "-runway", "28L", "-approachDistance", "<real>6</real>", "-timeOfDay", "morning",
                 "-displayMode", "Head-up display"], camera: "firstOfficer")
        sleep(5)
        attachScreenshot("Final approach, first officer, head-up display")
    }

    func testPassengerWindowInCruise() throws {
        try fly(["-startKind", "In flight", "-altitude", "<real>24000</real>", "-timeOfDay", "morning", "-weather", "broken"], camera: "passenger")
        sleep(6)
        attachScreenshot("FL240, passenger window, broken clouds")
    }

    func testCabinCrewView() throws {
        try fly(["-startKind", "In flight", "-altitude", "<real>10000</real>", "-timeOfDay", "noon"], camera: "cabinCrew")
        sleep(5)
        attachScreenshot("10,000 ft, cabin crew")
    }

    func testWingViewOverOceanAtSunset() throws {
        try fly(["-startKind", "In flight", "-altitude", "<real>3000</real>", "-timeOfDay", "sunset", "-weather", "clear"], camera: "wing")
        sleep(6)
        attachScreenshot("3,000 ft over the ocean at sunset, wing")
    }

    func testNightCruiseFromTheCockpit() throws {
        try fly(["-startKind", "In flight", "-altitude", "<real>35000</real>", "-timeOfDay", "night", "-weather", "clear"], camera: "captain")
        sleep(6)
        attachScreenshot("FL350 at night, captain")
    }

    func testRainApproachFromTheTower() throws {
        try fly(["-startKind", "Final approach", "-runway", "28L", "-approachDistance", "<real>3</real>", "-timeOfDay", "noon",
                 "-weather", "rain"], camera: "tower")
        sleep(6)
        attachScreenshot("Final approach in rain, tower")
    }

    func testRouteMap() throws {
        try fly(["-startKind", "In flight", "-altitude", "<real>24000</real>", "-destination", "KLAX", "-displayMode", "Map"], camera: "orbit")
        sleep(6)
        attachScreenshot("Route to KLAX, map")
    }

    func testTerrainOverTheHills() throws {
        try fly(["-startKind", "In flight", "-altitude", "<real>10000</real>", "-offsetDistance", "<real>25</real>",
                 "-offsetBearing", "<real>180</real>", "-timeOfDay", "noon", "-weather", "fewClouds"], camera: "chase")
        sleep(12)
        attachScreenshot("10,000 ft over the Santa Cruz Mountains, chase")
    }

    func testFlyby() throws {
        try fly(["-startKind", "In flight", "-altitude", "<real>3000</real>", "-timeOfDay", "afternoon"], camera: "flyby")
        sleep(8)
        attachScreenshot("Flyby")
    }

    // MARK: - The fleet

    func testAircraftPage() throws {
        app.launchArguments = ["-startPage", "Aircraft", "-aircraft", "b747"]
        app.launch()
        XCTAssertTrue(app.buttons["Start flight"].waitForExistence(timeout: 60), "The start page did not appear")
        XCTAssertTrue(app.buttons["c172"].exists, "The Cessna is in the fleet")
        attachScreenshot("Aircraft page, 747 selected")
    }

    func testJumboTakeoffChase() throws {
        try fly(["-startKind", "On the runway", "-runway", "28L", "-timeOfDay", "noon", "-weather", "fewClouds"], camera: "chase", aircraft: "b747")
        sleep(5)
        attachScreenshot("747-400 on 28L, chase")
    }

    func testCessnaLeftSeatOnTheRunway() throws {
        try fly(["-startKind", "On the runway", "-runway", "28L", "-timeOfDay", "morning", "-weather", "fewClouds"], camera: "captain",
                aircraft: "c172")
        sleep(5)
        attachScreenshot("Cessna 172 on 28L, left seat")
    }

    func testCessnaOrbitInFlight() throws {
        try fly(["-startKind", "In flight", "-altitude", "<real>3000</real>", "-timeOfDay", "afternoon", "-weather", "clear"], camera: "orbit",
                aircraft: "c172")
        sleep(5)
        attachScreenshot("Cessna 172 at 3,000 ft, orbit")
    }

    func testPhantomPilotInFlight() throws {
        try fly(["-startKind", "In flight", "-altitude", "<real>18000</real>", "-timeOfDay", "noon", "-weather", "scattered"], camera: "captain",
                aircraft: "f4")
        sleep(5)
        attachScreenshot("F-4 at FL180, pilot")
    }

    func testPhantomChase() throws {
        try fly(["-startKind", "On the runway", "-runway", "28L", "-timeOfDay", "afternoon"], camera: "chase", aircraft: "f4")
        sleep(5)
        attachScreenshot("F-4 on 28L, chase")
    }

    func testHerculesWingView() throws {
        try fly(["-startKind", "In flight", "-altitude", "<real>10000</real>", "-timeOfDay", "noon", "-weather", "fewClouds"], camera: "wing",
                aircraft: "c130")
        sleep(5)
        attachScreenshot("C-130 at 10,000 ft, wing")
    }

    func testTwinOtterApproachOrbit() throws {
        try fly(["-startKind", "Final approach", "-runway", "28L", "-approachDistance", "<real>3</real>", "-timeOfDay", "afternoon"],
                camera: "orbit", aircraft: "dhc6")
        sleep(5)
        attachScreenshot("Twin Otter on final, orbit")
    }

    func testA320PassengerWindow() throws {
        try fly(["-startKind", "In flight", "-altitude", "<real>24000</real>", "-timeOfDay", "morning", "-weather", "scattered"],
                camera: "passenger", aircraft: "a320")
        sleep(5)
        attachScreenshot("A320 at FL240, passenger window")
    }

    func testDreamlinerFirstOfficer() throws {
        try fly(["-startKind", "Final approach", "-runway", "28L", "-approachDistance", "<real>6</real>", "-timeOfDay", "sunset"],
                camera: "firstOfficer", aircraft: "b787")
        sleep(5)
        attachScreenshot("787-8 on final, first officer")
    }

    func testGlobalCabinAndOrbit() throws {
        try fly(["-startKind", "In flight", "-altitude", "<real>35000</real>", "-timeOfDay", "afternoon", "-weather", "clear"], camera: "orbit",
                aircraft: "global5000")
        sleep(5)
        attachScreenshot("Global 5000 at FL350, orbit")
    }

    /// Launches with the given start page settings, aircraft and camera, presses Start flight (focused by
    /// default), and waits for the flight's status bar.
    private func fly(_ arguments: [String], camera: String, aircraft: String = "b737") throws {
        app.launchArguments = arguments + ["-initialCamera", camera, "-aircraft", aircraft]
        app.launch()
        let start = app.buttons["Start flight"]
        // A cold start in the simulator (airport list, map) can take a while.
        XCTAssertTrue(start.waitForExistence(timeout: 60), "The start page did not appear")
        XCTAssertTrue(start.hasFocus, "Start flight should have focus")
        XCUIRemote.shared.press(.select)
        // The status bar shows the flight phase once the flight is running.
        let phases = ["Before takeoff", "Takeoff", "Climb", "Cruise", "Descent", "Approach", "Landing"]
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if phases.contains(where: { app.staticTexts[$0].exists }) { break }
            XCTAssertFalse(app.staticTexts["The flight stopped"].exists, "The flight failed to start")
            sleep(1)
        }
        XCTAssertTrue(phases.contains(where: { app.staticTexts[$0].exists }), "The flight status bar did not appear")
    }

    private func attachScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
