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
    
    func UpdateElapsedTime(timer: Timer) {
        
        if self.isRunning && !viewController.isRecordingPaused {
            let minutes = Int(self.elapsedTime / 60)
            let seconds = Int(self.elapsedTime.truncatingRemainder(dividingBy: 60))
            let tensOfSeconds = Int((self.elapsedTime * 10).truncatingRemainder(dividingBy: 10))
            viewController.StopWatchLabel.text = String(format: "%d:%02d.%d", minutes, seconds, tensOfSeconds)
        } else {
            timer.invalidate()
        }
    }
    
    func UpdateElapsedTimeListen(timer: Timer) {
        if self.isRunning && !viewController.isRecordingPaused {
            let elapsedTime = self.elapsedTime
            let minutes = Int(elapsedTime / 60)
            let seconds = Int(elapsedTime.truncatingRemainder(dividingBy: 60))
            let tensOfSeconds = Int((elapsedTime * 10).truncatingRemainder(dividingBy: 10))
            let minutesTotal = Int(viewController.audioPlayer.duration / 60)
            let secondsTotal = Int(viewController.audioPlayer.duration.truncatingRemainder(dividingBy: 60))
            let tensOfSecondsTotal = Int((viewController.audioPlayer.duration * 10).truncatingRemainder(dividingBy: 10))
            viewController.StopWatchLabel.text = String(format: "%d:%02d.%d", minutes, seconds, tensOfSeconds) + "/" + String(format: "%d:%02d.%d", minutesTotal, secondsTotal, tensOfSecondsTotal)
        } else {
            timer.invalidate()
        }
    }
}
