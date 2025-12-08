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
    var uuid: UUID
    var fileName: String
    var hasTranscription: Bool
    var transcriptionText: String?
    var isTranscribing: Bool = false
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
    var transcribingAudioTranscriptionObjects: [AudioTranscriptionObject] = []
    let maxNumSavedRecordings = 25
    
    //Stores the current recording in queue the user wants to listen to
    var toggledRecordingsIndex: Int = Int()
    var toggledRecordingURL: URL? = nil
    var toggledTranscriptURL: URL? = nil
    var toggledAudioTranscriptionObject: AudioTranscriptionObject = AudioTranscriptionObject(uuid: UUID(), fileName: "", hasTranscription: false)
    
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
    
    var newlyCreatedAudioTranscriptionObject: AudioTranscriptionObject? = nil
    func createNewAudioTranscriptionObject(uuid: UUID) {
        newlyCreatedAudioTranscriptionObject = AudioTranscriptionObject(
            uuid: uuid,
            fileName: mostRecentRecordingName,
            hasTranscription: false,
            transcriptionText: nil,
            isTranscribing: false
        )
    }
    
    func UpdateSavedRecordings() {
        let recordingCount = savedAudioTranscriptionObjects.count
        if recordingCount >= maxNumSavedRecordings {
            //Delete the oldest recording in the queue
            let oldestRecording = savedAudioTranscriptionObjects.removeFirst()
            
            do {
                let m4aUrl = GetDirectory().appendingPathComponent(oldestRecording.uuid.uuidString).appendingPathExtension(audioRecordingExtension)
                if (FileManager.default.fileExists(atPath: m4aUrl.path)) {try FileManager.default.removeItem(at: m4aUrl)} else {print("M4A FILES DOES NOT EXIST!!!!")}
            } catch {
                print("UNABLE TO DETETE THE FILE OF AN OLDEST RECORDING IN QUEUE!!!!")
            }
        }

        if let newlyCreatedAudioTranscriptionObject {
            savedAudioTranscriptionObjects.append(newlyCreatedAudioTranscriptionObject)
        }

        saveAudioTranscriptionObjectsToUserDefaults()
        Task { try await SelectMostRecentRecording() }
        viewController.NoTranscriptionUI()
        transcriptionManager.toggledTranscriptText = nil
    }
    
    func UpdateAudioTranscriptionObjectOnTranscriptionInProgressChange(processedObjectUUID: UUID, isTranscriptionInProgress: Bool) {
        for (index, object) in savedAudioTranscriptionObjects.enumerated() where object.uuid == processedObjectUUID {
            print("updating \(object.fileName) with uuid: \(object.uuid.uuidString) object isTranscribing to \(isTranscriptionInProgress)")
            savedAudioTranscriptionObjects[index].isTranscribing = isTranscriptionInProgress
            if (toggledAudioTranscriptionObject.uuid == processedObjectUUID) {
                print("updating toggledAudioTranscriptionObject, we are on that one")
                toggledAudioTranscriptionObject.isTranscribing = isTranscriptionInProgress
            }
        }
    }
    
    func saveAudioTranscriptionObjectsToUserDefaults() {
        let sanitizedAudioTranscriptionObjects: [AudioTranscriptionObject] = savedAudioTranscriptionObjects.map { object in
            return AudioTranscriptionObject(uuid: object.uuid, fileName: object.fileName, hasTranscription: object.hasTranscription, transcriptionText: nil, isTranscribing: false)
        }
        do {
            try UserDefaults.standard.setCodable(sanitizedAudioTranscriptionObjects, forKey: savedAudioTranscriptionObjectsKey)
        } catch {
            print("Unable to save audio transcription objects to UserDefaults")
        }
    }
    
    func setToggledRecordingURL() {
        toggledRecordingURL = GetDirectory().appendingPathComponent(toggledAudioTranscriptionObject.uuid.uuidString).appendingPathExtension(audioRecordingExtension)
    }
    
    func createPrettyFileURLForExport(for original: URL, exportedFilename: String, ext: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent(exportedFilename).appendingPathExtension(ext)

        let fm = FileManager.default
        if fm.fileExists(atPath: tempURL.path) {
            try fm.removeItem(at: tempURL)
        }
        try fm.copyItem(at: original, to: tempURL)
        print("createPrettyFileURLForExport: \(tempURL)")
        return tempURL
    }
    
    func getURLForAudioTranscriptionObject(at uuid: UUID) -> URL? {
        return GetDirectory().appendingPathComponent(uuid.uuidString).appendingPathExtension(audioRecordingExtension)
    }
    
    func SelectMostRecentRecording() async throws {
        let recordingCount = savedAudioTranscriptionObjects.count
        toggledRecordingsIndex = recordingCount - 1
        toggledAudioTranscriptionObject = savedAudioTranscriptionObjects[toggledRecordingsIndex]
        if (toggledAudioTranscriptionObject.hasTranscription) {
            await viewController.HasTranscriptionUI()
            Task { try await transcriptionManager.readToggledTextFileAndSetInAudioTranscriptObject() }
        } else {
            await viewController.NoTranscriptionUI()
        }
        setToggledRecordingURL()
        await viewController.FileNameLabel.setTitle(savedAudioTranscriptionObjects[toggledRecordingsIndex].fileName, for: .normal)
        await viewController.HasRecordingsUI(numberOfRecordings: recordingCount)
    }
    
    func sanitizedBaseName(_ name: String, replacement: String = "-") -> String {
        // Characters that can break paths (keep `:` illegal)
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        
        // Replace illegal chars with a replacement token
        var s = name.components(separatedBy: illegal).joined(separator: replacement)
        
        // Collapse repeated spaces/dashes and trim edges
        s = s.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove any leading dots (avoid hidden files)
        while s.hasPrefix(".") { s.removeFirst() }
        
        // Remove trailing dots/spaces (friendlier to Windows/cloud sync)
        while s.hasSuffix(".") || s.hasSuffix(" ") { s.removeLast() }
        
        // Ensure non-empty result
        if s.isEmpty { s = "untitled" }
        
        return s
    }
    
    func RenameFile(newName rawNewName: String) {
        // Handle illegal characters
        let illegalSet = CharacterSet(charactersIn: "/:\\?%*|\"<>\\()").union(.controlCharacters)
        
        if rawNewName.rangeOfCharacter(from: illegalSet) != nil {
            viewController.displayAlert(title: "Invalid File Name", message: """
                Invalid file name. Disallowed: / : ? % * | " < > \\ ( )
            """)
            return
        }
        
        if rawNewName.hasPrefix(".") || rawNewName.hasSuffix(".") || rawNewName.hasPrefix(" ") || rawNewName.hasSuffix(" ") {
            viewController.displayAlert(title: "Invalid FileName", message: "Leading or trailing dots and whitespaces are not allowed.")
            return
        }
        
        // Normalize: trim and drop any extension the user typed
        let baseNewName = (rawNewName as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseNewName.isEmpty else { return }
        let santizedNewName = sanitizedBaseName(baseNewName)

        let dir = GetDirectory()

        let oldBaseName = self.toggledAudioTranscriptionObject.fileName
        if oldBaseName == santizedNewName { return }
        
        self.savedAudioTranscriptionObjects[self.toggledRecordingsIndex].fileName = santizedNewName
        self.toggledAudioTranscriptionObject = self.savedAudioTranscriptionObjects[self.toggledRecordingsIndex]
        viewController.FileNameLabel.setTitle(santizedNewName, for: .normal)
        saveAudioTranscriptionObjectsToUserDefaults()
    }

    
    func RecordingTimeForName(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        // safer: no "/" or ":" in the raw name
        f.dateFormat = "EEE MMM d yyyy 'at' h.mm a"   // e.g., "Tue Nov 4 2025 at 10.01 pm"

        let base = f.string(from: now)
        let sanitized = sanitizedBaseName(base)
        if (savedAudioTranscriptionObjects.count > 0) {
            let n = GetDuplicateIndex(newFileName: sanitized, isNewFile: true)
            return n > 0 ? "\(sanitized)(\(n))" : sanitized
        } else {
            return sanitized
        }
    }

    func extractDigits(from filename: String) -> Int {
        let pattern = #"\((\d+)\)"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(filename.startIndex..., in: filename)
            if let match = regex.firstMatch(in: filename, options: [], range: range),
               let digitsRange = Range(match.range(at: 1), in: filename) {
                return Int(filename[digitsRange]) ?? 0
            }
        }
        return 0
    }
    
    /// Finds the next numeric suffix for files that share the same minute stamp.
    /// Matches exactly `fileName` or `fileName(<number>)` and returns the next number to use.
    func GetDuplicateIndex(newFileName: String, isNewFile: Bool) -> Int {
        var previousHighestDupIndex = -1
        var numDups = 0
        
        for object in savedAudioTranscriptionObjects {
            let name = object.fileName
            
            let parts = name.split(separator: "(", maxSplits: 1, omittingEmptySubsequences: true)
            guard let first = parts.first else { continue }
            
            let base = String(first).trimmingCharacters(in: .whitespaces)
            guard base == newFileName else { continue }
            
            let index = extractDigits(from: name)  // assume 0 if no "(n)"
            previousHighestDupIndex = max(previousHighestDupIndex, index)
            numDups += 1
        }
        
        return numDups == 0 ? 0 : previousHighestDupIndex + 1
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
            return nil
        }
    }
}
