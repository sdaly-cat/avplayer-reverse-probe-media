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
        let asset = AVURLAsset(url: remoteURL)
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
                probeLog.error("\(label, privacy: .public) item FAILED: \(item.error?.localizedDescription ?? "?", privacy: .public)")
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
