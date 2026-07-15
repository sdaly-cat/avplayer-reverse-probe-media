#!/usr/bin/env bash
#
# run-device.sh — build ReverseProbe SIGNED for a cabled physical iPad, install it with devicectl,
# and launch it with the console attached so the app's stdout (our Probe.log/print lines) streams
# back here. The physical-device counterpart of run-sim.sh.
#
# WHY stdout and not os_log: over the cable the unified log isn't reachable with the tooling on this
# machine (`log stream`/`log collect` have no --device; no idevicesyslog). `devicectl process launch
# --console` DOES forward the process's stdout/stderr — so the app mirrors every log line to print()
# and we read those here.
#
# SIGNING: device signing/bundle-id/UDIDs are PERSONAL and this repo is public, so they live in a
# gitignored scripts/device.local.sh (copy scripts/device.local.sh.example). We sign under a personal
# team + a com.<you>.* bundle id — the org (com.catapult.*) namespace routes to an org Apple account
# that isn't valid here. Auto-provisioning needs a valid Apple ID session in Xcode for that team.
#
# USAGE
#   scripts/run-device.sh            # build (generic iOS) → install → launch, streaming the console
#   scripts/run-device.sh autopilot  # same, but pass -autopilot so the app self-drives a validation run
#   (config via scripts/device.local.sh; DEVELOPMENT_TEAM / DEV_BUNDLE_ID can also be passed as env)
#
# The console streams until the app exits or this process is killed. Run it in the background and read
# the task output (or build/probe-device.log) to watch logs live. The iPad must be UNLOCKED + trusted.

set -euo pipefail

REPO="/Users/sean.daly/repos/avplayer-reverse-probe-media"
PROJECT="$REPO/ReverseProbe.xcodeproj"
SCHEME="ReverseProbe"

# --- Load personal config -----------------------------------------------------
[[ -f "$REPO/scripts/device.local.sh" ]] && source "$REPO/scripts/device.local.sh"
TEAM="${DEVELOPMENT_TEAM:-}"
BUNDLE_ID="${DEV_BUNDLE_ID:-}"
if [[ -z "$TEAM" || -z "$BUNDLE_ID" ]]; then
  echo "!! Missing signing config. Create scripts/device.local.sh from scripts/device.local.sh.example"
  echo "   (set DEVELOPMENT_TEAM and DEV_BUNDLE_ID), then re-run."
  exit 1
fi

# --- Resolve the device (auto-detect first paired iPad if not pinned) ---------
CTL_ID="${DEVICE_CTL_ID:-}"
if [[ -z "$CTL_ID" ]]; then
  CTL_ID="$(xcrun devicectl list devices 2>/dev/null | awk -F'  +' '/iPad|iPhone/ && /paired/ {print $3; exit}')"
fi
[[ -n "$CTL_ID" ]] || { echo "!! No paired device found (xcrun devicectl list devices)"; exit 1; }
echo ">> Device (devicectl): $CTL_ID"

DERIVED="$REPO/build/DerivedData-device"
LOGFILE="$REPO/build/probe-device.log"
mkdir -p "$REPO/build"

# --- 1. Build SIGNED for a generic iOS device --------------------------------
# generic/platform=iOS decouples the BUILD from the device being awake/mounted (avoids the
# "developer disk image could not be mounted" timeout). devicectl handles the device for install/launch.
echo ">> Building signed (team $TEAM, bundle $BUNDLE_ID)…"
xcodebuild \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  build \
  > "$REPO/build/xcodebuild-device.log" 2>&1 \
  || { echo "!! Build/sign failed — tail of build/xcodebuild-device.log:"; tail -40 "$REPO/build/xcodebuild-device.log"; exit 1; }

APP="$DERIVED/Build/Products/Debug-iphoneos/ReverseProbe.app"
[[ -d "$APP" ]] || { echo "!! Built app not found at $APP"; exit 1; }
echo ">> Built: $APP"

# --- 2. Install (device must be unlocked + trusted) --------------------------
echo ">> Installing on device…"
xcrun devicectl device install app --device "$CTL_ID" "$APP"

# --- 3. Launch with console (streams stdout → our print() lines) -------------
# Optional first arg `autopilot` appends the -autopilot launch argument (devicectl forwards trailing
# args to the app's argv, which ProcessInfo.arguments reads).
# `--` stops devicectl's own option parsing so leading-dash args pass through to the app's argv
# (otherwise `-autopilot` is misread as a devicectl flag → "Missing value for '-t'").
LAUNCH_ARGS=()
if [[ "${1:-}" == "autopilot" ]]; then
  LAUNCH_ARGS+=("--" "-autopilot")
  echo ">> AUTOPILOT: passing -autopilot launch arg (app will self-drive a validation run)"
fi
echo ">> Launching with console attached (stdout streams below; kill to stop)…"
: > "$LOGFILE"
xcrun devicectl device process launch --console --terminate-existing \
  --device "$CTL_ID" "$BUNDLE_ID" ${LAUNCH_ARGS[@]+"${LAUNCH_ARGS[@]}"} 2>&1 | tee "$LOGFILE"
