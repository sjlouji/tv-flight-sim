#!/usr/bin/env python3
"""Download a real airport layout from OpenStreetMap and save it as app data.

Usage:
    python3 scripts/fetch_airport.py KSFO --out FlightSim/Resources/Airports/KSFO.json

The output keeps geographic coordinates (latitude, longitude). The app projects
them into its local 3D frame, so there is a single projection implementation.

Map data (c) OpenStreetMap contributors, available under the Open Database
License (ODbL). The app must show that credit.
"""
from __future__ import annotations

import argparse
import json
import logging
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

OVERPASS_URL = "https://overpass-api.de/api/interpreter"
USER_AGENT = "tv-flight-sim/0.1 (personal flight simulator airport data build)"

# Widths and heights used when OpenStreetMap has no tag. Every use is counted
# and logged so missing data is visible, never silent.
DEFAULT_RUNWAY_WIDTH_M = 45.0   # ICAO code letter E runway width
DEFAULT_TAXIWAY_WIDTH_M = 23.0  # ICAO code letter E taxiway width
DEFAULT_LEVEL_HEIGHT_M = 4.0
DEFAULT_BUILDING_HEIGHT_M = {"terminal": 18.0, "hangar": 20.0, "control_tower": 60.0, "other": 9.0}

log = logging.getLogger("fetch_airport")


class AirportDataError(Exception):
    """Raised when OpenStreetMap data is missing something the app cannot work without."""


def build_query(icao: str) -> str:
    return f"""
[out:json][timeout:180];
(way["aeroway"="aerodrome"]["icao"="{icao}"];relation["aeroway"="aerodrome"]["icao"="{icao}"];)->.ad;
.ad map_to_area->.a;
(
  way["aeroway"~"^(runway|taxiway|apron|parking_position)$"](area.a);
  relation["aeroway"="apron"](area.a);
  node["aeroway"~"^(holding_position|gate)$"](area.a);
  way["building"](area.a);
  relation["building"](area.a);
  way["aeroway"="control_tower"](area.a);
);
out tags geom;
.ad out tags geom;
"""


def fetch_overpass(icao: str, url: str, attempts: int = 4) -> dict[str, Any]:
    """Query Overpass, retrying on the 429/5xx responses its public servers return under load."""
    body = urllib.parse.urlencode({"data": build_query(icao)}).encode()
    for attempt in range(1, attempts + 1):
        request = urllib.request.Request(url, data=body, headers={"User-Agent": USER_AGENT})
        log.info("Querying %s for %s (attempt %d of %d)", url, icao, attempt, attempts)
        try:
            with urllib.request.urlopen(request, timeout=240) as response:
                return json.load(response)
        except urllib.error.HTTPError as exc:
            retryable = exc.code in (429, 502, 503, 504)
            log.error("Overpass request for %s failed with HTTP %d", icao, exc.code)
            if not retryable or attempt == attempts:
                raise
        except Exception as exc:
            log.error("Overpass request for %s failed: %s", icao, exc)
            raise
        delay = 15 * attempt
        log.info("Retrying in %d seconds", delay)
        time.sleep(delay)
    raise AssertionError("unreachable")


def parse_length_m(raw: str | None) -> float | None:
    """Parse OSM length tags such as '61', '61 m', '200 ft' or '45.7'."""
    if raw is None:
        return None
    text = raw.strip().lower().replace(",", ".")
    factor = 1.0
    for suffix, multiplier in ((" ft", 0.3048), ("ft", 0.3048), ("'", 0.3048), (" m", 1.0), ("m", 1.0)):
        if text.endswith(suffix):
            text, factor = text[: -len(suffix)].strip(), multiplier
            break
    try:
        value = float(text) * factor
    except ValueError:
        log.warning("Ignoring unparseable length tag %r", raw)
        return None
    return value if value > 0 else None


def way_points(element: dict[str, Any]) -> list[list[float]]:
    return [[round(p["lat"], 7), round(p["lon"], 7)] for p in element.get("geometry", []) if p]


