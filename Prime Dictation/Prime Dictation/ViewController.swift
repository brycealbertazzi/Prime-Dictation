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
import ProgressHUD

class ViewController: UIViewController, AVAudioRecorderDelegate, UIApplicationDelegate, AVAudioPlayerDelegate {

    //MARK: - IBOutlets
    @IBOutlet weak var TitleOfAppLabel: UILabel!
    @IBOutlet weak var ListenLabel: UIButton!
    @IBOutlet weak var RecordLabel: UIButton!
    @IBOutlet weak var SendLabel: UIButton!
    @IBOutlet weak var DestinationLabel: UIButton!
    @IBOutlet weak var FileNameLabel: UIButton!
    @IBOutlet weak var PreviousRecordingLabel: UIButton!
    @IBOutlet weak var NextRecordingLabel: UIButton!
    @IBOutlet weak var PausePlayButtonLabel: UIButton!
    @IBOutlet weak var StopButtonLabel: UIButton!
    @IBOutlet weak var PausePlaybackLabel: UIButton!
    @IBOutlet weak var EndPlaybackLabel: UIButton!
    @IBOutlet weak var StopWatchLabel: UILabel!
        
    var recordingSession: AVAudioSession! //Communicates how you intend to use audio within your app
    var audioRecorder: AVAudioRecorder! //Responsible for recording our audio
    var audioPlayer: AVAudioPlayer!
    
    var dropboxManager: DropboxManager!
    var oneDriveManager: OneDriveManager!
    var destinationManager: DestinationManager!
    
    var recordingManager: RecordingManager!
    var watch: Stopwatch!
    
    //MARK: View did load
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let services = AppServices.shared
        recordingManager = services.recordingManager
        dropboxManager = services.dropboxManager
        oneDriveManager = services.oneDriveManager
        destinationManager = services.destinationManager
        
        recordingManager.attach(viewController: self)
        dropboxManager.attach(viewController: self, recordingManager: recordingManager)
        oneDriveManager.attach(viewController: self, recordingManager: recordingManager)

        watch = Stopwatch(viewController: self)
        
        destinationManager.getDestination()
        
        // Do any additional setup after loading the view.
        ListenLabel.setTitle("Listen", for: .normal)
        HideRecordingInProgressUI()
        HideListeningUI()
        
