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
import FirebaseAuth

class ViewController: UIViewController, AVAudioRecorderDelegate, UIApplicationDelegate, AVAudioPlayerDelegate {

    //MARK: - IBOutlets
    @IBOutlet weak var TitleOfAppLabel: UILabel!
    @IBOutlet weak var ListenLabel: UIButton!
    @IBOutlet weak var RecordLabel: UIButton!
    @IBOutlet weak var SendLabel: UIButton!
    @IBOutlet weak var DestinationLabel: UIButton!
    @IBOutlet weak var FileNameLabel: UIButton!
    @IBOutlet weak var RenameFileLabel: UIButton!
    @IBOutlet weak var PreviousRecordingLabel: UIButton!
    @IBOutlet weak var NextRecordingLabel: UIButton!
    @IBOutlet weak var PausePlayButtonLabel: UIButton!
    @IBOutlet weak var StopButtonLabel: UIButton!
    @IBOutlet weak var PausePlaybackLabel: UIButton!
    @IBOutlet weak var EndPlaybackLabel: UIButton!
    @IBOutlet weak var StopWatchLabel: UILabel!
    @IBOutlet weak var TranscribeLabel: UIButton!
    
    var recordingSession: AVAudioSession! //Communicates how you intend to use audio within your app
    var audioRecorder: AVAudioRecorder! //Responsible for recording our audio
    var audioPlayer: AVAudioPlayer!
    
    var dropboxManager: DropboxManager!
    var oneDriveManager: OneDriveManager!
    var googleDriveManager: GoogleDriveManager!
    var destinationManager: DestinationManager!
    var emailManager: EmailManager!
    
    var recordingManager: RecordingManager!
    var transcriptionManager: TranscriptionManager!
    var watch: Stopwatch!
    
    //MARK: View did load
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let services = AppServices.shared
        recordingManager = services.recordingManager
        transcriptionManager = services.transcriptionManager
        dropboxManager = services.dropboxManager
        oneDriveManager = services.oneDriveManager
        googleDriveManager = services.googleDriveManager
        destinationManager = services.destinationManager
        emailManager = services.emailManager
        
