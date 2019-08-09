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
    
}
