#!/usr/bin/env bash
#
# run-sim.sh — build ReverseProbe, install it on an iOS Simulator, launch it, and
# capture the app's unified-log output so it can be read back from the host.
#
# This is a PLUMBING-VALIDATION harness: it proves the debug-console channel works.
# (The Simulator decodes on the Mac and does NOT predict real-iPad reverse smoothness
# — see HANDOFF.md. Use a cabled iPad for the actual feasibility answer.)
#
# Usage:
#   scripts/run-sim.sh                # use first booted sim, or boot the default iPad
#   scripts/run-sim.sh <device-udid>  # target a specific simulator by UDID
#   CAPTURE_SECONDS=8 scripts/run-sim.sh
#
# Reads back: prints the captured probe log lines to stdout and leaves the full
# capture at build/probe-sim.log.

set -euo pipefail

# --- Config (absolute paths; this script must not depend on CWD) ---------------
REPO="/Users/sean.daly/repos/avplayer-reverse-probe-media"
PROJECT="$REPO/ReverseProbe.xcodeproj"
SCHEME="ReverseProbe"
BUNDLE_ID="com.catapult.ReverseProbe"
SUBSYSTEM="com.catapult.ReverseProbe"
DEFAULT_DEVICE="iPad Pro 13-inch (M5)"
DERIVED="$REPO/build/DerivedData"
LOGFILE="$REPO/build/probe-sim.log"
CAPTURE_SECONDS="${CAPTURE_SECONDS:-8}"

mkdir -p "$REPO/build"

# --- 1. Resolve the target simulator UDID --------------------------------------
UDID="${1:-}"
if [[ -z "$UDID" ]]; then
  UDID="$(xcrun simctl list devices booted -j \
    | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; ids=[x["udid"] for v in d.values() for x in v if x.get("state")=="Booted"]; print(ids[0] if ids else "")')"
fi
if [[ -z "$UDID" ]]; then
  echo ">> No booted simulator; booting \"$DEFAULT_DEVICE\"…"
  UDID="$(xcrun simctl list devices available -j \
    | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin)['devices']; ids=[x['udid'] for v in d.values() for x in v if x['name']=='$DEFAULT_DEVICE']; print(ids[0] if ids else '')")"
  [[ -z "$UDID" ]] && { echo "!! Could not find device named '$DEFAULT_DEVICE'"; exit 1; }
fi
echo ">> Target simulator UDID: $UDID"

# --- 2. Boot it + open the Simulator UI ----------------------------------------
open -a Simulator
xcrun simctl bootstatus "$UDID" -b   # boots if needed and waits until ready

# --- 3. Build for the simulator ------------------------------------------------
echo ">> Building (this can take a bit on a cold build)…"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "id=$UDID" \
  -derivedDataPath "$DERIVED" \
  build \
  > "$REPO/build/xcodebuild.log" 2>&1 \
  || { echo "!! Build failed — tail of build/xcodebuild.log:"; tail -30 "$REPO/build/xcodebuild.log"; exit 1; }

APP="$DERIVED/Build/Products/Debug-iphonesimulator/ReverseProbe.app"
[[ -d "$APP" ]] || { echo "!! Built app not found at $APP"; exit 1; }
echo ">> Built: $APP"

# --- 4. Install ----------------------------------------------------------------
xcrun simctl install "$UDID" "$APP"
echo ">> Installed $BUNDLE_ID"

# --- 5. Start capturing the unified log (background), then launch ---------------
: > "$LOGFILE"
xcrun simctl spawn "$UDID" log stream \
  --level debug --style compact \
  --predicate "subsystem == \"$SUBSYSTEM\"" \
  >> "$LOGFILE" 2>&1 &
STREAM_PID=$!
# give the stream a moment to attach before the app emits its launch line
sleep 1

echo ">> Launching app…"
xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null

echo ">> Capturing logs for ${CAPTURE_SECONDS}s…"
sleep "$CAPTURE_SECONDS"

kill "$STREAM_PID" 2>/dev/null || true
wait "$STREAM_PID" 2>/dev/null || true

# --- 6. Report -----------------------------------------------------------------
echo ">> ===== captured probe log ($LOGFILE) ====="
if [[ -s "$LOGFILE" ]]; then
  cat "$LOGFILE"
else
  echo "(no lines captured — subsystem '$SUBSYSTEM' produced no output in the window)"
fi
echo ">> ===== end ====="
