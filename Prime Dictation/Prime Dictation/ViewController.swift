//
//  ViewController.swift
//  Prime Dictation
//
//  Created by Bryce Albertazzi on 7/28/19.
//  Copyright © 2019 Bryce Albertazzi. All rights reserved.
//

import UIKit
import AVFoundation
import SwiftyDropbox
import DropboxAuth
import ProgressHUD

class ViewController: UIViewController, AVAudioRecorderDelegate, UIApplicationDelegate, AVAudioPlayerDelegate {

    @IBOutlet weak var TitleOfAppLabel: UILabel!
    @IBOutlet weak var ListenLabel: UIButton!
    @IBOutlet weak var RecordLabel: UIButton!
    @IBOutlet weak var SendLabel: UIButton!
    @IBOutlet weak var FileNameLabel: UIButton!
    @IBOutlet weak var PreviousRecordingLabel: UIButton!
    @IBOutlet weak var NextRecordingLabel: UIButton!
    @IBOutlet weak var SignInLabel: UIButton!
    @IBOutlet weak var PausePlayButtonLabel: UIButton!
    @IBOutlet weak var StopButtonLabel: UIButton!
    @IBOutlet weak var PausePlaybackLabel: UIButton!
    @IBOutlet weak var EndPlaybackLabel: UIButton!
    @IBOutlet weak var StopWatchLabel: UILabel!
    
    
    var recordingSession: AVAudioSession! //Communicates how you intend to use audio within your app
    var audioRecorder: AVAudioRecorder! //Responsible for recording our audio
    var audioPlayer: AVAudioPlayer!
    
    var numberOfRecordings: Int = 0
    
    var userSelectedFileType = 0
    
    //MARK: View did load
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
        ListenLabel.setTitle("Listen", for: .normal)
        RecordLabel.isHidden = false
        StopButtonLabel.isHidden = true
        PausePlayButtonLabel.isHidden = true
        EndPlaybackLabel.isHidden = true
        PausePlaybackLabel.isHidden = true
        StopWatchLabel.isHidden = true
        /*****/
        //FileNameLabel should be disabled at all times
        FileNameLabel.isEnabled = false
        /*****/
        //Initialize recording session
        recordingSession = AVAudioSession.sharedInstance()
        RecordLabel.setImage(UIImage(named: "RecordButton"), for: .normal)
        //Request permission
        AVAudioSession.sharedInstance().requestRecordPermission { (hasPermission) in
            print("Accepted")
        }
        savedRecordingNames = UserDefaults.standard.object(forKey: savedRecordingsKey) as? [String] ?? [String]()
            
        for recording in savedRecordingNames {
            print(recording)
        }
        if (savedRecordingNames.count > 1) {
        FileNameLabel.setTitle(savedRecordingNames[savedRecordingNames.count - 1] + ".wav", for: .normal)
        
        toggledRecordingsIndex = savedRecordingNames.count - 1
        toggledRecordingName = savedRecordingNames[toggledRecordingsIndex]
        NextRecordingLabel.isEnabled = false
        } else if (savedRecordingNames.count == 1) {
            toggledRecordingsIndex = savedRecordingNames.count - 1
            toggledRecordingName = savedRecordingNames[toggledRecordingsIndex]
            FileNameLabel.setTitle(toggledRecordingName + ".wav", for: .normal)
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
    
    //MARK: Listen to Playback
    let recordingExtension: String = "m4a"
    let destinationRecordingExtension: String = "wav"
    var recordingName: String = String()
    
    @IBAction func ListenButton(_ sender: Any) {
        
            //Store the path to the recording in this "path" variable
            let previousRecordingPath = GetDirectory().appendingPathComponent(toggledRecordingName).appendingPathExtension(destinationRecordingExtension)
            
            //Play the previously recorded recording
            do {
                try recordingSession.setCategory(.playback)
                audioPlayer = try AVAudioPlayer(contentsOf: previousRecordingPath)
                audioPlayer?.delegate = self
                audioPlayer.prepareToPlay()
                audioPlayer.volume = 1
                audioPlayer.play()
                
                ListenLabel.isHidden = true
                StopWatchLabel.isHidden = false
                RecordLabel.isEnabled = false
                SendLabel.isEnabled = false
                SendLabel.setTitleColor(UIColor(red: 0, green: 0, blue: 0, alpha: 0.3), for: .normal)
                SignInLabel.isEnabled = false
                SignInLabel.setTitleColor(UIColor(red: 0, green: 0, blue: 0, alpha: 0.3), for: .normal)
                PausePlaybackLabel.isHidden = false
                EndPlaybackLabel.isHidden = false
                Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true, block: UpdateElapsedTimeListen(timer:))
                watch.start()
            } catch {
                displayAlert(title: "Error!", message: "Could not play recording, no recording exists or you have bad connection")
            }
        
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if audioPlayer.currentTime <= 0 {
            player.delegate = self
            ListenLabel.setTitle("Listen", for: .normal)
            ListenLabel.isHidden = false
            StopWatchLabel.isHidden = true
            PausePlaybackLabel.isHidden = true
            EndPlaybackLabel.isHidden = true
            RecordLabel.isEnabled = true
            SendLabel.setTitleColor(UIColor.black, for: .normal)
            SendLabel.isEnabled = true
            SignInLabel.isEnabled = true
            SignInLabel.setTitleColor(UIColor.black, for: .normal)
            watch.stop()
            print("Audio player didFinishPlaying")
        }
    }
    

    
    //Stores the current recording in queue the user wants to listen to
    var toggledRecordingName: String = String()
    var toggledRecordingsIndex: Int = Int()
    
