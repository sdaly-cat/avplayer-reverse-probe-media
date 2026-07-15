---
name: ipad-open
description: Use when asked to open / run / launch / deploy the ReverseProbe app on the iOS Simulator OR a cabled physical iPad, to test it, or to read its debug console logs (probe launched, STREAM ready, canPlayReverse, orientation, seek). Also on the phrase "ipad-open".
---

# ipad-open

## Overview
Builds ReverseProbe, deploys it, launches it, and captures its debug log lines so you (Claude) can
read the app's console directly. Two targets — pick by what's asked:

- **Simulator** → `scripts/run-sim.sh`  (fast dev loop; NOT representative of real-iPad decode)
- **Physical iPad** → `scripts/run-device.sh`  (real hardware; the reverse-playback verdict lives here)

The app logs to BOTH os_log and stdout (`Probe.log`), so the same lines are readable on either target.

## Simulator
```bash
/Users/sean.daly/repos/avplayer-reverse-probe-media/scripts/run-sim.sh      # build→install→launch→capture
```
- `CAPTURE_SECONDS=15 …` longer window · `… <udid>` target a specific sim · full log at `build/probe-sim.log`.
- Logs captured via the unified log: `xcrun simctl spawn booted log stream --predicate 'subsystem == "com.catapult.ReverseProbe"'`.
- For **live** debugging while you drive it, run that `log stream` under a Monitor.

## Physical iPad
```bash
/Users/sean.daly/repos/avplayer-reverse-probe-media/scripts/run-device.sh   # build(generic)→devicectl install→launch --console
```
- **One-time setup:** `cp scripts/device.local.sh.example scripts/device.local.sh` and fill in your
  `DEVELOPMENT_TEAM` + a personal `DEV_BUNDLE_ID` (`com.<you>.*`). That file is **gitignored** (this repo
  is public — keep team id / bundle / UDIDs local).
- **iPad must be UNLOCKED, awake, and trusted** — install/launch need it; the build does not.
- Logs stream over the cable via **stdout** (`devicectl … process launch --console`), because the unified
  log isn't reachable over USB here (`log stream`/`log collect` have no `--device`, no `idevicesyslog`).
  The launch blocks and streams until the app quits or you kill it; full log also at `build/probe-device.log`.
  Run it in the background and read the task output / logfile to watch live.

## Reading the logs
Subsystem/tag **`com.catapult.ReverseProbe`** (device lines are prefixed `[probe]`). Key lines:
`probe launched`, `STREAM ready — canPlayReverse=… slow=… fast=… duration=…`, `connectivity: status=…`,
`orientation: … isLandscape=…`, `layout: … size=…`, `seek to …s`, any `item FAILED`.

## Gotchas
- **Signing:** sign the device build under a **personal** team + `com.<you>.*` bundle id. The org
  `com.catapult.*` namespace routes to an org Apple account that may have no valid session here and fails
  auto-provisioning; the personal namespace avoids it. No Xcode UI needed once that Apple ID is valid.
- **`simctl … screenshot` does not reflect app orientation** on the iPadOS-26 sim — trust the
  `orientation:`/`layout:` log lines over a screenshot.
- **Hot-relaunch in portrait can render rotated** — the app calls `requestGeometryUpdate(.landscape)` on
  launch; if it still looks rotated, reboot the sim.
- Piping the harness through `| grep`/`| tail` keeps its output buffered until it exits — read the
  `build/probe-*.log` file (or raw task output) instead.