        recordingManager.attach(viewController: self, transcriptionManager: transcriptionManager)
        transcriptionManager.attach(viewController: self, recordingMananger: recordingManager)
        dropboxManager.attach(viewController: self, recordingManager: recordingManager)
        oneDriveManager.attach(viewController: self, recordingManager: recordingManager)
        googleDriveManager.attach(viewController: self, recordingManager: recordingManager)
        emailManager.attach(viewController: self, recordingManager: recordingManager)
        

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
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == "ShowSettingsPopover",
           let vc = segue.destination as? SettingsViewController,
           let pop = vc.popoverPresentationController {

            if let anchor = sender as? UIView {
                pop.sourceView = anchor
                pop.sourceRect = anchor.bounds
                pop.permittedArrowDirections = [.up, .down]
            } else {
                pop.sourceView = view
                pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
                pop.permittedArrowDirections = []
            }
            pop.delegate = self

            // Optional: prevent swipe-down dismissal when full screen
            vc.isModalInPresentation = true
        }
    }
    
    //MARK: Listen to Playback
    @IBAction func ListenButton(_ sender: Any) {
        //Store the path to the recording in this "path" variable
        let previousRecordingPath = recordingManager.GetDirectory().appendingPathComponent(recordingManager.toggledAudioTranscriptionObject.fileName).appendingPathExtension(recordingManager.audioRecordingExtension)
        
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
    
    func checkHasTranscription() {
        if (recordingManager.toggledAudioTranscriptionObject.hasTranscription) {
            HasTranscriptionUI()
            Task {try await transcriptionManager.readToggledTextFileAndSetInAudioTranscriptObject() }
        } else {NoTranscriptionUI()}
    }
    
    @IBAction func PreviousRecordingButton(_ sender: Any) {
        recordingManager.CheckToggledRecordingsIndex(goingToPreviousRecording: true)
        recordingManager.toggledAudioTranscriptionObject = recordingManager.savedAudioTranscriptionObjects[recordingManager.toggledRecordingsIndex]
        recordingManager.setToggledRecordingURL()
        
        FileNameLabel.setTitle(recordingManager.toggledAudioTranscriptionObject.fileName, for: .normal)
        checkHasTranscription()
        
    }
    
    @IBAction func NextRecordingButton(_ sender: Any) {
        recordingManager.CheckToggledRecordingsIndex(goingToPreviousRecording: false)
        recordingManager.toggledAudioTranscriptionObject = recordingManager.savedAudioTranscriptionObjects[recordingManager.toggledRecordingsIndex]
        recordingManager.setToggledRecordingURL()
        
        FileNameLabel.setTitle(recordingManager.toggledAudioTranscriptionObject.fileName, for: .normal)
        checkHasTranscription()
    }
    
    @IBAction func RenameFileButton(_ sender: Any) {
        let alert = UIAlertController(title: "Rename File", message: nil, preferredStyle: .alert)
        
        alert.addTextField { textField in
            textField.placeholder = "Enter file name..."
            textField.text = self.recordingManager.toggledAudioTranscriptionObject.fileName
            textField.keyboardType = .default
            textField.autocapitalizationType = .none
            textField.clearButtonMode = .whileEditing
        }
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        alert.addAction(UIAlertAction(title: "Save", style: .default) { _ in
            if let newName = alert.textFields?.first?.text, !newName.isEmpty {
                self.recordingManager.RenameFile(newName: newName)
            } else {
                ProgressHUD.failed("Name cannot be empty.")
            }
        })
        
        self.present(alert, animated: true)
    }

    @IBAction func RecordButton(_ sender: Any) {
        //Check if we have an active recorder
        if audioRecorder == nil {
            //If we are not already recording audio, start the recording
            recordingManager.numberOfRecordings += 1
            recordingManager.mostRecentRecordingName = recordingManager.RecordingTimeForName()
            let fileName = recordingManager.GetDirectory().appendingPathComponent(recordingManager.mostRecentRecordingName).appendingPathExtension(recordingManager.audioRecordingExtension)
            
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 48000,                  
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]

            //Start the recording
            do {
                try recordingSession.setCategory(.record)
                audioRecorder = try AVAudioRecorder(url: fileName, settings: settings)
                audioRecorder.delegate = self
                audioRecorder.prepareToRecord()
                audioRecorder.isMeteringEnabled = false
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
    
    @IBAction func TranscribeButton(_ sender: Any) {
        ProgressHUD.animate("Transcribing...", .triangleDotShift)
        // Hop into an async context
        Task { @MainActor in
            await transcriptionManager.transcribeAudioFile()
            recordingManager.SetToggledAudioTranscriptObjectAfterTranscription()
            ProgressHUD.succeed("Transcription Complete")
        }
    }
    
    private func showSettingsPopover(anchorView: UIView?, barButtonItem: UIBarButtonItem?) {
        let vc = storyboard!.instantiateViewController(withIdentifier: "SettingsViewController") as! SettingsViewController
        vc.modalPresentationStyle = .popover

        if let pop = vc.popoverPresentationController {
            if let item = barButtonItem {
                pop.barButtonItem = item
            } else if let view = anchorView {
                pop.sourceView = view
                pop.sourceRect = view.bounds           // correct coordinate space
                pop.permittedArrowDirections = [.up, .down]
            } else {
                // Fallback center (avoid if you want identical positioning)
                pop.sourceView = self.view
                pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
                pop.permittedArrowDirections = []
            }
            pop.delegate = self
        }

        // Allow swipe-down to dismiss when it adapts (don’t lock it)
        vc.isModalInPresentation = false

        present(vc, animated: true)
    }

    @IBAction func SendButton(_ sender: Any) {
        if recordingManager.savedAudioTranscriptionObjects.count > 0 {
            let toggledHasTranscription: Bool = recordingManager.toggledAudioTranscriptionObject.hasTranscription
            switch DestinationManager.SELECTED_DESTINATION {
            case Destination.dropbox:
                print("Sending to Dropbox")
                dropboxManager.SendToDropbox(hasTranscription: toggledHasTranscription)
            case Destination.onedrive:
                print("Sending to OneDrive")
                oneDriveManager.SendToOneDrive(hasTranscription: toggledHasTranscription)
            case Destination.googledrive:
                print("Sending to Google Drive")
                googleDriveManager.SendToGoogleDrive(hasTranscription: toggledHasTranscription)
            case Destination.email:
                print("Sending to Email")
                Task { await emailManager.SendToEmail(hasTranscription: toggledHasTranscription) }
            default:
                print("No destination selected")
                showSettingsPopover(anchorView: DestinationLabel, barButtonItem: nil)
            }
        } else {
            ProgressHUD.failed("No recording to send")
        }
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
    
    func NoTranscriptionUI() {
        TranscribeLabel.setTitle("Transcribe", for: .normal)
    }
    
    func HasTranscriptionUI() {
        TranscribeLabel.setTitle("See Transcription", for: .normal)
    }
    
    func DisableUI() {
        DisableDestinationAndSendButtons()
        RecordLabel.isEnabled = false
        ListenLabel.isEnabled = false
        FileNameLabel.setTitleColor(UIColor(red: 0, green: 0, blue: 0, alpha: 0.3), for: .normal)
        TitleOfAppLabel.textColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0.3)
        PreviousRecordingLabel.isEnabled = false
        NextRecordingLabel.isEnabled = false
        PreviousRecordingLabel.setTitleColor(UIColor(red: 0, green: 0, blue: 0, alpha: 0.3), for: .normal)
        NextRecordingLabel.setTitleColor(UIColor(red: 0, green: 0, blue: 0, alpha: 0.3), for: .normal)
        RenameFileLabel.isEnabled = false
        TranscribeLabel.isEnabled = false
        TranscribeLabel.setTitleColor(UIColor(red: 0, green: 0, blue: 0, alpha: 0.3), for: .normal)
    }
    
    func EnableUI() {
        EnableDestinationAndSendButtons()
        RecordLabel.isEnabled = true
        ListenLabel.isEnabled = true
        FileNameLabel.setTitleColor(UIColor.black, for: .normal)
        TitleOfAppLabel.textColor = UIColor.black
        PreviousRecordingLabel.isEnabled = true
        NextRecordingLabel.isEnabled = true
        PreviousRecordingLabel.setTitleColor(UIColor.black, for: .normal)
        NextRecordingLabel.setTitleColor(UIColor.black, for: .normal)
        RenameFileLabel.isEnabled = true
        TranscribeLabel.isEnabled = true
        TranscribeLabel.setTitleColor(UIColor.black, for: .normal)
    }
    
    func NoRecordingsUI() {
        ListenLabel.isHidden = true
        FileNameLabel.isHidden = true
        SendLabel.isEnabled = false
        SendLabel.setTitleColor(UIColor(red: 0, green: 0, blue: 0, alpha: 0.3), for: .normal)
        PreviousRecordingLabel.isHidden = true
        NextRecordingLabel.isHidden = true
        TranscribeLabel.isHidden = true
        RenameFileLabel.isHidden = true
    }
    
    func HasRecordingsUI(numberOfRecordings: Int) {
        ListenLabel.isHidden = false
        FileNameLabel.isHidden = false
        SendLabel.isEnabled = true
        SendLabel.setTitleColor(UIColor.black, for: .normal)
        PreviousRecordingLabel.isHidden = numberOfRecordings <= 1 // Show back arrow of there are 2 or more recordings
        NextRecordingLabel.isHidden = true
        TranscribeLabel.isHidden = false
        RenameFileLabel.isHidden = false
    }
}

extension ViewController: UIPopoverPresentationControllerDelegate {

    // Make iPhone behave like your Destination button: a sheet that supports swipe-down
    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
        // On compact width (iPhone), use a sheet (swipe-down supported). On iPad, keep popover.
        return traitCollection.horizontalSizeClass == .compact ? .pageSheet : .none
    }

    // Optional: wrap in a nav controller when it becomes a sheet to show a title/close button
    func presentationController(_ controller: UIPresentationController,
                                viewControllerForAdaptivePresentationStyle style: UIModalPresentationStyle) -> UIViewController? {
        guard style != .none else { return nil }
        return UINavigationController(rootViewController: controller.presentedViewController)
    }
}

