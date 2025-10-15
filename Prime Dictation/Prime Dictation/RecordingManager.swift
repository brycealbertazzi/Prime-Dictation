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
    let destinationRecordingExtension: String = "wav"
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
                try FileManager.default.removeItem(at: GetDirectory().appendingPathComponent(oldestRecording).appendingPathExtension("wav"))
                try FileManager.default.removeItem(at: GetDirectory().appendingPathComponent(oldestRecording).appendingPathExtension("m4a"))
            } catch {
                viewController.displayAlert(title: "Error!", message: "Could not delete oldest recording in queue")
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
        
        do {
            try FileManager.default.moveItem(at: GetDirectory().appendingPathComponent(oldName).appendingPathExtension("wav"), to: GetDirectory().appendingPathComponent(newName).appendingPathExtension("wav"))
            self.savedRecordingNames[self.toggledRecordingsIndex] = newName
            self.toggledRecordingName = newName
            viewController.FileNameLabel.setTitle(newName, for: .normal)
            UserDefaults.standard.set(self.savedRecordingNames, forKey: self.savedRecordingsKey)
        } catch {
            ProgressHUD.failed("Failed to remane file")
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
    
    func ConvertAudio() {
        let url = GetDirectory().appendingPathComponent(recordingName).appendingPathExtension(recordingExtension)
        let outputURL = GetDirectory().appendingPathComponent(recordingName).appendingPathExtension(destinationRecordingExtension)
        
        var error : OSStatus = noErr
        var destinationFile: ExtAudioFileRef? = nil
        var sourceFile : ExtAudioFileRef? = nil
        
        var srcFormat : AudioStreamBasicDescription = AudioStreamBasicDescription()
        var dstFormat : AudioStreamBasicDescription = AudioStreamBasicDescription()
        
        ExtAudioFileOpenURL(url as CFURL, &sourceFile)
        
        var thePropertySize: UInt32 = UInt32(MemoryLayout.stride(ofValue: srcFormat))
        
        ExtAudioFileGetProperty(sourceFile!,
                                kExtAudioFileProperty_FileDataFormat,
                                &thePropertySize, &srcFormat)
        
        dstFormat.mSampleRate = Float64(sampleRate)  //Set sample rate
        dstFormat.mFormatID = kAudioFormatLinearPCM
        dstFormat.mChannelsPerFrame = 1
        dstFormat.mBitsPerChannel = 16
        dstFormat.mBytesPerPacket = 2 * dstFormat.mChannelsPerFrame
        dstFormat.mBytesPerFrame = 2 * dstFormat.mChannelsPerFrame
        dstFormat.mFramesPerPacket = 1
        dstFormat.mFormatFlags = kLinearPCMFormatFlagIsPacked |
        kAudioFormatFlagIsSignedInteger
        
        // Create destination file
        error = ExtAudioFileCreateWithURL(
            outputURL as CFURL,
            kAudioFileWAVEType,
            &dstFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &destinationFile)
        print("Error 1 in convertAudio: \(error.description)")
        
        error = ExtAudioFileSetProperty(sourceFile!,
                                        kExtAudioFileProperty_ClientDataFormat,
                                        thePropertySize,
                                        &dstFormat)
        print("Error 2 in convertAudio: \(error.description)")
        
        error = ExtAudioFileSetProperty(destinationFile!,
                                        kExtAudioFileProperty_ClientDataFormat,
                                        thePropertySize,
                                        &dstFormat)
        print("Error 3 in convertAudio: \(error.description)")
        
        let bufferByteSize : UInt32 = 32768
        var srcBuffer = [UInt8](repeating: 0, count: 32768)
        var sourceFrameOffset : ULONG = 0
        
        while(true){
            var fillBufList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(srcBuffer.count),
                    mData: &srcBuffer
                )
            )
            var numFrames : UInt32 = 0
            
            if(dstFormat.mBytesPerFrame > 0){
                numFrames = bufferByteSize / dstFormat.mBytesPerFrame
            }
            
            error = ExtAudioFileRead(sourceFile!, &numFrames, &fillBufList)
            print("Error 4 in convertAudio: \(error.description)")
            
            if(numFrames == 0){
                error = noErr;
                break;
            }
            
            sourceFrameOffset += numFrames
            error = ExtAudioFileWrite(destinationFile!, numFrames, &fillBufList)
            print("Error 5 in convertAudio: \(error.description)")
        }
        
        error = ExtAudioFileDispose(destinationFile!)
        print("Error 6 in convertAudio: \(error.description)")
        error = ExtAudioFileDispose(sourceFile!)
        print("Error 7 in convertAudio: \(error.description)")
    
    }
}
