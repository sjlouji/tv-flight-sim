#!/usr/bin/env python3
"""Build the worldwide airport list the app uses for destinations and navigation.

Usage:
    python3 scripts/fetch_world_airports.py --out FlightSim/Resources/Airports/world.json

Source: OurAirports (https://ourairports.com/data/), released into the public domain.
Keeps airports with scheduled airline service and an ICAO code, and their open,
paved runways of at least 5,000 ft whose both ends have coordinates. Each runway
becomes two landing directions ("28L" and "10R"), each with its threshold position.
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import logging
import math
import sys
import urllib.request
from collections import Counter
from typing import Iterable

AIRPORTS_URL = "https://davidmegginson.github.io/ourairports-data/airports.csv"
RUNWAYS_URL = "https://davidmegginson.github.io/ourairports-data/runways.csv"
USER_AGENT = "tv-flight-sim/0.1 (personal flight simulator navigation data build)"

AIRPORT_TYPES = {"large_airport", "medium_airport"}
MIN_RUNWAY_LENGTH_FT = 5000
PAVED_PREFIXES = ("ASP", "CON", "PEM", "BIT", "TAR", "PAV", "MAC")
DEFAULT_RUNWAY_WIDTH_FT = 148.0  # 45 m, ICAO code letter E

log = logging.getLogger("fetch_world_airports")


class AirportDataError(Exception):
    """Raised when the source data is unusable."""


def download(url: str) -> str:
    log.info("Downloading %s", url)
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return response.read().decode("utf-8")
    except Exception as exc:
        log.error("Download of %s failed: %s", url, exc)
        raise


def parse_float(value: str | None) -> float | None:
    if value is None or value.strip() == "":
        return None
    try:
        return float(value)
    except ValueError:
        return None


def is_paved(surface: str) -> bool:
    return surface.strip().upper().startswith(PAVED_PREFIXES)


def bearing_degrees(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Initial great-circle bearing, degrees true."""
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dlon = math.radians(lon2 - lon1)
    y = math.sin(dlon) * math.cos(phi2)
    x = math.cos(phi1) * math.sin(phi2) - math.sin(phi1) * math.cos(phi2) * math.cos(dlon)
    return (math.degrees(math.atan2(y, x)) + 360) % 360


def runway_ends(row: dict[str, str], airport_elevation: float, defaults: Counter) -> list[dict]:
    """Both landing directions of one runway row, or [] if the row can't be used."""
    if row.get("closed") == "1":
        return []
    length = parse_float(row.get("length_ft"))
    if length is None or length < MIN_RUNWAY_LENGTH_FT or not is_paved(row.get("surface", "")):
        return []
    le = (parse_float(row.get("le_latitude_deg")), parse_float(row.get("le_longitude_deg")))
    he = (parse_float(row.get("he_latitude_deg")), parse_float(row.get("he_longitude_deg")))
    if None in le or None in he or not row.get("le_ident") or not row.get("he_ident"):
        defaults["runway_without_end_coordinates"] += 1
        return []
    width = parse_float(row.get("width_ft"))
    if width is None or width <= 0:
        width = DEFAULT_RUNWAY_WIDTH_FT
        defaults["runway_width_default"] += 1
    ends = []
    for prefix, here, there in (("le", le, he), ("he", he, le)):
        elevation = parse_float(row.get(f"{prefix}_elevation_ft"))
        if elevation is None:
            elevation = airport_elevation
            defaults["threshold_elevation_from_airport"] += 1
        # The heading is computed from the two thresholds so it always matches the geometry.
        ends.append({
            "id": row[f"{prefix}_ident"].strip(),
            "lat": round(here[0], 6),
            "lon": round(here[1], 6),
            "heading": round(bearing_degrees(here[0], here[1], there[0], there[1]), 2),
            "length_ft": round(length),
            "width_ft": round(width),
            "elevation_ft": round(elevation),
        })
    return ends


def normalize(airport_rows: Iterable[dict[str, str]], runway_rows: Iterable[dict[str, str]]) -> dict:
    defaults: Counter = Counter()
    candidates: dict[str, dict] = {}
    for row in airport_rows:
        icao = (row.get("icao_code") or row.get("gps_code") or "").strip().upper()
        if row.get("type") not in AIRPORT_TYPES or row.get("scheduled_service") != "yes":
            continue
        if len(icao) != 4 or not icao.isalpha():
            continue
        lat, lon = parse_float(row.get("latitude_deg")), parse_float(row.get("longitude_deg"))
        if lat is None or lon is None:
            continue
        elevation = parse_float(row.get("elevation_ft"))
        if elevation is None:
            elevation = 0.0
            defaults["airport_elevation_zero"] += 1
        candidates[row["ident"]] = {
            "icao": icao,
            "iata": (row.get("iata_code") or "").strip(),
            "name": row.get("name", "").strip(),
            "city": row.get("municipality", "").strip(),
            "country": row.get("iso_country", "").strip(),
            "lat": round(lat, 6),
            "lon": round(lon, 6),
            "elevation_ft": round(elevation),
            "runways": [],
        }
    for row in runway_rows:
        airport = candidates.get(row.get("airport_ident", ""))
        if airport is not None:
            airport["runways"].extend(runway_ends(row, airport["elevation_ft"], defaults))
    airports = sorted((a for a in candidates.values() if a["runways"]), key=lambda a: a["icao"])
    if not airports:
        raise AirportDataError("No airports survived filtering; the source format may have changed")
    for name, count in sorted(defaults.items()):
        log.warning("Default or skip applied %d times: %s", count, name)
    return {
        "attribution": "Airport data: OurAirports (public domain)",
        "airports": airports,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="[fetch_world_airports] %(levelname)s %(message)s")
    airports_csv = csv.DictReader(io.StringIO(download(AIRPORTS_URL)))
    runways_csv = csv.DictReader(io.StringIO(download(RUNWAYS_URL)))
    data = normalize(airports_csv, runways_csv)
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(data, handle, separators=(",", ":"), ensure_ascii=False)
    log.info("Wrote %d airports to %s", len(data["airports"]), args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