        //FileNameLabel should be disabled at all times
        FileNameLabel.isEnabled = false
        /*****/
        //Initialize recording session
        recordingSession = AVAudioSession.sharedInstance()
        RecordLabel.setImage(UIImage(named: "RecordButton"), for: .normal)
        //Request permission
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                if granted {
                    print("Mic access granted")
                } else {
                    print("Mic access denied")
                }
            }
        } else {
            // Fallback for older iOS versions
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                if granted {
                    print("Mic access granted")
                } else {
                    print("Mic access denied")
                }
            }
        }
        recordingManager.SetSavedRecordingsOnLoad()
    }
    
    //MARK: Listen to Playback
    @IBAction func ListenButton(_ sender: Any) {
        //Store the path to the recording in this "path" variable
        let previousRecordingPath = recordingManager.GetDirectory().appendingPathComponent(recordingManager.toggledRecordingName).appendingPathExtension(recordingManager.destinationRecordingExtension)
        
        //Play the previously recorded recording
        do {
            try recordingSession.setCategory(.playback)
            audioPlayer = try AVAudioPlayer(contentsOf: previousRecordingPath)
            audioPlayer?.delegate = self
            audioPlayer.prepareToPlay()
            audioPlayer.volume = 1
            audioPlayer.enableRate = true
            audioPlayer.rate = 1
            audioPlayer.play()
            
            ShowListeningUI()
            
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true, block: watch.UpdateElapsedTimeListen(timer:))
            watch.start()
        } catch {
            displayAlert(title: "Error!", message: "Could not play recording, no recording exists or you have bad connection")
        }
    }
    
    @IBAction func PreviousRecordingButton(_ sender: Any) {
        recordingManager.CheckToggledRecordingsIndex(goingToPreviousRecording: true)
        recordingManager.toggledRecordingName = recordingManager.savedRecordingNames[recordingManager.toggledRecordingsIndex]
        FileNameLabel.setTitle(recordingManager.toggledRecordingName, for: .normal)
    }
    
    @IBAction func NextRecordingButton(_ sender: Any) {
        recordingManager.CheckToggledRecordingsIndex(goingToPreviousRecording: false)
        recordingManager.toggledRecordingName = recordingManager.savedRecordingNames[recordingManager.toggledRecordingsIndex]
        FileNameLabel.setTitle(recordingManager.toggledRecordingName, for: .normal)
    }

    @IBAction func RecordButton(_ sender: Any) {
        //Check if we have an active recorder
        if audioRecorder == nil {
            //If we are not already recording audio, start the recording
            recordingManager.numberOfRecordings += 1
            recordingManager.recordingName = recordingManager.RecordingTimeForFileName()
            let fileName = recordingManager.GetDirectory().appendingPathComponent(recordingManager.recordingName).appendingPathExtension(recordingManager.recordingExtension)
            
            let settings = [ AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: recordingManager.sampleRate, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.low.rawValue,
            ]
            //Start the recording
            do {
                try recordingSession.setCategory(.record)
                audioRecorder = try AVAudioRecorder(url: fileName, settings: settings)
                audioRecorder.delegate = self
                audioRecorder.record()
                ListenLabel.isHidden = true
                ShowRecordingInProgressUI()
                
                //Start Timer
                Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true, block: watch.UpdateElapsedTime(timer:))
                watch.start()
                StopWatchLabel.isHidden = false
            } catch {
                displayAlert(title: "Error!", message: "Could not play recording, check your connection")
            }
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
        HideRecordingInProgressUI()
        PausePlayButtonLabel.setImage(UIImage(named: "PauseButton-2"), for: .normal)
        
        //Convert the audio
        recordingManager.ConvertAudio()
        
        //Save the number of recordings
        UserDefaults.standard.set(recordingManager.numberOfRecordings, forKey: "myNumber")
        
        //Set the file name label to name or recording
        recordingManager.UpdateSavedRecordings()
        
        watch.stop()
        StopWatchLabel.isHidden = true
    }
    
    var isRecordingPaused: Bool = false
    @IBAction func PausePlayRecordingButton(_ sender: Any) {
        if audioRecorder.isRecording {
            PausePlayButtonLabel.setImage(UIImage(named: "PlayButton-2"), for: .normal)
            audioRecorder.pause()
            isRecordingPaused = true
            watch.pause()
        } else {
            PausePlayButtonLabel.setImage(UIImage(named: "PauseButton-2"), for: .normal)
            audioRecorder.record()
            isRecordingPaused = false
            watch.resume()
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true, block: watch.UpdateElapsedTime(timer:))
        }
    }
    
    @IBAction func EndPlaybackButton(_ sender: Any) {
        ListenLabel.setTitle("Listen", for: .normal)
        PausePlaybackLabel.setTitle("Pause", for: .normal)
        isRecordingPaused = false
        audioPlayer.stop()
        watch.stop()
        HideListeningUI()
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
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true, block: watch.UpdateElapsedTimeListen(timer:))
        }
    }

    @IBAction func SendButton(_ sender: Any) {
        if recordingManager.savedRecordingNames.count > 0 {
            let recordingUrl = recordingManager.GetDirectory().appendingPathComponent(recordingManager.toggledRecordingName).appendingPathExtension(recordingManager.destinationRecordingExtension)
            switch DestinationManager.SELECTED_DESTINATION {
            case Destination.dropbox:
                print("Sending to Dropbox")
                dropboxManager.SendToDropbox(url: recordingUrl)
            case Destination.onedrive:
                print("Sending to OneDrive")
                oneDriveManager.SendToOneDrive(url: recordingUrl)
            default:
                print("No destination selected")
                ProgressHUD.failed("No destination selected")
            }
        } else {
            ProgressHUD.failed("No recording to send")
        }
    }
    
    @IBAction func DestinationButton(_ sender: UIButton) {
        print("Destination button clicked")
    }
    
    func displayAlert(title: String, message: String, handler: (@MainActor () -> Void)? = nil) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: {_ in
            handler?()
        }))
        present(alert, animated: true, completion: nil)
    }
    
    func DisableDestinationAndSendButtons() {
        SendLabel.isEnabled = false
        SendLabel.setTitleColor(UIColor(red: 0, green: 0, blue: 0, alpha: 0.3), for: .normal)
        DestinationLabel.isEnabled = false
        DestinationLabel.setTitleColor(UIColor(red: 0, green: 0, blue: 0, alpha: 0.3), for: .normal)
    }
    
    func EnableDestinationAndSendButtons() {
        SendLabel.isEnabled = true
        SendLabel.setTitleColor(UIColor.black, for: .normal)
        DestinationLabel.isEnabled = true
        DestinationLabel.setTitleColor(UIColor.black, for: .normal)
    }
    
    func ShowRecordingInProgressUI() {
        RecordLabel.isHidden = true
        StopButtonLabel.isHidden = false
        PausePlayButtonLabel.isHidden = false
        DisableDestinationAndSendButtons()
    }
    
    func HideRecordingInProgressUI() {
        RecordLabel.isHidden = false
        StopButtonLabel.isHidden = true
        PausePlayButtonLabel.isHidden = true
        EnableDestinationAndSendButtons()
    }
    
    func ShowListeningUI() {
        ListenLabel.isHidden = true
        StopWatchLabel.isHidden = false
        PausePlaybackLabel.isHidden = false
        EndPlaybackLabel.isHidden = false
        RecordLabel.isEnabled = false
        DisableDestinationAndSendButtons()
    }
    
    func HideListeningUI() {
        ListenLabel.isHidden = false
        StopWatchLabel.isHidden = true
        PausePlaybackLabel.isHidden = true
        EndPlaybackLabel.isHidden = true
        RecordLabel.isEnabled = true
        EnableDestinationAndSendButtons()
    }
    
    func ShowSendingUI() {
        DisableDestinationAndSendButtons()
        RecordLabel.isEnabled = false
        ListenLabel.isEnabled = false
        FileNameLabel.setTitleColor(UIColor(red: 0, green: 0, blue: 0, alpha: 0.3), for: .normal)
        TitleOfAppLabel.textColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0.3)
        PreviousRecordingLabel.isEnabled = false
        NextRecordingLabel.isEnabled = false
        PreviousRecordingLabel.setTitleColor(UIColor(red: 0, green: 0, blue: 0, alpha: 0.3), for: .normal)
        NextRecordingLabel.setTitleColor(UIColor(red: 0, green: 0, blue: 0, alpha: 0.3), for: .normal)
    }
    
    func HideSendingUI() {
        EnableDestinationAndSendButtons()
        RecordLabel.isEnabled = true
        ListenLabel.isEnabled = true
        FileNameLabel.setTitleColor(UIColor.black, for: .normal)
        TitleOfAppLabel.textColor = UIColor.black
        PreviousRecordingLabel.isEnabled = true
        NextRecordingLabel.isEnabled = true
        PreviousRecordingLabel.setTitleColor(UIColor.black, for: .normal)
        NextRecordingLabel.setTitleColor(UIColor.black, for: .normal)
    }
}
