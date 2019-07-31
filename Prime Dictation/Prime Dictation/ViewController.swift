//
//  ViewController.swift
//  Prime Dictation
//
//  Created by Bryce Albertazzi on 7/28/19.
//  Copyright © 2019 Bryce Albertazzi. All rights reserved.
//

import UIKit
import AVFoundation

class ViewController: UIViewController, AVAudioRecorderDelegate {

    @IBOutlet weak var ListenLabel: UIButton!
    @IBOutlet weak var RecordLabel: UIButton!
    @IBOutlet weak var SendLabel: UIButton!
    @IBOutlet weak var FileNameLabel: UIButton!
    @IBOutlet weak var PreviousRecordingLabel: UIButton!
    @IBOutlet weak var NextRecordingLabel: UIButton!
    
    
    var recordingSession: AVAudioSession! //Communicates how you intend to use audio within your app
    var audioRecorder: AVAudioRecorder! //Responsible for recording our audio
    var audioPlayer: AVAudioPlayer!
    
    var numberOfRecordings: Int = 0
    
    var userSelectedFileType = 0
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
        ListenLabel.setTitle("Listen", for: .normal)
        //Initialize recording session
        recordingSession = AVAudioSession.sharedInstance()
        
        //Request permission
        AVAudioSession.sharedInstance().requestRecordPermission { (hasPermission) in
            print("Accepted")
        }
        savedRecordingNames = UserDefaults.standard.object(forKey: savedRecordingsKey) as? [String] ?? [String]()
            
        for recording in savedRecordingNames {
            print(recording)
        }
        if (savedRecordingNames.count > 1) {
        FileNameLabel.setTitle(savedRecordingNames[savedRecordingNames.count - 1], for: .normal)
        
        toggledRecordingsIndex = savedRecordingNames.count - 1
        toggledRecordingName = savedRecordingNames[toggledRecordingsIndex]
        NextRecordingLabel.isEnabled = false
        } else if (savedRecordingNames.count == 1) {
            toggledRecordingsIndex = savedRecordingNames.count - 1
            toggledRecordingName = savedRecordingNames[toggledRecordingsIndex]
            FileNameLabel.setTitle(toggledRecordingName, for: .normal)
            PreviousRecordingLabel.isEnabled = false
            NextRecordingLabel.isEnabled = false
        }
        else
        {
            PreviousRecordingLabel.isEnabled = false
            NextRecordingLabel.isEnabled = false
        }
        
