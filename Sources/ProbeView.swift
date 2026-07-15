import SwiftUI
import AVKit
import AVFoundation
import os

/// Structured log channel for the probe. Emits to BOTH:
///   • os_log (subsystem com.catapult.ReverseProbe) — read on the Simulator via
///     `xcrun simctl spawn booted log stream --predicate 'subsystem == "com.catapult.ReverseProbe"'`
///   • stdout via print() — read on a PHYSICAL DEVICE via `devicectl device process launch --console`
///     (the unified log isn't reachable over the cable with the available tooling, but stdout is).
enum Probe {
    private static let logger = Logger(subsystem: "com.catapult.ReverseProbe", category: "probe")
    static func log(_ msg: String) {
        logger.log("\(msg, privacy: .public)")
        print("[probe] \(msg)")
    }
    static func error(_ msg: String) {
        logger.error("\(msg, privacy: .public)")
        print("[probe][error] \(msg)")
    }
}

/// Feasibility probe for native AVPlayer reverse playback while STREAMING over a CDN.
/// See HANDOFF.md for the full "what is this / what question does it answer" brief.
struct ProbeView: View {
    @State private var player = AVPlayer()
    @State private var status = "idle"
    @State private var reverseFlags = "reverse flags: (waiting)"
    @State private var timeText = "t = 0.00"
    @State private var timeObserver: Any?
    @State private var currentSeconds: Double = 0     // playhead, mirrored to the seek slider
    @State private var durationSeconds: Double = 0     // item duration (0 until known)
    @State private var isScrubbing = false             // true while dragging the slider
    @State private var isSeekInProgress = false         // a scrub seek is mid-flight
    @State private var pendingSeekTarget: Double? = nil // latest requested scrub position
    @State private var isPlaying = false                // drives the play/pause toggle icon
    @State private var clipIndex = 0                    // which entry of `clips` is loaded
    @State private var trickPlay = false                // mode switch: false = native rate, true = seek loop
    @State private var trickTimer: Timer?               // drives trick playback (nil when not trick-playing)
    @State private var playLocal = false                // source toggle: false = stream, true = downloaded local file
    @State private var localFiles: [Int: URL] = [:]     // clipIndex -> downloaded local file (once fetched)
    @State private var isDownloading = false            // a download is in flight (disables the button)

    // Thundercloud's FULL_RES_REWIND_RATE — the -0.5 threshold that splits its trick-timer cadence ladder.
    private static let fullResRewindRate = -0.5

    // The on-disk copy of the current clip, if it's been downloaded.
    private var currentLocalFile: URL? { localFiles[clipIndex] }

    /// Stable on-disk home for downloaded clips. Application Support survives relaunch (unlike
    /// temporaryDirectory, which iOS may purge) and is the correct place for app-managed files.
    private static func downloadsDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Deterministic path for a clip's local copy, so the same clip always maps to the same file and
    /// its presence can be detected across relaunches.
    private static func localPath(for idx: Int) -> URL {
        downloadsDir().appendingPathComponent("probe-\(idx).mp4")
    }

    // MARK: - Test media (synthetic, hosted on this repo's GitHub Releases)
    // Both are 1920x1080, 59.94fps, H.264 High@4.2, progressive, GOP-30, 12 Mbps CBR, ~180s.
    // They differ ONLY in GOP structure. The burned-in on-screen label says CLOSED or OPEN.
    static let closedGOP = URL(string: "https://github.com/sdaly-cat/avplayer-reverse-probe-media/releases/download/v1/synthetic_ball_1080p_5994fps_3min_closedgop.mp4")!
    static let openGOP   = URL(string: "https://github.com/sdaly-cat/avplayer-reverse-probe-media/releases/download/v1/synthetic_ball_1080p_5994fps_3min_opengop.mp4")!

    // Available clips — pick from the on-screen "Stream" menu. Add entries here and they show up in
    // the menu automatically. (Open GOP is the harder, more representative case.)
    static let clips: [(name: String, url: URL)] = [
        ("Closed GOP", closedGOP),
        ("Open GOP",   openGOP),
    ]
    private var remoteURL: URL { Self.clips[clipIndex].url }

