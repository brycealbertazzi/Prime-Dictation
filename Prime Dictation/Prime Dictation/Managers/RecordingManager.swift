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
            transcriptionManager.toggledTranscriptText = nil
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
        savedAudioTranscriptionObjects[toggledRecordingsIndex] = toggledAudioTranscriptionObject
        viewController.HasTranscriptionUI()
    }
    
    func UpdateToggledTranscriptionText(newText: String, editing: Bool = false) {
        // 1) update in-memory cache
        var finalText: String
        if (editing) {
            finalText = newText
        } else {
            finalText = normalizeTranscript(newText)
        }
        transcriptionManager.toggledTranscriptText = finalText
        toggledAudioTranscriptionObject.transcriptionText = finalText
        savedAudioTranscriptionObjects[toggledRecordingsIndex] = toggledAudioTranscriptionObject
        
        // 2) persist to disk
        // assuming your object has something like `fileURL: URL?` or `transcriptFileURL: URL?`
        if let fileURL = toggledRecordingURL?.deletingPathExtension().appendingPathExtension(transcriptionRecordingExtension) {
            do {
                try finalText.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                print("⚠️ Failed to write updated transcript to disk")
            }
        } else {
            print("⚠️ No transcript file URL on toggledAudioTranscriptionObject")
        }
    }
    
    func normalizeTranscript(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1) Collapse newlines -> spaces
        text = text
            .replacingOccurrences(of: #"\s*(?:\r\n|\r|\n|\u2028|\u2029)+\s*"#,
                                  with: " ",
                                  options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 2) Spoken punctuation -> symbols (with "literal" escape)
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
        var out: [String] = []

        func lower(_ s: String) -> String { s.lowercased() }
        func peek(_ i: Int) -> String? { (i < tokens.count) ? tokens[i] : nil }
        func attach(_ symbol: String) {
            if let last = out.last {
                if !last.hasSuffix(symbol) { out[out.count - 1] = last + symbol }
            } else { out.append(symbol) }
        }
        func dropLiteralAndKeep(_ word: String) { if !out.isEmpty { out.removeLast() }; out.append(word) }

        var i = 0
        while i < tokens.count {
            let cur = tokens[i]
            let curL = lower(cur)
            let prevWord = out.last ?? ""
            let prevIsLiteral = lower(prevWord) == "literal"
            let next = peek(i + 1)
            let nextL = lower(next ?? "")

            if curL == "question", nextL == "mark" {
                if prevIsLiteral { dropLiteralAndKeep(cur); i += 1; if let n = next { out.append(n) } }
                else { attach("?"); i += 1 }
                i += 1; continue
            }
            if curL == "exclamation", (nextL == "mark" || nextL == "point") {
                if prevIsLiteral { dropLiteralAndKeep(cur); i += 1; if let n = next { out.append(n) } }
                else { attach("!"); i += 1 }
                i += 1; continue
            }
            if ["period","comma","colon","semicolon"].contains(curL) {
                if prevIsLiteral { dropLiteralAndKeep(cur) }
                else { attach(["period":".","comma":",","colon":":","semicolon":" ;"][curL] ?? "") }
                i += 1; continue
            }
            out.append(cur)
            i += 1
        }

        // 3) Tidy spacing around punctuation
        var normalized = out.joined(separator: " ")
        normalized = normalized.replacingOccurrences(of: #"\s+([\.,!?\;:])"#,
                                                     with: "$1",
                                                     options: .regularExpression)
        normalized = normalized.replacingOccurrences(of: #"([\.,!?\;:])([^\s"'\)\]\}])"#,
                                                     with: "$1 $2",
                                                     options: .regularExpression)
        normalized = normalized.replacingOccurrences(of: #"\s{2,}"#,
                                                     with: " ",
                                                     options: .regularExpression)
                               .trimmingCharacters(in: .whitespacesAndNewlines)

        // 4) Capitalize the start of sentences (after ., !, ?)
        normalized = sentenceCase(normalized)

        return normalized.isEmpty ? "[Empty transcript]" : normalized
    }

    /// Capitalizes the first alphabetic character of the string and any
    /// alphabetic character that follows `.`, `!`, or `?` (skipping spaces/quotes/brackets).
    private func sentenceCase(_ s: String) -> String {
        var result = ""
        var capitalizeNext = true
        for ch in s {
            if capitalizeNext, ch.isLetter {
                result.append(String(ch).uppercased())
                capitalizeNext = false
            } else {
                result.append(ch)
            }
            if ".!?".contains(ch) { capitalizeNext = true }
            // If you keep newlines anywhere, uncomment:
            // if ch == "\n" { capitalizeNext = true }
        }
        return result
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
        let santizedBaseName = sanitizedBaseName(baseNewName)

        let dir = GetDirectory()

        let oldBase = self.toggledAudioTranscriptionObject.fileName
        if oldBase == santizedBaseName { return }

        // Compute final new base with your duplicate-per-minute suffix
        let n = GetDuplicateIndex(newFileName: santizedBaseName, isNewFile: false)
        let newBase = n > 0 ? "\(santizedBaseName)(\(n))" : santizedBaseName
        
        if (oldBase == newBase) { return }

        // Build URLs
        let oldAudioURL = dir.appendingPathComponent(oldBase).appendingPathExtension(audioRecordingExtension)
        let newAudioURL = dir.appendingPathComponent(newBase).appendingPathExtension(audioRecordingExtension)

        let oldTranscriptURL = dir.appendingPathComponent(oldBase).appendingPathExtension(transcriptionRecordingExtension)
        let newTranscriptURL = dir.appendingPathComponent(newBase).appendingPathExtension(transcriptionRecordingExtension)

        do {
            // 1) Rename audio first
            try FileManager.default.moveItem(at: oldAudioURL, to: newAudioURL)

            // 2) If there is a transcript, rename it too
            if FileManager.default.fileExists(atPath: oldTranscriptURL.path) {
                do {
                    try FileManager.default.moveItem(at: oldTranscriptURL, to: newTranscriptURL)
                } catch {
                    // Roll back audio rename if transcript rename fails
                    try? FileManager.default.moveItem(at: newAudioURL, to: oldAudioURL)
                    throw error
                }
            }

            // 3) Update in-memory model + UI
            self.savedAudioTranscriptionObjects[self.toggledRecordingsIndex].fileName = newBase
            self.toggledAudioTranscriptionObject = self.savedAudioTranscriptionObjects[self.toggledRecordingsIndex]
            self.setToggledRecordingURL() // Make sure this recalculates from fileName
            viewController.FileNameLabel.setTitle(newBase, for: .normal)
            saveAudioTranscriptionObjectsToUserDefaults()
            
            // 4) Refresh cached transcript URL and in-memory transcript text
            self.toggledTranscriptURL = self.toggledRecordingURL?
                .deletingPathExtension()
                .appendingPathExtension(self.transcriptionRecordingExtension)

            // If a transcript file exists for the renamed recording, reload it into cache
            if let transcriptURL = self.toggledTranscriptURL,
               FileManager.default.fileExists(atPath: transcriptURL.path) {
                do {
                    let text = try String(contentsOf: transcriptURL, encoding: .utf8)
                    self.toggledAudioTranscriptionObject.transcriptionText = text
                    self.savedAudioTranscriptionObjects[self.toggledRecordingsIndex] = self.toggledAudioTranscriptionObject
                    self.transcriptionManager.toggledTranscriptText = text
                    // Optionally update UI to reflect that a transcript is available and current
                    self.viewController.HasTranscriptionUI()
                } catch {
                    print("⚠️ Failed to reload transcript after rename")
                }
            } else {
                // No transcript file — clear cached text to avoid stale data
                self.toggledAudioTranscriptionObject.transcriptionText = nil
                self.savedAudioTranscriptionObjects[self.toggledRecordingsIndex] = self.toggledAudioTranscriptionObject
                self.transcriptionManager.toggledTranscriptText = nil
                self.viewController.NoTranscriptionUI()
            }

        } catch {
            ProgressHUD.failed("We were unable to rename your file.")
            print("Failed to rename file")
        }
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
        var duplicateIndexes: [Int] = []
        var lowestAvailableIndex : Int = 0
        let toggledFileNameBase = toggledAudioTranscriptionObject.fileName.split(separator: "(")[0]
        let toggledFileNameIndex : Int = extractDigits(from: toggledAudioTranscriptionObject.fileName)
        
        for object in savedAudioTranscriptionObjects {
            let name = object.fileName
            let split = name.split(separator: "(")
            let base = String(split[0])
            let index = extractDigits(from: name)
            if (base == newFileName) {
                if (toggledFileNameBase == base && !isNewFile) {
                    if (toggledFileNameIndex != index) {
                        duplicateIndexes.append(index)
                    }
                } else {
                    duplicateIndexes.append(index)
                }
            }
        }
        
        if (duplicateIndexes.isEmpty) {
            return 0
        } else {
            while(duplicateIndexes.contains(lowestAvailableIndex)) {
                lowestAvailableIndex += 1
            }
        }

        return lowestAvailableIndex
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
