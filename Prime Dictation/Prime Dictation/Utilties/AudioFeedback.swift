import AVFoundation
import UIKit   // for NSDataAsset

final class AudioFeedback {
    static let shared = AudioFeedback()

    private var players: [String: AVAudioPlayer] = [:]
    private let queue = DispatchQueue(label: "audiofeedback.queue")

    private init() {
        // Keep it passive so the view controller owns AVAudioSession.
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
            // Restart from the beginning if it’s mid-play (optional)
            // player.currentTime = 0
            player.volume = vol
            player.play()
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
