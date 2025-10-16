//
//  RecordingManager.swift
//  Prime Dictation
//
//  Created by Bryce Albertazzi on 9/16/25.
//  Copyright © 2025 Bryce Albertazzi. All rights reserved.
//
import UIKit
import AVFoundation
import SwiftyDropbox
import ProgressHUD

class RecordingManager {
    
    var viewController: ViewController!
    var sampleRate = 16000
    
    let recordingExtension: String = "m4a"
    let destinationRecordingExtension: String = "m4a"
    var recordingName: String = String() // The name of the most recent recording the user made
    
    var savedRecordingsKey: String = "savedRecordings"
    var savedRecordingNames: [String] = []
    let maxNumSavedRecordings = 10
    
    //Stores the current recording in queue the user wants to listen to
    var toggledRecordingName: String = String()
    var toggledRecordingsIndex: Int = Int()
    
    var numberOfRecordings: Int = 0
    
    init () {}
    
    func attach(viewController: ViewController) {
        self.viewController = viewController
    }
    
    func SetSavedRecordingsOnLoad()
    {
        savedRecordingNames = UserDefaults.standard.object(forKey: savedRecordingsKey) as? [String] ?? [String]()
        let recordingCount = savedRecordingNames.count
        if (recordingCount > 0) {
            SelectMostRecentRecording()
        } else {
            viewController.NoRecordingsUI()
        }
    }
    
    func UpdateSavedRecordings() {
        let recordingCount = savedRecordingNames.count
        if recordingCount < maxNumSavedRecordings {
            savedRecordingNames.append(recordingName)
        } else {
            //Delete the oldest recording and add the next one
            let oldestRecording = savedRecordingNames.removeFirst()

            do {
                let m4aUrl = GetDirectory().appendingPathComponent(oldestRecording).appendingPathExtension("m4a")
                if (FileManager.default.fileExists(atPath: m4aUrl.path)) {try FileManager.default.removeItem(at: m4aUrl)} else {print("M4A FILES DOES NOT EXIST!!!!")}
            } catch {
                print("UNABLE TO DETETE THE FILE OF AN OLDEST RECORDING IN QUEUE!!!!")
            }
            savedRecordingNames.append(recordingName)
        }
        UserDefaults.standard.set(savedRecordingNames, forKey: savedRecordingsKey)
        SelectMostRecentRecording()
    }
    
    func SelectMostRecentRecording() {
        let recordingCount = savedRecordingNames.count
        toggledRecordingsIndex = recordingCount - 1
        toggledRecordingName = savedRecordingNames[toggledRecordingsIndex]
        viewController.FileNameLabel.setTitle(savedRecordingNames[toggledRecordingsIndex], for: .normal)
        viewController.HasRecordingsUI(numberOfRecordings: recordingCount)
    }
    
    func RenameFile(newName: String) {
        let oldName = self.toggledRecordingName
        if (oldName == newName) {
            return
        }
        let n = DuplicateRecordingsThisMinute(fileName: newName)
        let newNameWithSuffix = n > 0 ? "\(newName)(\(n))" : newName
        do {
            try FileManager.default.moveItem(at: GetDirectory().appendingPathComponent(oldName).appendingPathExtension("m4a"), to: GetDirectory().appendingPathComponent(newNameWithSuffix).appendingPathExtension("m4a"))
            self.savedRecordingNames[self.toggledRecordingsIndex] = newNameWithSuffix
            self.toggledRecordingName = newNameWithSuffix
            viewController.FileNameLabel.setTitle(newNameWithSuffix, for: .normal)
            UserDefaults.standard.set(self.savedRecordingNames, forKey: self.savedRecordingsKey)
        } catch {
            ProgressHUD.failed("Failed to rename file")
        }
    }
    
    func RecordingTimeForName(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        f.dateFormat = "EEE MMM d yyyy 'at' h:mma"

        let base = f.string(from: now)
        let n = DuplicateRecordingsThisMinute(fileName: base)
        return n > 0 ? "\(base)(\(n))" : base
    }

    /// Finds the next numeric suffix for files that share the same minute stamp.
    /// Matches exactly `fileName` or `fileName(<number>)` and returns the next number to use.
    func DuplicateRecordingsThisMinute(fileName: String) -> Int {
        var maxSuffix = -1 // -1 means no existing files; 0 means base name exists

        for name in savedRecordingNames {
            if name == fileName {
                maxSuffix = max(maxSuffix, 0)
            } else if name.hasPrefix(fileName + "("), name.hasSuffix(")") {
                // Extract the digits between the parentheses
                let start = name.index(name.startIndex, offsetBy: fileName.count + 1)
                let end = name.index(before: name.endIndex)
                if start <= end {
                    let digits = name[start..<end]
                    if let n = Int(digits) {
                        maxSuffix = max(maxSuffix, n)
                    }
                }
            }
        }

        // Next available suffix (handles 10+, 100+, etc.)
        return maxSuffix + 1
    }
    
    func CheckToggledRecordingsIndex(goingToPreviousRecording: Bool) {
        let recordingCount = savedRecordingNames.count
        
        if (goingToPreviousRecording) {
            //Index bounds check for previous recording button
            if (toggledRecordingsIndex <= 0) { return }
            viewController.NextRecordingLabel.isHidden = false
            if (toggledRecordingsIndex == 1) {
                // Going to the oldest recording
                viewController.PreviousRecordingLabel.isHidden = true
            }
            toggledRecordingsIndex -= 1
        } else {
            //Index bounds check for next recording button
            if (toggledRecordingsIndex >= recordingCount - 1) { return }
            viewController.PreviousRecordingLabel.isHidden = false
            if (toggledRecordingsIndex == recordingCount - 2) {
                // Going to the newest recording
                viewController.NextRecordingLabel.isHidden = true
            }
            toggledRecordingsIndex += 1
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if viewController.audioPlayer.currentTime <= 0 {
            player.delegate = viewController
            viewController.ListenLabel.setTitle("Listen", for: .normal)
            viewController.HideListeningUI()
            viewController.EnableDestinationAndSendButtons()
            viewController.watch.stop()
        }
    }
    
    //Get path to directory
    func GetDirectory() -> URL {
        //Search for all urls in document directory
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        
        //Get the first URL in the document directory
        let documentDirectory = path[0]
        //Return the url to that directory
        return documentDirectory
    }
}
