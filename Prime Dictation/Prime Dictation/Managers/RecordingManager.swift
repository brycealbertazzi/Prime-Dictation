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

struct AudioTranscriptionObject : Codable {
    var fileName: String
    var hasTranscription: Bool
    var transcriptionText: String?
}

class RecordingManager {
    
    var viewController: ViewController!
    var transcriptionManager: TranscriptionManager!
    var sampleRate = 16000
    
    let audioRecordingExtension: String = "m4a"
    let transcriptionRecordingExtension: String = "txt"
    var mostRecentRecordingName: String = String() // The name of the most recent recording the user made
    
    var savedAudioTranscriptionObjectsKey: String = "savedAudioTranscriptionObjectsKey"
    var savedAudioTranscriptionObjects: [AudioTranscriptionObject] = []
    let maxNumSavedRecordings = 10
    
    //Stores the current recording in queue the user wants to listen to
    var toggledRecordingsIndex: Int = Int()
    var toggledRecordingURL: URL? = nil
    var toggledTranscriptURL: URL? = nil
    var toggledAudioTranscriptionObject: AudioTranscriptionObject = AudioTranscriptionObject(fileName: "", hasTranscription: false)
    
    var numberOfRecordings: Int = 0
    
    init () {}
    
    func attach(viewController: ViewController, transcriptionManager: TranscriptionManager) {
        self.viewController = viewController
        self.transcriptionManager = transcriptionManager
    }
    
    func SetSavedRecordingsOnLoad()
    {
        savedAudioTranscriptionObjects = UserDefaults.standard.loadCodable([AudioTranscriptionObject].self, forKey: savedAudioTranscriptionObjectsKey) ?? [AudioTranscriptionObject]()
        let recordingCount = savedAudioTranscriptionObjects.count
        if (recordingCount > 0) {
            Task { try await SelectMostRecentRecording() }
        } else {
            viewController.NoRecordingsUI()
        }
    }
    
    func UpdateSavedRecordings() {
        let recordingCount = savedAudioTranscriptionObjects.count
        if recordingCount < maxNumSavedRecordings {
            savedAudioTranscriptionObjects.append(AudioTranscriptionObject(fileName: mostRecentRecordingName, hasTranscription: false, transcriptionText: nil))
        } else {
            //Delete the oldest recording and add the next one
            let oldestRecording = savedAudioTranscriptionObjects.removeFirst()

            do {
                let m4aUrl = GetDirectory().appendingPathComponent(oldestRecording.fileName).appendingPathExtension(audioRecordingExtension)
                if (FileManager.default.fileExists(atPath: m4aUrl.path)) {try FileManager.default.removeItem(at: m4aUrl)} else {print("M4A FILES DOES NOT EXIST!!!!")}
            } catch {
                print("UNABLE TO DETETE THE FILE OF AN OLDEST RECORDING IN QUEUE!!!!")
            }
            savedAudioTranscriptionObjects.append(AudioTranscriptionObject(fileName: mostRecentRecordingName, hasTranscription: false, transcriptionText: nil))
        }
        saveAudioTranscriptionObjectsToUserDefaults()
        Task { try await SelectMostRecentRecording() }
        viewController.NoTranscriptionUI()
    }
    
    func saveAudioTranscriptionObjectsToUserDefaults() {
        let sanitizedAudioTranscriptionObjects: [AudioTranscriptionObject] = savedAudioTranscriptionObjects.map { object in
            return AudioTranscriptionObject(fileName: object.fileName, hasTranscription: object.hasTranscription, transcriptionText: nil)
        }
        do {
            try UserDefaults.standard.setCodable(sanitizedAudioTranscriptionObjects, forKey: savedAudioTranscriptionObjectsKey)
        } catch {
            print("Unable to save audio transcription objects to UserDefaults")
        }
    }
    
