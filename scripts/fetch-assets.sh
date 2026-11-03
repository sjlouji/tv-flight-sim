#!/usr/bin/env bash
# Downloads the CC0 (public domain) surface textures the app bundles. (The sky is computed, not downloaded.)
#
#   Surfaces:  ambientCG Asphalt033, Concrete034, Grass004  https://ambientcg.com  (all CC0)
#
# Downloads land in Vendor/.downloads (one folder per archive); only the image
# files the app uses are copied into FlightSim/Resources.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOWNLOADS="$ROOT/Vendor/.downloads"
TEXTURES="$ROOT/FlightSim/Resources/Textures"
# ambientCG asset id -> name used in the app
MATERIALS=("Asphalt033:asphalt" "Concrete034:concrete" "Grass004:grass")

log() { printf '[fetch-assets] %s\n' "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }

download() {
  local url="$1" dest="$2"
  if [[ -s "$dest" ]]; then log "Already downloaded $(basename "$dest")"; return; fi
  log "Downloading $url"
  curl -fsSL --retry 3 --max-time 600 -o "$dest.part" "$url" || fail "download failed: $url"
  mv "$dest.part" "$dest"
}

mkdir -p "$DOWNLOADS" "$TEXTURES"

for entry in "${MATERIALS[@]}"; do
  asset="${entry%%:*}"
  name="${entry##*:}"
  zip="$DOWNLOADS/${asset}_2K-JPG.zip"
  download "https://ambientcg.com/get?file=${asset}_2K-JPG.zip" "$zip"
  dir="$DOWNLOADS/$asset"
  rm -rf "$dir" && mkdir -p "$dir"
  unzip -q -o "$zip" -d "$dir" || fail "could not unzip $zip"
  for map in Color:color NormalGL:normal Roughness:roughness; do
    suffix="${map%%:*}"
    target="${map##*:}"
    src="$dir/${asset}_2K-JPG_${suffix}.jpg"
    [[ -f "$src" ]] || fail "missing $src in $zip"
    cp "$src" "$TEXTURES/${name}_${target}.jpg"
  done
done

cat > "$ROOT/FlightSim/Resources/CREDITS.txt" <<'EOF'
Map data © OpenStreetMap contributors, available under the Open Database License (ODbL).
Airport list: OurAirports (ourairports.com), public domain.
Surface textures: Asphalt033, Concrete034, Grass004 by ambientCG (ambientcg.com), CC0.
Flight dynamics: JSBSim (LGPL-2.1). Boeing 737 flight model by Dave Culp / Aeromatic, distributed with JSBSim.
EOF

log "Done"
