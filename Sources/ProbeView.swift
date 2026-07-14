import SwiftUI
import AVKit
import AVFoundation
import os

/// Structured log channel for the probe. Filter it from the host with:
///   xcrun simctl spawn booted log stream --predicate 'subsystem == "com.catapult.ReverseProbe"'
/// Interpolations are marked `.public` so they are NOT redacted as `<private>`.
let probeLog = Logger(subsystem: "com.catapult.ReverseProbe", category: "probe")

/// Feasibility probe for native AVPlayer reverse playback while STREAMING over a CDN.
/// See HANDOFF.md for the full "what is this / what question does it answer" brief.
struct ProbeView: View {
    @State private var player = AVPlayer()
    @State private var status = "idle"
    @State private var reverseFlags = "reverse flags: (waiting)"
    @State private var timeText = "t = 0.00"
    @State private var timeObserver: Any?

    // MARK: - Test media (synthetic, hosted on this repo's GitHub Releases)
    // Both are 1920x1080, 59.94fps, H.264 High@4.2, progressive, GOP-30, 12 Mbps CBR, ~180s.
    // They differ ONLY in GOP structure. The burned-in on-screen label says CLOSED or OPEN.
    static let closedGOP = URL(string: "https://github.com/sdaly-cat/avplayer-reverse-probe-media/releases/download/v1/synthetic_ball_1080p_5994fps_3min_closedgop.mp4")!
    static let openGOP   = URL(string: "https://github.com/sdaly-cat/avplayer-reverse-probe-media/releases/download/v1/synthetic_ball_1080p_5994fps_3min_opengop.mp4")!

    // Flip this between .closedGOP and .openGOP to compare. (Open GOP is the harder, more
    // representative case — it's what tripped up WebCodecs on the web player.)
    private let remoteURL = ProbeView.closedGOP

    var body: some View {
        VStack(spacing: 10) {
            // Fill all vertical space left over by the compact control cluster below.
            VideoPlayer(player: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(status).font(.footnote)
            Text(reverseFlags).font(.footnote).foregroundColor(.secondary)
            Text(timeText).font(.system(.footnote, design: .monospaced))
            HStack {
                ForEach([-2.0, -1.0, -0.5, 0.0, 0.5, 1.0, 2.0], id: \.self) { r in
                    Button(r == 0 ? "❚❚" : String(format: "%.1f", r)) { setRate(Float(r)) }
                        .buttonStyle(.bordered)
                }
            }
            HStack(spacing: 12) {
                Button("Load remote (stream)") { loadRemote() }.buttonStyle(.borderedProminent)
                Button("Download then play local") { downloadThenPlay() }.buttonStyle(.bordered)
            }
        }
        .padding()
        .background(
            GeometryReader { proxy in
                Color.clear.onAppear {
                    probeLog.log("layout: SwiftUI content size=\(Int(proxy.size.width), privacy: .public)x\(Int(proxy.size.height), privacy: .public)")
                }
            }
        )
        .onAppear {
            probeLog.log("probe launched — remoteURL=\(remoteURL.absoluteString, privacy: .public)")
            forceLandscape()
            probeConnectivity()
            installTimeObserver()
            loadRemote()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { logOrientation() }
        }
    }

    func setRate(_ r: Float) {
        player.rate = r            // negative = reverse (requires item.canPlayReverse)
        status = "rate = \(r)"
    }

    func loadRemote() {
        // GitHub Releases redirects to objects.githubusercontent.com, which serves the file as
        // `application/octet-stream` with no `.mp4` in the redirected path — so AVFoundation can't
        // identify the container and fails with AVErrorFileFormatNotRecognized (-11828). Override the
        // MIME type so it treats the stream as MP4. (iOS 17+; harmless no-op below that.)
        var options: [String: Any] = [:]
        if #available(iOS 17.0, *) {
            options[AVURLAssetOverrideMIMETypeKey] = "video/mp4"
        }
        let asset = AVURLAsset(url: remoteURL, options: options)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        status = "loading remote (stream)…"
        pollReady(item, label: "STREAM")
    }