def join_segments(segments: list[list[list[float]]]) -> list[list[list[float]]]:
    """Join ways that share end points into the longest possible chains.

    Closed chains (first point == last point) are rings; open ones are polylines.
    """
    pending = [list(s) for s in segments if len(s) >= 2]
    chains: list[list[list[float]]] = []
    while pending:
        chain = pending.pop(0)
        progress = True
        while chain[0] != chain[-1] and progress:
            progress = False
            for i, seg in enumerate(pending):
                if seg[0] == chain[-1]:
                    chain.extend(seg[1:])
                elif seg[-1] == chain[-1]:
                    chain.extend(list(reversed(seg))[1:])
                elif seg[-1] == chain[0]:
                    chain[:0] = seg[:-1]
                elif seg[0] == chain[0]:
                    chain[:0] = list(reversed(seg))[:-1]
                else:
                    continue
                pending.pop(i)
                progress = True
                break
        chains.append(chain)
    return chains


def stitch_rings(segments: list[list[list[float]]]) -> list[list[list[float]]]:
    """Join multipolygon member ways that share end points into closed rings."""
    rings = []
    for chain in join_segments(segments):
        if chain[0] != chain[-1]:
            log.warning("Dropping an unclosed multipolygon ring with %d points", len(chain))
            continue
        rings.append(chain)
    return rings


