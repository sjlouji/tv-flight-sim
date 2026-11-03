"""Unit tests for fetch_airport.normalize. Run: python3 -m unittest discover -s scripts"""
import unittest

from fetch_airport import AirportDataError, normalize, parse_length_m, stitch_rings


def node(lat, lon):
    return {"lat": lat, "lon": lon}


AERODROME = {
    "type": "way", "id": 1,
    "tags": {"aeroway": "aerodrome", "icao": "KTST", "ele": "4", "name": "Test Field"},
    "geometry": [node(0, 0), node(0, 1), node(1, 1), node(1, 0), node(0, 0)],
}


class ParseLengthTests(unittest.TestCase):
    def test_units(self):
        self.assertEqual(parse_length_m("61"), 61.0)
        self.assertEqual(parse_length_m("61 m"), 61.0)
        self.assertAlmostEqual(parse_length_m("200 ft"), 60.96)
        self.assertIsNone(parse_length_m("wide"))
        self.assertIsNone(parse_length_m(None))


class StitchTests(unittest.TestCase):
    def test_joins_reversed_segments_into_one_ring(self):
        a = [[0, 0], [0, 1]]
        b = [[1, 1], [0, 1]]          # reversed relative to a
        c = [[1, 1], [1, 0], [0, 0]]
        rings = stitch_rings([a, b, c])
        self.assertEqual(len(rings), 1)
        self.assertEqual(rings[0][0], rings[0][-1])
        self.assertEqual(len(rings[0]), 5)

    def test_drops_unclosed_ring(self):
        self.assertEqual(stitch_rings([[[0, 0], [0, 1]]]), [])


class NormalizeTests(unittest.TestCase):
    def test_runway_taxiway_and_defaults(self):
        raw = {"elements": [
            AERODROME,
            {"type": "way", "id": 2, "tags": {"aeroway": "runway", "ref": "09/27", "width": "45"},
             "geometry": [node(0.5, 0.1), node(0.5, 0.9)]},
            {"type": "way", "id": 3, "tags": {"aeroway": "taxiway", "ref": "A"},
             "geometry": [node(0.4, 0.1), node(0.4, 0.9)]},
            {"type": "way", "id": 4, "tags": {"building": "terminal", "building:levels": "3"},
             "geometry": [node(0.2, 0.2), node(0.2, 0.3), node(0.3, 0.3), node(0.2, 0.2)]},
        ]}
        airport = normalize(raw, "KTST")
        self.assertEqual(airport["reference"]["elevation_m"], 4.0)
        self.assertEqual(airport["runways"][0]["ref"], "09/27")
        self.assertEqual(airport["taxiways"][0]["width_m"], 23.0)
        self.assertEqual(airport["defaults_used"]["taxiway_width_default"], 1)
        self.assertEqual(airport["buildings"][0]["kind"], "terminal")
        self.assertEqual(airport["buildings"][0]["height_m"], 12.0)

    def test_split_runway_pieces_are_merged_into_one_centerline(self):
        raw = {"elements": [
            AERODROME,
            {"type": "way", "id": 2, "tags": {"aeroway": "runway", "ref": "09/27", "width": "45"},
             "geometry": [node(0.5, 0.1), node(0.5, 0.5)]},
            {"type": "way", "id": 3, "tags": {"aeroway": "runway", "ref": "09/27", "width": "45"},
             "geometry": [node(0.5, 0.9), node(0.5, 0.5)]},
        ]}
        runways = normalize(raw, "KTST")["runways"]
        self.assertEqual(len(runways), 1)
        self.assertEqual(runways[0]["centerline"], [[0.5, 0.1], [0.5, 0.5], [0.5, 0.9]])

    def test_missing_elevation_is_an_error(self):
        aerodrome = dict(AERODROME, tags={"aeroway": "aerodrome", "icao": "KTST"})
        with self.assertRaises(AirportDataError):
            normalize({"elements": [aerodrome]}, "KTST")

    def test_no_runways_is_an_error(self):
        with self.assertRaises(AirportDataError):
            normalize({"elements": [AERODROME]}, "KTST")


if __name__ == "__main__":
    unittest.main()
