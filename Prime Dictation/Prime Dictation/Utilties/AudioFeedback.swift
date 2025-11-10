import AVFoundation
import UIKit   // for NSDataAsset

final class AudioFeedback {
    static let shared = AudioFeedback()

    // Cache players so they start instantly and can replay quickly
    private var players: [String: AVAudioPlayer] = [:]
    private let queue = DispatchQueue(label: "audiofeedback.queue")

    private init() {
        // Optional: configure the audio session for lightweight UI sounds
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
        preload(["ding", "whoosh"])
    }

    // MARK: - Public API

    func playDing()  { play(assetNamed: "ding") }
    func playWhoosh(){ play(assetNamed: "whoosh") }

    // MARK: - Internal

    private func preload(_ names: [String]) {
        names.forEach { _ = player(for: $0) }
    }

    private func play(assetNamed name: String) {
        queue.async {
            guard let player = self.player(for: name) else {
                print("⚠️ AudioFeedback: asset '\(name)' not found or failed to initialize.")
                return
            }
            // If currently playing and you want it to restart, uncomment:
            // player.currentTime = 0

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