    func downloadThenPlay() {
        status = "downloading…"
        URLSession.shared.downloadTask(with: remoteURL) { tmp, _, err in
            guard let tmp else {
                DispatchQueue.main.async { status = "download failed: \(err?.localizedDescription ?? "?")" }
                return
            }
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("probe.mp4")
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.moveItem(at: tmp, to: dest)
            DispatchQueue.main.async {
                let item = AVPlayerItem(url: dest)
                player.replaceCurrentItem(with: item)
                status = "playing LOCAL file"
                pollReady(item, label: "LOCAL")
            }
        }.resume()
    }

    func pollReady(_ item: AVPlayerItem, label: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if item.status == .readyToPlay {
                reverseFlags = "[\(label)] canPlayReverse=\(item.canPlayReverse)  slow=\(item.canPlaySlowReverse)  fast=\(item.canPlayFastReverse)"
                status = "\(label) ready — play forward, then try negative rates"
                probeLog.log("\(label, privacy: .public) ready — canPlayReverse=\(item.canPlayReverse, privacy: .public) slow=\(item.canPlaySlowReverse, privacy: .public) fast=\(item.canPlayFastReverse, privacy: .public)")
            } else if item.status == .failed {
                reverseFlags = "[\(label)] item FAILED: \(item.error?.localizedDescription ?? "?")"
                probeLog.error("\(label, privacy: .public) item FAILED: \(describeError(item.error), privacy: .public)")
                logMediaLogs(item, label: label)
            } else {
                pollReady(item, label: label)
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
            probeLog.error("requestGeometryUpdate failed: \(error.localizedDescription, privacy: .public)")
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
                probeLog.error("[\(label, privacy: .public)] errorLog status=\(e.errorStatusCode, privacy: .public) domain=\(e.errorDomain, privacy: .public) server=\(e.serverAddress ?? "-", privacy: .public) uri=\(e.uri ?? "-", privacy: .public) comment=\(e.errorComment ?? "-", privacy: .public)")
            }
        } else {
            probeLog.error("[\(label, privacy: .public)] errorLog: (empty — failure happened before/without an HTTP transaction)")
        }
        if let al = item.accessLog(), !al.events.isEmpty {
            for e in al.events {
                probeLog.log("[\(label, privacy: .public)] accessLog server=\(e.serverAddress ?? "-", privacy: .public) bytes=\(e.numberOfBytesTransferred, privacy: .public) uri=\(e.uri ?? "-", privacy: .public)")
            }
        } else {
            probeLog.log("[\(label, privacy: .public)] accessLog: (empty — no bytes ever transferred)")
        }
    }

    /// Independent network check: fetch the first 64 KB of the SAME url via URLSession. Isolates
    /// "can the Simulator reach the media at all" from "does AVFoundation accept the asset".
    func probeConnectivity() {
        var req = URLRequest(url: remoteURL)
        req.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err as NSError? {
                probeLog.error("connectivity: FAILED \(err.domain, privacy: .public)#\(err.code, privacy: .public): \(err.localizedDescription, privacy: .public)")
                return
            }
            let http = resp as? HTTPURLResponse
            probeLog.log("connectivity: status=\(http?.statusCode ?? -1, privacy: .public) type=\(http?.value(forHTTPHeaderField: "Content-Type") ?? "-", privacy: .public) accept-ranges=\(http?.value(forHTTPHeaderField: "Accept-Ranges") ?? "-", privacy: .public) bytes=\(data?.count ?? 0, privacy: .public)")
        }.resume()
    }

    func logOrientation() {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let o = scene?.interfaceOrientation.rawValue ?? -1
        let size = scene?.windows.first?.bounds.size ?? .zero
        let isLandscape = scene?.interfaceOrientation.isLandscape ?? false
        probeLog.log("orientation: interfaceOrientation=\(o, privacy: .public) isLandscape=\(isLandscape, privacy: .public) window=\(Int(size.width), privacy: .public)x\(Int(size.height), privacy: .public)")
    }

    func installTimeObserver() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { t in
            timeText = String(format: "t = %.2f", CMTimeGetSeconds(t))
        }
    }
}