    func SetToggledAudioTranscriptObjectAfterTranscription() {
        savedAudioTranscriptionObjects[toggledRecordingsIndex].hasTranscription = true
        toggledAudioTranscriptionObject = savedAudioTranscriptionObjects[toggledRecordingsIndex]
        
        saveAudioTranscriptionObjectsToUserDefaults()
        // Temporarily set the transcripionText of the toggledAudioTranscription object to the transcribedText (cache)
        // We don't want to persist this to UserDefaults because it is a very long string and could get corrupted in storage
        toggledAudioTranscriptionObject.transcriptionText = transcriptionManager.toggledTranscriptText
        viewController.HasTranscriptionUI()
    }
    
    func UpdateToggledTranscriptionText(newText: String) {
        // 1) update in-memory cache
        transcriptionManager.toggledTranscriptText = newText
        toggledAudioTranscriptionObject.transcriptionText = newText
        savedAudioTranscriptionObjects[toggledRecordingsIndex] = toggledAudioTranscriptionObject
        

        // 2) persist to disk
        // assuming your object has something like `fileURL: URL?` or `transcriptFileURL: URL?`
        if let fileURL = toggledRecordingURL?.deletingPathExtension().appendingPathExtension(transcriptionRecordingExtension) {
            do {
                try newText.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                print("⚠️ Failed to write updated transcript to disk: \(error)")
            }
        } else {
            print("⚠️ No transcript file URL on toggledAudioTranscriptionObject")
        }
    }
    
    func setToggledRecordingURL() {
        toggledRecordingURL = GetDirectory().appendingPathComponent(toggledAudioTranscriptionObject.fileName).appendingPathExtension(audioRecordingExtension)
    }
    
    func SelectMostRecentRecording() async throws {
        let recordingCount = savedAudioTranscriptionObjects.count
        toggledRecordingsIndex = recordingCount - 1
        toggledAudioTranscriptionObject = savedAudioTranscriptionObjects[toggledRecordingsIndex]
        if (toggledAudioTranscriptionObject.hasTranscription) {
            await viewController.HasTranscriptionUI()
            Task { try await transcriptionManager.readToggledTextFileAndSetInAudioTranscriptObject() }
        }
        setToggledRecordingURL()
        await viewController.FileNameLabel.setTitle(savedAudioTranscriptionObjects[toggledRecordingsIndex].fileName, for: .normal)
        await viewController.HasRecordingsUI(numberOfRecordings: recordingCount)
    }
    
    func RenameFile(newName: String) {
        let oldName = self.toggledAudioTranscriptionObject.fileName
        if (oldName == newName) {
            return
        }
        let n = DuplicateRecordingsThisMinute(fileName: newName)
        let newNameWithSuffix = n > 0 ? "\(newName)(\(n))" : newName
        do {
            try FileManager.default.moveItem(at: GetDirectory().appendingPathComponent(oldName).appendingPathExtension(audioRecordingExtension), to: GetDirectory().appendingPathComponent(newNameWithSuffix).appendingPathExtension(audioRecordingExtension))
            self.savedAudioTranscriptionObjects[self.toggledRecordingsIndex].fileName = newNameWithSuffix
            self.toggledAudioTranscriptionObject = self.savedAudioTranscriptionObjects[self.toggledRecordingsIndex]
            self.setToggledRecordingURL()
            viewController.FileNameLabel.setTitle(newNameWithSuffix, for: .normal)
            saveAudioTranscriptionObjectsToUserDefaults()
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

        for object in savedAudioTranscriptionObjects {
            let name = object.fileName
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
        let recordingCount = savedAudioTranscriptionObjects.count
        
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

extension UserDefaults {
    func setCodable<T: Codable>(_ value: T, forKey key: String) throws {
        let data = try JSONEncoder().encode(value)
        self.set(data, forKey: key)
    }

    func loadCodable<T: Codable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch {
            // Optional: log once
            print("UserDefaults decode error for \(key):", error)
            return nil
        }
    }
}
