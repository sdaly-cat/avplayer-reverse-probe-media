# avplayer-reverse-probe

Native iOS **sandbox** for testing whether `AVPlayer` plays our media **smoothly in reverse while
streaming** over a CDN on a real iPad. This is a throwaway feasibility spike, not production code.

- **Full context / pick-up brief:** see [`HANDOFF.md`](./HANDOFF.md) — open that first.
- **Test media** lives in this repo's [Releases](../../releases/tag/v1) (two synthetic clips,
  closed-GOP and open-GOP). The app streams them directly; nothing to download.

## Quick start

```bash
# 1. Regenerate the Xcode project only if you changed project.yml (it's already committed):
#    brew install xcodegen && xcodegen generate

# 2. Open it:
open ReverseProbe.xcodeproj
```

Then in Xcode:
1. Select the **ReverseProbe** target → **Signing & Capabilities** → tick *Automatically manage
   signing* and pick your **Team** (your Apple ID). Same no-TestFlight flow as Voltron's `ios:dev`.
2. Plug in the iPad, select it as the run destination, hit **▶ Run**.
3. Play forward, then tap **−1.0 / −0.5** and watch the burned-in **FRAME** counter tick *down* —
   smooth countdown = good, stutter/skips = jank.

## Switch closed-GOP ↔ open-GOP

In [`Sources/ProbeView.swift`](./Sources/ProbeView.swift), change `remoteURL` between
`ProbeView.closedGOP` and `ProbeView.openGOP`. The on-screen label always tells you which is loaded.

## Layout

| Path | What |
|---|---|
| `Sources/ReverseProbeApp.swift` | `@main` app entry |
| `Sources/ProbeView.swift` | the probe UI + AVPlayer logic + media URLs |
| `project.yml` | XcodeGen spec (source of truth for the project) |
| `ReverseProbe.xcodeproj` | generated, committed so you can clone-and-open |
| `HANDOFF.md` | the full brief: the question, how to read results, what's next |