def merge_runway_pieces(pieces: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """OpenStreetMap often splits one runway into several ways; rebuild one centerline per ref."""
    by_ref: dict[str, list[dict[str, Any]]] = {}
    for piece in pieces:
        by_ref.setdefault(piece["ref"], []).append(piece)
    merged = []
    for ref, group in by_ref.items():
        chains = join_segments([p["centerline"] for p in group])
        if len(chains) > 1:
            log.warning("Runway %s has %d disconnected pieces; keeping the longest", ref, len(chains))
        longest = max(chains, key=len)
        merged.append({"ref": ref,
                       "width_m": max(p["width_m"] for p in group),
                       "surface": group[0]["surface"],
                       "centerline": longest})
    return merged


def outer_rings(element: dict[str, Any]) -> list[list[list[float]]]:
    if element["type"] == "way":
        points = way_points(element)
        return [points] if len(points) >= 4 and points[0] == points[-1] else []
    outers = [way_points(m) for m in element.get("members", []) if m.get("type") == "way" and m.get("role") in ("outer", "")]
    return stitch_rings(outers)


def building_kind(tags: dict[str, str]) -> str:
    if tags.get("aeroway") == "control_tower" or tags.get("tower:type") == "airport_control":
        return "control_tower"
    value = tags.get("aeroway") or tags.get("building", "")
    if value in ("terminal", "hangar"):
        return value
    return "other"


def building_height_m(tags: dict[str, str], kind: str, counters: dict[str, int]) -> float:
    height = parse_length_m(tags.get("height"))
    if height is not None:
        return height
    levels = parse_length_m(tags.get("building:levels"))
    if levels is not None:
        counters["building_height_from_levels"] += 1
        return levels * DEFAULT_LEVEL_HEIGHT_M
    counters["building_height_default"] += 1
    return DEFAULT_BUILDING_HEIGHT_M[kind]


def normalize(raw: dict[str, Any], icao: str) -> dict[str, Any]:
    elements = raw.get("elements", [])
    aerodromes = [e for e in elements if e.get("tags", {}).get("aeroway") == "aerodrome" and e.get("tags", {}).get("icao") == icao]
    if not aerodromes:
        raise AirportDataError(f"No aerodrome tagged icao={icao} in OpenStreetMap response")
    aerodrome = aerodromes[0]
    tags = aerodrome["tags"]
    elevation = parse_length_m(tags.get("ele"))
    if elevation is None:
        raise AirportDataError(f"{icao} has no 'ele' (elevation) tag in OpenStreetMap; cannot place the ground")

    boundary = outer_rings(aerodrome)
    if not boundary:
        raise AirportDataError(f"{icao} aerodrome has no closed boundary geometry")
    lats = [p[0] for ring in boundary for p in ring]
    lons = [p[1] for ring in boundary for p in ring]

    counters = {k: 0 for k in ("runway_width_default", "taxiway_width_default", "building_height_from_levels", "building_height_default")}
    runways, taxiways, aprons, buildings, gates, holding_points = [], [], [], [], [], []
    seen_buildings: set[tuple[str, int]] = set()

    for element in elements:
        etags = element.get("tags", {})
        aeroway = etags.get("aeroway")
        if element is aerodrome:
            continue
        if element["type"] == "way" and aeroway == "runway":
            points = way_points(element)
            if etags.get("area") == "yes" or len(points) < 2:
                continue
            width = parse_length_m(etags.get("width"))
            if width is None:
                counters["runway_width_default"] += 1
                width = DEFAULT_RUNWAY_WIDTH_M
            ref = etags.get("ref")
            if not ref or "/" not in ref:
                log.warning("Skipping runway way %s with no two-ended ref tag (%r)", element["id"], ref)
                continue
            runways.append({"ref": ref, "width_m": width, "surface": etags.get("surface", "asphalt"), "centerline": points})
        elif element["type"] == "way" and aeroway == "taxiway":
            points = way_points(element)
            if etags.get("area") == "yes" or len(points) < 2:
                continue
            width = parse_length_m(etags.get("width"))
            if width is None:
                counters["taxiway_width_default"] += 1
                width = DEFAULT_TAXIWAY_WIDTH_M
            taxiways.append({"ref": etags.get("ref", ""), "width_m": width, "centerline": points})
        elif aeroway == "apron" and element["type"] in ("way", "relation"):
            for ring in outer_rings(element):
                aprons.append({"outline": ring})
        elif aeroway in ("gate", "parking_position"):
            if element["type"] == "node":
                gates.append({"ref": etags.get("ref", ""), "position": [round(element["lat"], 7), round(element["lon"], 7)]})
            else:
                points = way_points(element)
                if points:
                    gates.append({"ref": etags.get("ref", ""), "position": points[0]})
        elif aeroway == "holding_position" and element["type"] == "node":
            holding_points.append({"ref": etags.get("ref", ""), "position": [round(element["lat"], 7), round(element["lon"], 7)]})

        if element["type"] != "node" and ("building" in etags or aeroway == "control_tower"):
            key = (element["type"], element["id"])
            if key in seen_buildings:
                continue
            seen_buildings.add(key)
            kind = building_kind(etags)
            height = building_height_m(etags, kind, counters)
            for ring in outer_rings(element):
                buildings.append({"kind": kind, "height_m": round(height, 2), "outline": ring})

    runways = merge_runway_pieces(runways)
    if not runways:
        raise AirportDataError(f"{icao} has no runway centerlines with ref tags in OpenStreetMap")

    for name, count in counters.items():
        if count:
            log.warning("Used a default for %s on %d feature(s)", name.replace("_", " "), count)
    log.info("%s: %d runways, %d taxiways, %d aprons, %d buildings, %d gates, %d holding points",
             icao, len(runways), len(taxiways), len(aprons), len(buildings), len(gates), len(holding_points))

    return {
        "icao": icao,
        "name": tags.get("name", icao),
        "attribution": "Map data © OpenStreetMap contributors, ODbL",
        "reference": {"latitude": round((min(lats) + max(lats)) / 2, 7),
                      "longitude": round((min(lons) + max(lons)) / 2, 7),
                      "elevation_m": elevation},
        "boundary": boundary,
        "runways": runways,
        "taxiways": taxiways,
        "aprons": aprons,
        "buildings": buildings,
        "gates": gates,
        "holding_points": holding_points,
        "defaults_used": counters,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("icao", help="ICAO airport code, for example KSFO")
    parser.add_argument("--out", required=True, help="Output JSON path")
    parser.add_argument("--overpass-url", default=OVERPASS_URL,
                        help="Overpass endpoint, e.g. https://overpass.kumi.systems/api/interpreter if the main one is busy")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="[fetch_airport] %(levelname)s %(message)s")
    icao = args.icao.upper()
    try:
        airport = normalize(fetch_overpass(icao, args.overpass_url), icao)
    except AirportDataError as exc:
        log.error("%s", exc)
        return 1
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(airport, handle, separators=(",", ":"))
    log.info("Wrote %s", args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
