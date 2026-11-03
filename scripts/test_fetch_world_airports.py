"""Unit tests for fetch_world_airports.normalize. Run: python3 -m unittest discover -s scripts"""
import unittest

from fetch_world_airports import AirportDataError, bearing_degrees, normalize


def airport(ident="KTST", kind="large_airport", service="yes", icao="KTST", elevation="13"):
    return {"ident": ident, "type": kind, "scheduled_service": service, "icao_code": icao, "gps_code": icao,
            "name": "Test Intl", "municipality": "Testville", "iso_country": "US",
            "latitude_deg": "37.0", "longitude_deg": "-122.0", "elevation_ft": elevation, "iata_code": "TST"}


def runway(ident="KTST", length="10000", surface="ASP", closed="0", le_elev="10", width="150"):
    return {"airport_ident": ident, "length_ft": length, "width_ft": width, "surface": surface, "closed": closed,
            "le_ident": "09", "le_latitude_deg": "37.0", "le_longitude_deg": "-122.02", "le_elevation_ft": le_elev,
            "he_ident": "27", "he_latitude_deg": "37.0", "he_longitude_deg": "-121.98", "he_elevation_ft": ""}


class BearingTests(unittest.TestCase):
    def test_due_east_and_north(self):
        self.assertAlmostEqual(bearing_degrees(0, 0, 0, 1), 90, places=3)
        self.assertAlmostEqual(bearing_degrees(0, 0, 1, 0), 0, places=3)


class NormalizeTests(unittest.TestCase):
    def test_runway_becomes_two_landing_directions(self):
        data = normalize([airport()], [runway()])
        ends = data["airports"][0]["runways"]
        self.assertEqual([e["id"] for e in ends], ["09", "27"])
        self.assertAlmostEqual(ends[0]["heading"], 90, delta=0.1)
        self.assertAlmostEqual(ends[1]["heading"], 270, delta=0.1)
        self.assertEqual(ends[0]["elevation_ft"], 10)
        # The 27 threshold had no elevation, so it takes the airport's.
        self.assertEqual(ends[1]["elevation_ft"], 13)

    def test_filters_short_unpaved_closed_runways_and_unscheduled_airports(self):
        rows = [runway(length="3000"), runway(surface="GRS"), runway(closed="1")]
        with self.assertRaises(AirportDataError):
            normalize([airport()], rows)
        with self.assertRaises(AirportDataError):
            normalize([airport(service="no")], [runway()])
        with self.assertRaises(AirportDataError):
            normalize([airport(icao="")], [runway()])

    def test_missing_width_uses_default(self):
        data = normalize([airport()], [runway(width="")])
        self.assertEqual(data["airports"][0]["runways"][0]["width_ft"], 148)


if __name__ == "__main__":
    unittest.main()
