//
//  Stopwatch.swift
//  Prime Dictation
//
//  Created by Bryce Albertazzi on 8/9/19.
//  Copyright © 2019 Bryce Albertazzi. All rights reserved.
//

import Foundation

class Stopwatch {
    private var startTime : Date?
    private var currentElapsedTime: TimeInterval?
    var viewController: ViewController!
    let subscriptionManager: SubscriptionManager! = AppServices.shared.subscriptionManager
    // 🔹 New: callback for each playback tick
    var onPlaybackTick: ((TimeInterval, TimeInterval) -> Void)?
    
    init(viewController: ViewController) {
        self.viewController = viewController
    }
    
    var elapsedTime: TimeInterval {
        if let startTime = self.startTime {
            return -startTime.timeIntervalSinceNow
        } else {
            return 0
        }
    }
    
    var isRunning: Bool {
        return startTime != nil
    }
    
    func start() {
        startTime = Date()
    }
    
    func stop() {
        startTime = nil
    }
    
    var timeWhenPaused: Date?
    func pause() {
        timeWhenPaused = Date()
    }
    
    var timeWhenResumed: Date?
    func resume() {
        timeWhenResumed = Date()
        startTime = startTime?.addingTimeInterval(timeWhenResumed?.timeIntervalSince(timeWhenPaused!) ?? 0)
    }
    
    func formatStopwatchTime(_ time: TimeInterval) -> String {
        // Use whole seconds for display
        let totalSeconds = Int(time)

        if totalSeconds < 60 {
            // Under a minute: "Xs"
            return "\(totalSeconds)s"
        } else {
            // 1 minute or more: "M:SS"
            let minutes = totalSeconds / 60
            let seconds = totalSeconds % 60
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
    
    static let StopwatchDefaultText = "0s"
    func UpdateElapsedTime(timer: Timer) {
        if subscriptionManager.accessLevel == .trial && overTrialRemainingLength() {
            timer.invalidate()
            viewController.finishCurrentRecording(interrupted: true, trialEnded: true)
        }
        if self.isRunning && !viewController.isRecordingPaused {
            let formatted = formatStopwatchTime(self.elapsedTime)
            viewController.RecordingStopwatch.text = formatted
        } else {
            timer.invalidate()
        }
    }

    func UpdateElapsedTimeListen(timer: Timer) {        
        if self.isRunning && !viewController.isRecordingPaused {
            if let vc = viewController, let player = vc.audioPlayer {
                let currentTime = player.currentTime
                let currentText = formatStopwatchTime(currentTime)

                let totalTime = viewController.audioPlayer.duration
                let totalText = formatStopwatchTime(totalTime)
                viewController.PlaybackStopwatch.text = currentText + " / " + totalText
            
                let duration = player.duration
                onPlaybackTick?(currentTime, duration)
            }
        } else {
            timer.invalidate()
        }
    }
    
    func overTrialRemainingLength() -> Bool {
        if subscriptionManager.isSubscribed {
            print("Subscribed, will not calculate trial expiration")
            return false
        }
        print("elapsedTime: \(self.elapsedTime)")
        print("remainingFreeTrialTime: \(subscriptionManager.trialManager.remainingFreeTrialTime())")
        return self.elapsedTime > subscriptionManager.trialManager.remainingFreeTrialTime()
    }
}
