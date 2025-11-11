import AVFoundation
import UIKit   // for NSDataAsset

final class AudioFeedback {
    static let shared = AudioFeedback()

    private var players: [String: AVAudioPlayer] = [:]
    private let queue = DispatchQueue(label: "audiofeedback.queue")

    private init() {
        // Passive: the VC owns AVAudioSession.
        preload(["ding", "whoosh"])
    }

    // MARK: - Public API
    func playDing(intensity: Float = 1.0)   { play(assetNamed: "ding",   intensity: intensity) }
    func playWhoosh(intensity: Float = 1.0) { play(assetNamed: "whoosh", intensity: intensity) }

    // MARK: - Internals
    private func preload(_ names: [String]) {
        names.forEach { _ = player(for: $0) }
    }

    private func play(assetNamed name: String, intensity: Float) {
        let vol = max(0.0, min(1.0, intensity))

        queue.async {
            guard let player = self.player(for: name) else {
                print("⚠️ AudioFeedback: asset '\(name)' not found or failed to initialize.")
                return
            }

            let session = AVAudioSession.sharedInstance()

            // Snapshot for restore
            let prevCategory = session.category
            let prevMode     = session.mode
            let prevOptions  = session.categoryOptions

            // If we're in record mode, assert loudspeaker for this short UI sound
            if session.category == .playAndRecord {
                var opts = prevOptions
                if !opts.contains(.defaultToSpeaker) { opts.insert(.defaultToSpeaker) }
                // Switch to a playback-friendly mode (keeps category), then force speaker
                try? session.setCategory(.playAndRecord, mode: .default, options: opts)
                try? session.setActive(true)
                try? session.overrideOutputAudioPort(.speaker)
            } else {
                // Not recording: make sure session is active so it actually plays
                try? session.setActive(true)
            }

            // Play at requested intensity
            player.volume = vol
            // If you want to restart even if mid-play: player.currentTime = 0
            player.play()

            // Restore route/mode shortly after playback ends
            let lifetime = max(player.duration, 0.25)
            self.queue.asyncAfter(deadline: .now() + lifetime + 0.1) {
                if prevCategory == .playAndRecord {
                    // Clear override and restore the original mode/options
                    try? session.overrideOutputAudioPort(.none)
                    try? session.setCategory(prevCategory, mode: prevMode, options: prevOptions)
                    try? session.setActive(true)
                } else {
                    // Nothing special to restore
                }
            }
        }
    }

    private func player(for name: String) -> AVAudioPlayer? {
        if let cached = players[name] { return cached }
        guard let dataAsset = NSDataAsset(name: name) else {
            print("⚠️ AudioFeedback: NSDataAsset '\(name)' not found in asset catalog.")
            return nil
        }
        do {
            let player = try AVAudioPlayer(data: dataAsset.data)
            player.prepareToPlay()
            players[name] = player
            return player
        } catch {
            print("⚠️ AudioFeedback: failed to create player for '\(name)': \(error)")
            return nil
        }
    }
}