    @IBAction func PreviousRecordingButton(_ sender: Any) {
        CheckToggledRecordingsIndex(goingToPreviousRecording: true)
        toggledRecordingName = savedRecordingNames[toggledRecordingsIndex]
        FileNameLabel.setTitle(toggledRecordingName + ".wav", for: .normal)
        
    }
    
    @IBAction func NextRecordingButton(_ sender: Any) {
        CheckToggledRecordingsIndex(goingToPreviousRecording: false)
        toggledRecordingName = savedRecordingNames[toggledRecordingsIndex]
        FileNameLabel.setTitle(toggledRecordingName + ".wav", for: .normal)
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

    let sampleRate = 4000
    @IBAction func RecordButton(_ sender: Any) {
        //Check if we have an active recorder
        if audioRecorder == nil {
            //If we are not already recording audio, start the recording
            numberOfRecordings += 1
            recordingName = RecordingTimeForName()
            let fileName = GetDirectory().appendingPathComponent(recordingName).appendingPathExtension(recordingExtension)
            
            let settings = [ AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.low.rawValue,
            ]
            //Start the recording
            do {
                try recordingSession.setCategory(.record)
                audioRecorder = try AVAudioRecorder(url: fileName, settings: settings)
                audioRecorder.delegate = self
                audioRecorder.record()
                ListenLabel.isHidden = true
                SendLabel.isEnabled = false
                RecordLabel.isHidden = true
                StopButtonLabel.isHidden = false
                PausePlayButtonLabel.isHidden = false
                SendLabel.isEnabled = false
                SendLabel.setTitleColor(UIColor(red: 0, green: 0, blue: 0, alpha: 0.3), for: .normal)
                SignInLabel.isEnabled = false
                SignInLabel.setTitleColor(UIColor(red: 0, green: 0, blue: 0, alpha: 0.3), for: .normal)
                
                //Start Timer
                Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true, block: UpdateElapsedTime(timer:))
                watch.start()
                StopWatchLabel.isHidden = false
            } catch {
                displayAlert(title: "Error!", message: "Could not play recording, check your connection")
            }
        }
        
    }
    
    //MARK: Stopwatch
    
    let watch: Stopwatch = Stopwatch()
    
    func UpdateElapsedTime(timer: Timer) {
        if watch.isRunning && !isRecordingPaused {
            let minutes = Int(watch.elapsedTime / 60)
            let seconds = Int(watch.elapsedTime.truncatingRemainder(dividingBy: 60))
            let tensOfSeconds = Int((watch.elapsedTime * 10).truncatingRemainder(dividingBy: 10))
            StopWatchLabel.text = String(format: "%d:%02d.%d", minutes, seconds, tensOfSeconds)
        } else {
            timer.invalidate()
        }
    }
    