        print(savedRecordingNames.count)
        print(GetDirectory())
        
    }
    
    let recordingExtension: String = "m4a"
    let destinationRecordingExtension: String = "wav"
    var recordingName: String = String()
    
    @IBAction func ListenButton(_ sender: Any) {
        //Store the path to the recording in this "path" variable
        //savedRecordingNames = []
        //UserDefaults.standard.set(savedRecordingNames, forKey: savedRecordingsKey)
        let previousRecordingPath = GetDirectory().appendingPathComponent(toggledRecordingName).appendingPathExtension(destinationRecordingExtension)
        
        //Play the previously recorded recording
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: previousRecordingPath)
            audioPlayer.play()
        } catch {
            displayAlert(title: "Error!", message: "Could not play recording, no recording exists or you have bad connection")
        }
    }
    //Stores the current recording in queue the user wants to listen to
    var toggledRecordingName: String = String()
    var toggledRecordingsIndex: Int = Int()
    
    @IBAction func PreviousRecordingButton(_ sender: Any) {
        CheckToggledRecordingsIndex(goingToPreviousRecording: true)
        print(toggledRecordingsIndex)
        toggledRecordingName = savedRecordingNames[toggledRecordingsIndex]
        FileNameLabel.setTitle(toggledRecordingName, for: .normal)
        
    }
    
    @IBAction func NextRecordingButton(_ sender: Any) {
        CheckToggledRecordingsIndex(goingToPreviousRecording: false)
        toggledRecordingName = savedRecordingNames[toggledRecordingsIndex]
        print(toggledRecordingsIndex)
        FileNameLabel.setTitle(toggledRecordingName, for: .normal)
    }
    
    func CheckToggledRecordingsIndex(goingToPreviousRecording: Bool) {
        if (goingToPreviousRecording) {
            //Index bounds check for previous recording button
            if (toggledRecordingsIndex <= 1) {
                toggledRecordingsIndex -= 1
                PreviousRecordingLabel.isEnabled = false
                if (savedRecordingNames.count == 2) {
                    NextRecordingLabel.isEnabled = true
                }
                
            } else {
                if (!NextRecordingLabel.isEnabled) {
                    NextRecordingLabel.isEnabled = true
                }
                toggledRecordingsIndex -= 1
            }
        } else {
            //Index bounds check for next recording button
            if (toggledRecordingsIndex >= savedRecordingNames.count - 2) {
                toggledRecordingsIndex += 1
                NextRecordingLabel.isEnabled = false
                if (savedRecordingNames.count == 2) {
                    PreviousRecordingLabel.isEnabled = true
                }
            } else {
                if (!PreviousRecordingLabel.isEnabled) {
                    PreviousRecordingLabel.isEnabled = true
                }
                toggledRecordingsIndex += 1
            }
        }
    }

    
    @IBAction func RecordButton(_ sender: Any) {
        //Check if we have an active recorder
        if audioRecorder == nil {
            //If we are not already recording audio, start the recording
            numberOfRecordings += 1
            recordingName = RecordingTimeForName()
            let fileName = GetDirectory().appendingPathComponent(recordingName).appendingPathExtension(recordingExtension)
            
            let settings = [ AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            //Start the recording
            do {
                audioRecorder = try AVAudioRecorder(url: fileName, settings: settings)
                audioRecorder.delegate = self
                audioRecorder.record()
                RecordLabel.setTitle("Stop", for: .normal)
                ListenLabel.isEnabled = false
            } catch {
                displayAlert(title: "Error!", message: "Could not play recording, check your connection")
            }
        } else {
            //If we are already recording audio, stop the recording
            audioRecorder.stop()
            audioRecorder = nil
            RecordLabel.setTitle("Record", for: .normal)
            ListenLabel.isEnabled = true
            
            //Convert the audio
            ConvertAudio(GetDirectory().appendingPathComponent(recordingName).appendingPathExtension(recordingExtension), outputURL: GetDirectory().appendingPathComponent(recordingName).appendingPathExtension(destinationRecordingExtension))
            
            //Save the number of recordings
            UserDefaults.standard.set(numberOfRecordings, forKey: "myNumber")
            
            //Set the file name label to name or recording
            UpdateSavedRecordings()
        
        }
        
    }
    
    var savedRecordingsKey: String = "savedRecordings"
    var savedRecordingNames: [String] = []
    let maxNumSavedRecordings = 5
    
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
                displayAlert(title: "Error!", message: "Could not delete oldest recording in queue")
            }
            savedRecordingNames.append(recordingName)
        }
        UserDefaults.standard.set(savedRecordingNames, forKey: savedRecordingsKey)
        toggledRecordingsIndex = savedRecordingNames.count - 1
        toggledRecordingName = savedRecordingNames[toggledRecordingsIndex]
        
        if (savedRecordingNames.count >= 2) {
        NextRecordingLabel.isEnabled = false
        PreviousRecordingLabel.isEnabled = true
        }
        
        FileNameLabel.setTitle(toggledRecordingName, for: .normal)
        
        for recording in savedRecordingNames {
            print(recording)
        }
        
        print(savedRecordingNames.count)
        
        print(toggledRecordingsIndex)
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
        let dateName = String(year) + "-" + String(month) + "-" + String(day) + "_" + String(hour) + "-" + String(minute) + "-" + String(second)
        
        return dateName
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
    
    //Display an alert if something goes wrong
    func displayAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
        present(alert, animated: true, completion: nil)
    }
    
    func ConvertAudio(_ url: URL, outputURL: URL) {
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
        
        dstFormat.mSampleRate = 44100  //Set sample rate
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
    
    @IBAction func SendButton(_ sender: Any) {
        
    }
    
    
}



