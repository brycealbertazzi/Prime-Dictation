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

class RecordingManager {
    
    var viewController: ViewController!
    var sampleRate = 16000
    
    let recordingExtension: String = "m4a"
    let destinationRecordingExtension: String = "wav"
    var recordingName: String = String()
    
    var savedRecordingsKey: String = "savedRecordings"
    var savedRecordingNames: [String] = []
    let maxNumSavedRecordings = 10
    
    //Stores the current recording in queue the user wants to listen to
    var toggledRecordingName: String = String()
    var toggledRecordingsIndex: Int = Int()
    
    var numberOfRecordings: Int = 0
    
    init (viewController: ViewController) {
        self.viewController = viewController
    }
    
    func SetSavedRecordingsOnLoad()
    {
        savedRecordingNames = UserDefaults.standard.object(forKey: savedRecordingsKey) as? [String] ?? [String]()
        
        if (savedRecordingNames.count > 1) {
            viewController.FileNameLabel.setTitle(savedRecordingNames[savedRecordingNames.count - 1] + ".wav", for: .normal)
        
            toggledRecordingsIndex = savedRecordingNames.count - 1
            toggledRecordingName = savedRecordingNames[toggledRecordingsIndex]
            viewController.NextRecordingLabel.isEnabled = false
        } else if (savedRecordingNames.count == 1) {
            toggledRecordingsIndex = savedRecordingNames.count - 1
            toggledRecordingName = savedRecordingNames[toggledRecordingsIndex]
            viewController.FileNameLabel.setTitle(toggledRecordingName + ".wav", for: .normal)
            viewController.PreviousRecordingLabel.isEnabled = false
            viewController.NextRecordingLabel.isEnabled = false
        }
        else
        {
            viewController.PreviousRecordingLabel.isEnabled = false
            viewController.NextRecordingLabel.isEnabled = false
        }
    }
    
    func UpdateSavedRecordings() {
        if savedRecordingNames.count < maxNumSavedRecordings {
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
        toggledRecordingsIndex = savedRecordingNames.count - 1
        toggledRecordingName = savedRecordingNames[toggledRecordingsIndex]
        
        if (savedRecordingNames.count >= 2) {
            viewController.NextRecordingLabel.isEnabled = false
            viewController.PreviousRecordingLabel.isEnabled = true
        }
        
        viewController.FileNameLabel.setTitle(toggledRecordingName + ".wav", for: .normal)
    
    }
    
    func RecordingTimeForName() -> String {
        let date = Date()
        let calendar = Calendar.current
        
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let second = calendar.component(.second, from: date)
        
        let dateName = String(format: "%04d-%02d-%02d_%02d-%02d-%02d",
                              year, month, day, hour, minute, second)
        
        return dateName
    }
    
    func CheckToggledRecordingsIndex(goingToPreviousRecording: Bool) {
        if (goingToPreviousRecording) {
            //Index bounds check for previous recording button
            if (toggledRecordingsIndex <= 1) {
                toggledRecordingsIndex -= 1
                viewController.PreviousRecordingLabel.isEnabled = false
                if (savedRecordingNames.count == 2) {
                    viewController.NextRecordingLabel.isEnabled = true
                }
                
            } else {
                if (!viewController.NextRecordingLabel.isEnabled) {
                    viewController.NextRecordingLabel.isEnabled = true
                }
                toggledRecordingsIndex -= 1
            }
        } else {
            //Index bounds check for next recording button
            if (toggledRecordingsIndex >= savedRecordingNames.count - 2) {
                toggledRecordingsIndex += 1
                viewController.NextRecordingLabel.isEnabled = false
                if (savedRecordingNames.count == 2) {
                    viewController.PreviousRecordingLabel.isEnabled = true
                }
            } else {
                if (!viewController.PreviousRecordingLabel.isEnabled) {
                    viewController.PreviousRecordingLabel.isEnabled = true
                }
                toggledRecordingsIndex += 1
            }
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