    func UpdateElapsedTimeListen(timer: Timer) {
        if watch.isRunning && !isRecordingPaused {
            let minutes = Int(watch.elapsedTime / 60)
            let seconds = Int(watch.elapsedTime.truncatingRemainder(dividingBy: 60))
            let tensOfSeconds = Int((watch.elapsedTime * 10).truncatingRemainder(dividingBy: 10))
            let minutesTotal = Int(audioPlayer.duration / 60)
            let secondsTotal = Int(audioPlayer.duration.truncatingRemainder(dividingBy: 60))
            let tensOfSecondsTotal = Int((audioPlayer.duration * 10).truncatingRemainder(dividingBy: 10))
            StopWatchLabel.text = String(format: "%d:%02d.%d", minutes, seconds, tensOfSeconds) + "/" + String(format: "%d:%02d.%d", minutesTotal, secondsTotal, tensOfSecondsTotal)
        } else {
            timer.invalidate()
        }
    }
    
    //MARK: Pause-Resume-End Recordings and Playbacks:
    
    @IBAction func StopRecordingButton(_ sender: Any) {
        //If we are already recording audio, stop the recording
        audioRecorder.stop()
        isRecordingPaused = false
        audioRecorder = nil
        ListenLabel.isHidden = false
        ListenLabel.setTitle("Listen", for: .normal)
        SendLabel.isEnabled = true
        RecordLabel.isHidden = false
        StopButtonLabel.isHidden = true
        PausePlayButtonLabel.isHidden = true
        PausePlayButtonLabel.setImage(UIImage(named: "PauseButton"), for: .normal)
        SendLabel.setTitleColor(UIColor.black, for: .normal)
        SendLabel.isEnabled = true
        SignInLabel.isEnabled = true
        SignInLabel.setTitleColor(UIColor.black, for: .normal)
        
        //Convert the audio
        ConvertAudio(GetDirectory().appendingPathComponent(recordingName).appendingPathExtension(recordingExtension), outputURL: GetDirectory().appendingPathComponent(recordingName).appendingPathExtension(destinationRecordingExtension))
        
        //Save the number of recordings
        UserDefaults.standard.set(numberOfRecordings, forKey: "myNumber")
        
        //Set the file name label to name or recording
        UpdateSavedRecordings()
        
        watch.stop()
        StopWatchLabel.isHidden = true
    }
    