    // Fixed label width for every transport button so they're uniform (sized for the widest, "-10")
    // and bigger than content-hugging would make them.
    private let rateButtonWidth: CGFloat = 40

    var body: some View {
        VStack(spacing: 10) {
            // Fill all vertical space left over by the compact control cluster below.
            // Our own controls (seek bar + rate buttons) drive playback, so the default AVKit
            // transport overlay is suppressed — it was popping up over the video and getting in the way.
            PlayerSurface(player: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(status).font(.footnote)
            Text(reverseFlags).font(.footnote).foregroundColor(.secondary)
            Text(timeText).font(.system(.footnote, design: .monospaced))
            // Seek slider — drag to scrub/seek to a position. `isScrubbing` stops the periodic
            // time observer from fighting the drag; the seek is issued on release.
            HStack(spacing: 10) {
                Text(timeLabel(currentSeconds)).font(.system(.caption2, design: .monospaced))
                SeekBar(
                    current: currentSeconds,
                    duration: durationSeconds,
                    onScrub: { s in isScrubbing = true; stopTrickPlayback(); isPlaying = false; currentSeconds = s; scrubSeek(to: s) },
                    onCommit: { s in currentSeconds = s; isScrubbing = false; seek(to: s) }
                )
                Text(timeLabel(durationSeconds)).font(.system(.caption2, design: .monospaced))
            }
            HStack(spacing: 6) {
                ForEach([-10.0, -8.0, -6.0, -4.0, -2.0, -1.0, -0.5, 0.0, 0.5, 1.0, 2.0, 4.0, 6.0, 8.0, 10.0], id: \.self) { r in
                    if r == 0 {
                        // Real play/pause toggle: pause from any rate, resume at 1× when paused.
                        Button {
                            togglePlayPause()
                        } label: {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill").frame(width: rateButtonWidth)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button { setRate(Float(r)) } label: {
                            Text(rateTitle(r)).frame(width: rateButtonWidth)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .controlSize(.large)
            HStack(spacing: 12) {
                Menu {
                    ForEach(Array(Self.clips.enumerated()), id: \.offset) { idx, clip in
                        Button(clip.name) { clipIndex = idx; playLocal = false; loadSource(resumeAt: nil) }
                    }
                } label: {
                    Label(Self.clips[clipIndex].name, systemImage: "chevron.down.circle")
                }
                .buttonStyle(.borderedProminent)
                // Download the current clip to disk. Once it's local, the Source toggle can flip to it.
                Button {
                    downloadCurrent()
                } label: {
                    Label(isDownloading ? "Downloading…" : (currentLocalFile != nil ? "Downloaded" : "Download"),
                          systemImage: currentLocalFile != nil ? "checkmark.circle.fill" : "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .disabled(isDownloading || currentLocalFile != nil)   // no pointless re-download
                // Source: Stream ⟷ Local. Enabled only once the current clip has been downloaded.
                Toggle("Local", isOn: $playLocal)
                    .toggleStyle(.switch)
                    .fixedSize()
                    .disabled(currentLocalFile == nil)
                    .help("Off = stream over HTTPS byte-range. On = play the downloaded local file.")
                Toggle("Trick play", isOn: $trickPlay)
                    .toggleStyle(.switch)
                    .fixedSize()
                    .help("Off = native player.rate. On = Thundercloud-style seek loop for every rate.")
            }
        }
        .onChange(of: playLocal) { _ in   // flip source in place, keeping the current playhead for A/B
            loadSource(resumeAt: currentSeconds)
        }
        .onChange(of: trickPlay) { on in   // single-arg form for iOS 16 (two-arg onChange is iOS 17+)
            // Flipping the mode stops any running loop and parks the player (native rate 0), so the
            // next button press starts cleanly in the newly-selected mode.
            stopTrickPlayback()
            player.rate = 0
            isPlaying = false
            status = on ? "trick play ON (seek loop)" : "trick play OFF (native rate)"
            Probe.log("mode → \(on ? "TRICK (seek loop)" : "NATIVE rate")")
        }
        .padding()
        .background(
            GeometryReader { proxy in
                Color.clear.onAppear {
                    Probe.log("layout: SwiftUI content size=\(Int(proxy.size.width))x\(Int(proxy.size.height))")
                }
            }
        )
        .onAppear {
            Probe.log("probe launched — remoteURL=\(remoteURL.absoluteString)")
            forceLandscape()
            probeConnectivity()
            installTimeObserver()
            restoreDownloads()
            loadSource(resumeAt: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { logOrientation() }
            // Self-drive when launched with -autopilot (passed via `devicectl … launch … -autopilot`,
            // e.g. `scripts/run-device.sh autopilot`) so the source/rate/mode paths can be validated
            // from the logs alone, no on-screen taps required.
            if ProcessInfo.processInfo.arguments.contains("-autopilot") {
                Probe.log("AUTOPILOT: enabled via launch arg")
                runAutopilot()
            }
        }
        .preferredColorScheme(.dark)   // black background; default (black) text flips to light so none of it vanishes
    }

    /// A numbered rate button was pressed. Obeys the mode switch: NATIVE sets `player.rate`; TRICK runs
    /// the Thundercloud seek loop at that rate (forward OR reverse). The play/pause button does NOT go
    /// through here — it's always native (see togglePlayPause).
    /// Log a transport button press with everything the probe cares about: the rate, the active
    /// source (streaming vs the downloaded local file), and the playback mode (native vs trick).
    private func logButtonPress(rate: Float) {
        let source = (playLocal && currentLocalFile != nil) ? "LOCAL" : "STREAM"
        let mode = trickPlay ? "TRICK (seek loop)" : "NATIVE (player.rate)"
        Probe.log("BUTTON → rate=\(rate)  source=\(source)  mode=\(mode)")
    }

    func setRate(_ r: Float) {
        logButtonPress(rate: r)
        if trickPlay {
            startTrickPlayback(rate: Double(r))
            status = "trick rate = \(r) (seek loop)"
        } else {
            stopTrickPlayback()
            player.rate = r        // negative = reverse (requires item.canPlayReverse)
            status = "rate = \(r) (native)"
        }
        isPlaying = (r != 0)
    }

    // MARK: - Trick playback (Thundercloud seek loop)
    // Native rate is pinned to 0; a repeating timer seeks by (interval × rate) each tick, so the clip
    // advances/rewinds via discrete seeks instead of the decoder's native (backward) playback. This is
    // the exact fallback path Thunder Cloud uses for cached/streaming clips (XOSVideoController.m).

    func startTrickPlayback(rate: Double) {
        stopTrickPlayback()
        guard rate != 0 else { return }
        player.rate = 0   // we drive the timeline by seeking, not by native rate

        // Timer cadence ladder, verbatim from Thundercloud's startTrickPlayback:.
        let interval: TimeInterval =
            rate > 0                       ? 0.1  :   // forward
            rate > Self.fullResRewindRate  ? 0.2  :   // slow reverse (−0.5 < rate < 0)
            rate < Self.fullResRewindRate  ? 0.1  :   // fast reverse (< −0.5)
                                             0.15     // normal reverse (== −0.5)
        Probe.log("trick play START rate=\(rate) interval=\(interval)s jump/tick=\(interval * rate)s")

        trickTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            let jump = timer.timeInterval * rate                     // seconds to advance this tick
            let target = CMTimeGetSeconds(player.currentTime()) + jump
            // Thundercloud's asymmetric tolerance: allow landing slightly in the direction of travel.
            let tol = CMTime(seconds: 0.1, preferredTimescale: 1000)
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                        toleranceBefore: rate < 0 ? tol : .zero,
                        toleranceAfter:  rate > 0 ? tol : .zero)
        }
    }

    func stopTrickPlayback() {
        trickTimer?.invalidate()
        trickTimer = nil
    }

    // MARK: - Autopilot (self-driving validation, launched with -autopilot)
    // Drives a deterministic sequence through every source/rate/mode path and logs each transition
    // with the observed state, so a log read alone confirms behaviour without any on-screen taps.
    // NOTE: it exercises the LOGIC, not literal touches — a purely visual/layout glitch won't show up.

    /// Log the step (with current observed state) then run its action.
    private func autopilotStep(_ label: String, _ block: () -> Void) {
        let observed = String(format: "t=%.2f rate=%.2f trick=%@ local=%@",
                              currentSeconds, player.rate,
                              trickTimer != nil ? "on" : "off",
                              playLocal ? "on" : "off")
        Probe.log("AUTOPILOT: \(label) [observed \(observed)]")
        block()
    }

    /// Schedule an autopilot step `seconds` from now.
    private func autopilotAfter(_ seconds: Double, _ label: String, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { autopilotStep(label, block) }
    }

    /// Poll once a second (up to `triesLeft`) until the current clip is on disk, then continue.
    private func autopilotAwaitDownload(_ triesLeft: Int, then: @escaping () -> Void) {
        if currentLocalFile != nil { then(); return }
        guard triesLeft > 0 else { Probe.error("AUTOPILOT: download did not finish in time"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            autopilotAwaitDownload(triesLeft - 1, then: then)
        }
    }

    func runAutopilot() {
        Probe.log("AUTOPILOT: begin — clip=\(Self.clips[clipIndex].name)")
        // Phase 1 — streaming, native rate (forward + reverse).
        autopilotAfter(3,  "STREAM play forward 1x")      { setRate(1) }
        autopilotAfter(6,  "STREAM native reverse -0.5x") { setRate(-0.5) }
        autopilotAfter(9,  "STREAM native reverse -2x")   { setRate(-2) }
        autopilotAfter(12, "pause + start download")      { setRate(0); downloadCurrent() }
        // Phase 2 — wait for the download, then LOCAL, then STREAM again, then trick play.
        autopilotAfter(13, "await download") {
            autopilotAwaitDownload(120) {
                Probe.log("AUTOPILOT: download complete → switching to LOCAL")
                playLocal = true                                                   // onChange → load LOCAL
                autopilotAfter(2,  "LOCAL native reverse -0.5x")  { setRate(-0.5) }
                autopilotAfter(5,  "LOCAL pause → back to STREAM") { setRate(0); playLocal = false }
                autopilotAfter(8,  "STREAM trick play ON")        { trickPlay = true }   // onChange parks rate
                autopilotAfter(9,  "STREAM trick reverse -0.5x")  { setRate(-0.5) }      // starts seek loop
                autopilotAfter(12, "pause + trick play OFF")      { setRate(0); trickPlay = false }
                autopilotAfter(14, "done")                        { Probe.log("AUTOPILOT: complete ✅") }
            }
        }
    }

    /// Compact button label: drop the trailing ".0" on whole speeds (so 10 not 10.0) but keep 0.5.
    func rateTitle(_ r: Double) -> String {
        r == r.rounded() ? String(format: "%.0f", r) : String(format: "%.1f", r)
    }

    /// Play/pause toggle. ALWAYS native, regardless of the trick-play switch: play resumes at native
    /// 1× and pause stops everything (including any running trick loop). "Playing" means either the
    /// native rate is nonzero OR a trick loop is active.
    func togglePlayPause() {
        let playing = (player.rate != 0) || (trickTimer != nil)
        logButtonPress(rate: playing ? 0 : 1)   // pausing → 0, resuming → native 1×
        stopTrickPlayback()
        if playing {
            player.rate = 0
            isPlaying = false
            status = "paused"
        } else {
            player.rate = 1        // native 1× — the play button is the native escape hatch
            isPlaying = true
            status = "rate = 1 (native)"
        }
    }

    /// Load the current clip from whichever source the toggle selects: the downloaded local file when
    /// `playLocal` is on AND a copy exists, otherwise the CDN stream. `resumeAt` seeks back to that
    /// position once ready (used when flipping the Stream⟷Local toggle so the playhead stays put for
    /// A/B comparison); pass nil to auto-seek to the middle (fresh load / clip change).
    func loadSource(resumeAt: Double?) {
        stopTrickPlayback()   // don't let a running loop seek into the newly-loaded item
        let useLocal = playLocal && currentLocalFile != nil
        let item: AVPlayerItem
        let label: String
        if useLocal, let file = currentLocalFile {
            item = AVPlayerItem(url: file)
            label = "LOCAL"
            status = "playing LOCAL file"
        } else {
            // GitHub Releases redirects to objects.githubusercontent.com, which serves the file as
            // `application/octet-stream` with no `.mp4` in the redirected path — so AVFoundation can't
            // identify the container and fails with AVErrorFileFormatNotRecognized (-11828). Override the
            // MIME type so it treats the stream as MP4. (iOS 17+; harmless no-op below that.)
            var options: [String: Any] = [:]
            if #available(iOS 17.0, *) {
                options[AVURLAssetOverrideMIMETypeKey] = "video/mp4"
            }
            item = AVPlayerItem(asset: AVURLAsset(url: remoteURL, options: options))
            label = "STREAM"
            status = "loading remote (stream)…"
        }
        player.replaceCurrentItem(with: item)
        Probe.log("load \(label) source (resumeAt=\(resumeAt.map { String(format: "%.2f", $0) } ?? "middle"))")
        pollReady(item, label: label, resumeAt: resumeAt)
    }

    /// Re-populate `localFiles` from disk on launch, so downloads persist across relaunches: any clip
    /// whose deterministic file already exists is marked available (enables its Local toggle).
    func restoreDownloads() {
        for idx in Self.clips.indices {
            let file = Self.localPath(for: idx)
            if FileManager.default.fileExists(atPath: file.path) {
                localFiles[idx] = file
                Probe.log("found existing download for clip \(idx): \(file.lastPathComponent)")
            }
        }
    }

    /// Download the current clip to disk (once), keyed by clipIndex so each clip keeps its own copy.
    /// Does NOT switch playback — flip the Source toggle to play it. Re-downloads if pressed again.
    func downloadCurrent() {
        isDownloading = true
        let idx = clipIndex
        let url = remoteURL
        status = "downloading clip \(idx)…"
        URLSession.shared.downloadTask(with: url) { tmp, _, err in
            guard let tmp else {
                DispatchQueue.main.async {
                    isDownloading = false
                    status = "download failed: \(err?.localizedDescription ?? "?")"
                }
                return
            }
            let dest = Self.localPath(for: idx)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.moveItem(at: tmp, to: dest)
            DispatchQueue.main.async {
                localFiles[idx] = dest
                isDownloading = false
                status = "downloaded clip \(idx) — flip Local to play it"
                Probe.log("downloaded clip \(idx) → \(dest.lastPathComponent)")
            }
        }.resume()
    }

    func pollReady(_ item: AVPlayerItem, label: String, resumeAt: Double? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if item.status == .readyToPlay {
                reverseFlags = "[\(label)] canPlayReverse=\(item.canPlayReverse)  slow=\(item.canPlaySlowReverse)  fast=\(item.canPlayFastReverse)"
                status = "\(label) ready — play forward, then try negative rates"
                let d = CMTimeGetSeconds(item.duration)
                if d.isFinite, d > 0 { durationSeconds = d }   // enable the seek slider immediately
                Probe.log("\(label) ready — canPlayReverse=\(item.canPlayReverse) slow=\(item.canPlaySlowReverse) fast=\(item.canPlayFastReverse) duration=\(d)")
                // Resume at the requested position (source toggle) or auto-seek to the EXACT middle
                // of the loaded file (fresh load). Skipped only if duration is somehow unknown.
                if let r = resumeAt, r.isFinite, r > 0 {
                    currentSeconds = r
                    seek(to: r)
                    Probe.log("resume at \(r)s")
                } else if d.isFinite, d > 0 {
                    let mid = d / 2
                    currentSeconds = mid
                    seek(to: mid)
                    Probe.log("auto-seek to middle \(mid)s of \(d)s")
                }
            } else if item.status == .failed {
                reverseFlags = "[\(label)] item FAILED: \(item.error?.localizedDescription ?? "?")"
                Probe.error("\(label) item FAILED: \(describeError(item.error))")
                logMediaLogs(item, label: label)
            } else {
                pollReady(item, label: label, resumeAt: resumeAt)
            }
        }
    }

    /// Explicitly ask the window scene to snap to landscape. The Info.plist already locks the app
    /// to landscape, but the iOS Simulator sometimes fails to rotate a freshly-launched orientation-
    /// locked app when the device is physically portrait — this forces it. No-op / harmless on a real
    /// device (which honors the plist lock on its own).
    func forceLandscape() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { error in
            Probe.error("requestGeometryUpdate failed: \(error.localizedDescription)")
        }
    }

    /// Unpack an NSError deeply (domain, code, and nested underlying errors) — AVFoundation's
    /// top-level `localizedDescription` ("Cannot Open") hides the real cause in the underlying error.
    func describeError(_ error: Error?) -> String {
        guard var err = error as NSError? else { return "nil" }
        var parts: [String] = []
        while true {
            parts.append("\(err.domain)#\(err.code): \(err.localizedDescription)")
            guard let underlying = err.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            err = underlying
        }
        return parts.joined(separator: " ⟶ ")
    }

    /// Dump AVPlayerItem's HTTP-level error/access logs — these reveal whether the network fetch
    /// itself failed (HTTP status, bytes transferred, server) vs the media being unparseable.
    func logMediaLogs(_ item: AVPlayerItem, label: String) {
        if let el = item.errorLog(), !el.events.isEmpty {
            for e in el.events {
                Probe.error("[\(label)] errorLog status=\(e.errorStatusCode) domain=\(e.errorDomain) server=\(e.serverAddress ?? "-") uri=\(e.uri ?? "-") comment=\(e.errorComment ?? "-")")
            }
        } else {
            Probe.error("[\(label)] errorLog: (empty — failure happened before/without an HTTP transaction)")
        }
        if let al = item.accessLog(), !al.events.isEmpty {
            for e in al.events {
                Probe.log("[\(label)] accessLog server=\(e.serverAddress ?? "-") bytes=\(e.numberOfBytesTransferred) uri=\(e.uri ?? "-")")
            }
        } else {
            Probe.log("[\(label)] accessLog: (empty — no bytes ever transferred)")
        }
    }

    /// Independent network check: fetch the first 64 KB of the SAME url via URLSession. Isolates
    /// "can the Simulator reach the media at all" from "does AVFoundation accept the asset".
    func probeConnectivity() {
        var req = URLRequest(url: remoteURL)
        req.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err as NSError? {
                Probe.error("connectivity: FAILED \(err.domain)#\(err.code): \(err.localizedDescription)")
                return
            }
            let http = resp as? HTTPURLResponse
            Probe.log("connectivity: status=\(http?.statusCode ?? -1) type=\(http?.value(forHTTPHeaderField: "Content-Type") ?? "-") accept-ranges=\(http?.value(forHTTPHeaderField: "Accept-Ranges") ?? "-") bytes=\(data?.count ?? 0)")
        }.resume()
    }

    func logOrientation() {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let o = scene?.interfaceOrientation.rawValue ?? -1
        let size = scene?.windows.first?.bounds.size ?? .zero
        let isLandscape = scene?.interfaceOrientation.isLandscape ?? false
        Probe.log("orientation: interfaceOrientation=\(o) isLandscape=\(isLandscape) window=\(Int(size.width))x\(Int(size.height))")
    }

    func installTimeObserver() {
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { t in
            let cur = CMTimeGetSeconds(t)
            if cur.isFinite {
                timeText = String(format: "t = %.2f", cur)
                if !isScrubbing { currentSeconds = cur }   // don't fight an active drag
            }
            if let d = player.currentItem?.duration, d.isNumeric {
                let ds = CMTimeGetSeconds(d)
                if ds.isFinite, ds > 0 { durationSeconds = ds }
            }
            isPlaying = (player.rate != 0) || (trickTimer != nil)   // trick loop pins native rate to 0
        }
    }

    /// Seek exactly (zero tolerance) so scrubbing lands on the intended frame — important for a
    /// probe that judges reverse smoothness. Does not change `rate`. Used on drag RELEASE.
    func seek(to seconds: Double) {
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        Probe.log("seek to \(seconds)s")
    }

    /// Live scrub: update the frame continuously WHILE dragging. Uses the "seek chasing" pattern —
    /// only one seek is in flight at a time; if newer positions arrive during a seek, the completion
    /// handler chases the most recent one. A small tolerance keeps it responsive (matches how the
    /// system scrubber previews during a drag); the exact landing happens via seek(to:) on release.
    func scrubSeek(to seconds: Double) {
        pendingSeekTarget = seconds
        guard !isSeekInProgress else { return }
        chaseSeek()
    }

    private func chaseSeek() {
        guard let target = pendingSeekTarget else { isSeekInProgress = false; return }
        pendingSeekTarget = nil
        isSeekInProgress = true
        let tol = CMTime(seconds: 0.25, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: tol, toleranceAfter: tol) { _ in
            chaseSeek()   // a newer target may have arrived mid-seek — chase it
        }
    }

    func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Hosts the player WITHOUT AVKit's built-in transport controls. SwiftUI's `VideoPlayer` always shows
/// the tap-to-reveal control overlay and gives no way to disable it, so we wrap `AVPlayerViewController`
/// directly and set `showsPlaybackControls = false`. The probe's own seek bar + rate buttons are the
/// only controls. `videoGravity = .resizeAspect` keeps the default fill behavior (letterboxed, no crop).
struct PlayerSurface: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = false
        vc.videoGravity = .resizeAspect
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
    }
}

/// A seek bar that seeks to wherever you TAP (not just when you grab the thumb) and also supports
/// dragging. A stock SwiftUI `Slider` only moves when the thumb itself is dragged; a
/// `DragGesture(minimumDistance: 0)` over the whole track treats a tap as a zero-length drag, so a
/// single click jumps straight to that position.
struct SeekBar: View {
    let current: Double
    let duration: Double
    let onScrub: (Double) -> Void    // fired continuously while touching (updates the playhead state)
    let onCommit: (Double) -> Void   // fired on release / tap-up (issues the actual seek)

    private let trackHeight: CGFloat = 8
    private let thumb: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let frac = duration > 0 ? min(max(current / duration, 0), 1) : 0
            let x = CGFloat(frac) * w
            ZStack(alignment: .leading) {
                // systemGray2 adapts to light/dark and is visible on the app's white background
                // (a white/low-opacity track vanished against it).
                Capsule().fill(Color(.systemGray2)).frame(height: trackHeight)
                Capsule().fill(Color.accentColor).frame(width: x, height: trackHeight)
                Circle().fill(Color.white).frame(width: thumb, height: thumb)
                    .shadow(radius: 1)
                    .offset(x: min(max(x - thumb / 2, 0), w - thumb))
            }
            .frame(height: thumb, alignment: .leading)
            .frame(maxHeight: .infinity)            // center the track vertically in the row
            .contentShape(Rectangle())               // whole area is tappable, not just the thumb
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard duration > 0, w > 0 else { return }
                        onScrub(Double(min(max(v.location.x / w, 0), 1)) * duration)
                    }
                    .onEnded { v in
                        guard duration > 0, w > 0 else { return }
                        onCommit(Double(min(max(v.location.x / w, 0), 1)) * duration)
                    }
            )
        }
        .frame(height: 28)
    }
}
