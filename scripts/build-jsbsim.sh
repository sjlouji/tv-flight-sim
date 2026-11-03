#!/usr/bin/env bash
# Builds JSBSim (LGPL-2.1) as a static XCFramework for Apple TV devices and the
# Apple TV simulator, and copies the aircraft data files the app bundles.
#
# JSBSim's own CMake build cannot cross-compile for tvOS because it also builds
# command-line executables, so this script compiles the library sources directly.
#
# Output:
#   Vendor/JSBSim.xcframework   static library + headers
#   Vendor/jsbsim-data/         aircraft, engine and systems XML used at runtime
set -euo pipefail

JSBSIM_TAG="v1.3.3"
JSBSIM_VERSION="1.3.3"
DEPLOYMENT_TARGET="26.0"
# The aircraft the app offers, and the engine and thruster files they use from the shared engine folder.
AIRCRAFT=("737" "B747" "787-8" "A320" "C130" "c172p" "DHC6" "global5000" "F4N")
ENGINES=("CFM56" "direct" "GE-CF6-80C2-B1F" "trent_1000" "CFM56_5" "t56" "eng_io320" "prop_75in2f" "BR710")

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
WORK="$VENDOR/.build-jsbsim"
SRC_REPO="$WORK/jsbsim"

log() { printf '[build-jsbsim] %s\n' "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }

mkdir -p "$WORK"
if [[ ! -d "$SRC_REPO/.git" ]]; then
  log "Cloning JSBSim $JSBSIM_TAG"
  git clone --quiet --depth 1 --branch "$JSBSIM_TAG" https://github.com/JSBSim-Team/jsbsim.git "$SRC_REPO" \
    || fail "git clone of JSBSim $JSBSIM_TAG failed"
fi
SRC="$SRC_REPO/src"

# Library sources: every C/C++ file under src except the command-line programs,
# the MSIS self-test, Expat files that are #included by other files, and the
# trim-analysis files JSBSim's own CMake build leaves out.
EXCLUDES=(
  "JSBSim.cpp" "JSBSim.minimal.cpp"
  "models/atmosphere/MSIS/nrlmsise-00_test.c"
  "simgear/xml/xmltok_impl.c" "simgear/xml/xmltok_ns.c"
  "initialization/FGSimplexTrim.cpp" "initialization/FGTrimAnalysis.cpp"
  "initialization/FGTrimAnalysisControl.cpp" "initialization/FGTrimmer.cpp"
  "math/FGNelderMead.cpp"
)
SOURCES=()
while IFS= read -r file; do
  rel="${file#"$SRC"/}"
  skip=false
  for ex in "${EXCLUDES[@]}"; do [[ "$rel" == "$ex" ]] && skip=true && break; done
  $skip || SOURCES+=("$rel")
done < <(find "$SRC" \( -name '*.cpp' -o -name '*.cxx' -o -name '*.c' \) | sort)
log "Compiling ${#SOURCES[@]} source files per platform"

build_slice() {
  local sdk="$1"
  local target="$2"
  local out="$WORK/$sdk"
  local sysroot
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  rm -rf "$out" && mkdir -p "$out/obj"
  log "Building slice $sdk ($target)"
  # NDEBUG: JSBSim's internal asserts would abort the app; the flight model checks the state itself instead.
  local common=(-target "$target" -isysroot "$sysroot" -O2 -fPIC -DNDEBUG -I "$SRC" -DJSBSIM_VERSION="\"$JSBSIM_VERSION\"" -w)
  printf '%s\n' "${SOURCES[@]}" | xargs -P "$(sysctl -n hw.ncpu)" -I{} sh -c '
    rel="$1"; shift; out="$1"; shift; src="$1"; shift
    obj="$out/obj/$(echo "$rel" | tr "/" "_").o"
    case "$rel" in
      *.c) xcrun clang -std=c11 "$@" -c "$src/$rel" -o "$obj" ;;
      *)   xcrun clang++ -std=c++17 -stdlib=libc++ "$@" -c "$src/$rel" -o "$obj" ;;
    esac || { echo "[build-jsbsim] ERROR: failed to compile $rel" >&2; exit 255; }
  ' _ {} "$out" "$SRC" "${common[@]}" || fail "compilation failed for $sdk"
  xcrun libtool -static -o "$out/libJSBSim.a" "$out"/obj/*.o 2>/dev/null || fail "libtool failed for $sdk"
}

build_slice appletvos "arm64-apple-tvos$DEPLOYMENT_TARGET"
build_slice appletvsimulator "arm64-apple-tvos$DEPLOYMENT_TARGET-simulator"

log "Collecting headers"
HEADERS="$WORK/include"
rm -rf "$HEADERS" && mkdir -p "$HEADERS"
rsync -a --include='*/' --include='*.h' --include='*.hxx' --include='*.hpp' --exclude='*' "$SRC/" "$HEADERS/"

log "Creating XCFramework"
rm -rf "$VENDOR/JSBSim.xcframework"
xcodebuild -create-xcframework \
  -library "$WORK/appletvos/libJSBSim.a" -headers "$HEADERS" \
  -library "$WORK/appletvsimulator/libJSBSim.a" -headers "$HEADERS" \
  -output "$VENDOR/JSBSim.xcframework" >/dev/null || fail "xcodebuild -create-xcframework failed"

log "Copying aircraft data"
DATA="$VENDOR/jsbsim-data"
rm -rf "$DATA" && mkdir -p "$DATA/aircraft" "$DATA/engine" "$DATA/systems"
for a in "${AIRCRAFT[@]}"; do cp -R "$SRC_REPO/aircraft/$a" "$DATA/aircraft/"; done
for e in "${ENGINES[@]}"; do cp "$SRC_REPO/engine/$e.xml" "$DATA/engine/"; done
# Shared systems (autopilot, carrier catapult and hook, fighter control laws) some aircraft include.
cp "$SRC_REPO"/systems/*.xml "$DATA/systems/"
cp "$SRC_REPO/COPYING" "$DATA/COPYING-JSBSim-LGPL.txt"
# JSBSim's C-130 pairs a jet-style turbine engine (whose output is thrust) with a propeller thruster (whose
# input is shaft power), so each engine makes almost no thrust and the aircraft cannot fly level. A direct
# thruster applies the engine's own thrust tables, which already model the propeller's fall-off with speed.
sed -i '' 's|<thruster file="t56_prop">|<thruster file="direct">|' "$DATA/aircraft/C130/C130.xml"
grep -q 't56_prop' "$DATA/aircraft/C130/C130.xml" && fail "C130 thruster patch did not apply"

log "Done: $VENDOR/JSBSim.xcframework and $DATA"