    var isRecordingPaused: Bool = false
    @IBAction func PausePlayRecordingButton(_ sender: Any) {
        if audioRecorder.isRecording {
            PausePlayButtonLabel.setImage(UIImage(named: "PlayButton"), for: .normal)
            audioRecorder.pause()
            isRecordingPaused = true
            watch.pause()
        } else {
            PausePlayButtonLabel.setImage(UIImage(named: "PauseButton"), for: .normal)
            audioRecorder.record()
            isRecordingPaused = false
            watch.resume()
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true, block: UpdateElapsedTime(timer:))
        }
        print("AudioRecorder is Playing: \(audioRecorder.isRecording)")
    }
    
    @IBAction func EndPlaybackButton(_ sender: Any) {
        ListenLabel.setTitle("Listen", for: .normal)
        PausePlaybackLabel.setTitle("Pause", for: .normal)
        isRecordingPaused = false
        StopWatchLabel.isHidden = true
        audioPlayer.stop()
        watch.stop()
        SendLabel.setTitleColor(UIColor.black, for: .normal)
        SendLabel.isEnabled = true
        SignInLabel.isEnabled = true
        SignInLabel.setTitleColor(UIColor.black, for: .normal)
        /*************/
        ListenLabel.isHidden = false
        RecordLabel.isEnabled = true
        PausePlaybackLabel.isHidden = true
        EndPlaybackLabel.isHidden = true
    }
    
    
    @IBAction func PausePlaybackButton(_ sender: Any) {
        if audioPlayer.isPlaying {
            //Pause Recording
            audioPlayer.pause()
            isRecordingPaused = true
            PausePlaybackLabel.setTitle("Resume", for: .normal)
            watch.pause()
        } else {
            //Resume Recording
            audioPlayer?.delegate = self
            audioPlayer.prepareToPlay()
            audioPlayer.volume = 1
            audioPlayer.play()
            PausePlaybackLabel.setTitle("Pause", for: .normal)
            watch.resume()
            isRecordingPaused = false
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true, block: UpdateElapsedTimeListen(timer:))
            
        }
    }
    
    var savedRecordingsKey: String = "savedRecordings"
    var savedRecordingNames: [String] = []
    let maxNumSavedRecordings = 10
    
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
        
        FileNameLabel.setTitle(toggledRecordingName + ".wav", for: .normal)
    
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
    
    @IBAction func SendButton(_ sender: Any) {
        if let client: DropboxClient = DropboxClientsManager.authorizedClient {
            print("Client is already authorized")
            if savedRecordingNames.count > 0 {
                ProgressHUD.show("Sending...")
                SignInLabel.isEnabled = false
                SendLabel.isEnabled = false
                SignInLabel.setTitleColor(UIColor(red: 0, green: 0, blue: 0, alpha: 0.3), for: .normal)
                SendLabel.setTitleColor(UIColor(red: 0, green: 0, blue: 0, alpha: 0.3), for: .normal)
                RecordLabel.isEnabled = false
                ListenLabel.isEnabled = false
                FileNameLabel.setTitleColor(UIColor(red: 0, green: 0, blue: 0, alpha: 0.3), for: .normal)
                TitleOfAppLabel.textColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0.3)
                PreviousRecordingLabel.isEnabled = false
                NextRecordingLabel.isEnabled = false
                PreviousRecordingLabel.setTitleColor(UIColor(red: 0, green: 0, blue: 0, alpha: 0.3), for: .normal)
                NextRecordingLabel.setTitleColor(UIColor(red: 0, green: 0, blue: 0, alpha: 0.3), for: .normal)
                
                
                //Send recording to dropbox folder for this app
                let recordingToUpload: URL = GetDirectory().appendingPathComponent(toggledRecordingName).appendingPathExtension(destinationRecordingExtension)
                    _ = client.files.upload(path: "/" + toggledRecordingName + "." + destinationRecordingExtension, input: recordingToUpload)
                        .response { (response, error) in
                            if let response = response {
                                print(response)
                                ProgressHUD.showSuccess("Recording was sent to Dropbox", interaction: true)
                            } else if let error = error {
                                print(error)
                                ProgressHUD.showError("Failed to send recording to dropbox, check your connections", interaction: true)
                            }
                            self.SignInLabel.setTitleColor(UIColor.black, for: .normal)
                            self.SendLabel.setTitleColor(UIColor.black, for: .normal)
                            self.SignInLabel.isEnabled = true
                            self.SendLabel.isEnabled = true
                            self.RecordLabel.isEnabled = true
                            self.ListenLabel.isEnabled = true
                            self.FileNameLabel.setTitleColor(UIColor.black, for: .normal)
                            self.TitleOfAppLabel.textColor = UIColor.black
                            self.PreviousRecordingLabel.isEnabled = true
                            self.NextRecordingLabel.isEnabled = true
                            self.PreviousRecordingLabel.setTitleColor(UIColor.black, for: .normal)
                            self.NextRecordingLabel.setTitleColor(UIColor.black, for: .normal)
                        }
                        .progress { (progressData) in
                            print(progressData)
                        }
            } else {
                ProgressHUD.showError("No recording to send")
            }
        } else {
            OpenAuthorizationFlow()
        }
    }
    
    @IBAction func SignInButton(_ sender: Any) {
        OpenAuthorizationFlow()
    }
    
    
   
    var url: URL = URL(string: "https://www.dropbox.com/oauth2/authorize")!
    func OpenAuthorizationFlow() {
        DropboxClientsManager.authorizeFromController(UIApplication.shared, controller: self) { (url) in
            DropboxClientsManager.authorizeFromController(UIApplication.shared, controller: self, openURL: { (url) in
                if UIApplication.shared.canOpenURL(url) {
                    UIApplication.shared.open(url, completionHandler: nil)
                } else {
                    print("Cannot open authorization URL")
                    ProgressHUD.showError("Cannot connect to Dropbox servers, check your connection")
                }
            })
        }
    }
    
}



