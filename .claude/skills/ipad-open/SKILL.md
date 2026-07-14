---
name: ipad-open
description: Use when asked to open / run / launch / deploy the ReverseProbe app on the iOS Simulator, to test it there, or to read its debug console logs (probe launched, STREAM ready, canPlayReverse, orientation, seek). Also on the phrase "ipad-open". Simulator only for now — physical iPad not wired up yet.
---

# ipad-open

## Overview
Builds the ReverseProbe app, installs it on the iOS Simulator, launches it, and captures its
`os_log` output so you (Claude) can read the app's debug console directly. One command does the
whole build → install → launch → log-capture loop.

**Simulator only.** `xcrun simctl` does not target physical devices; on-device install + log
capture is not built yet. (The Simulator decodes on the Mac and does NOT predict real-iPad reverse
smoothness — see HANDOFF.md — so use it for the dev loop, not for the reverse-playback verdict.)

## Do this
Run the harness (it boots the iPad sim if needed, builds, installs, launches, captures logs, prints them):
```bash
/Users/sean.daly/repos/avplayer-reverse-probe-media/scripts/run-sim.sh
```
- Longer capture window: `CAPTURE_SECONDS=15 .../run-sim.sh`
- Target a specific sim: `.../run-sim.sh <device-udid>`
- Full capture is also written to `build/probe-sim.log`.

Run it in the background (cold builds take a bit) and read the output file, per this repo's usual flow.

## Reading the logs
The app logs under subsystem **`com.catapult.ReverseProbe`** (category `probe`), all interpolations
`.public` so nothing is redacted. Key lines: `probe launched`, `STREAM ready — canPlayReverse=… slow=… fast=… duration=…`,
`connectivity: status=…`, `orientation: … isLandscape=…`, `layout: … size=…`, `seek to …s`, and any `item FAILED`.

For **live** debugging while you drive the app (not just the one-shot snapshot), stream continuously
with a Monitor:
```bash
xcrun simctl spawn booted log stream --level debug --style compact \
  --predicate 'subsystem == "com.catapult.ReverseProbe"'
```

## Gotchas
- **`simctl … screenshot` does not reflect app orientation** on this iPadOS-26 sim (writes the native
  portrait panel). Trust the `orientation:`/`layout:` log lines over a screenshot.
- **Hot-relaunch in portrait can render rotated** — the app calls `requestGeometryUpdate(.landscape)`
  on launch to snap the sim to landscape; if it still looks rotated, reboot the sim.
- Pipe a `\| grep`/`\| tail` and the harness's output file stays empty until it exits — read
  `build/probe-sim.log` or the raw task output instead.
