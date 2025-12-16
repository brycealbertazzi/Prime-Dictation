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
    @IBOutlet weak var StopButtonLabel: UIButton!
    @IBOutlet weak var PlaybackStopwatch: UILabel!
    @IBOutlet weak var TranscribeLabel: UIButton!
    @IBOutlet weak var SeeTranscriptionLabel: UIButton!
    @IBOutlet weak var SendAccessibilityLabel: UILabel!
    @IBOutlet weak var PausePlayRecordingLabel: UIButton!
    @IBOutlet weak var TranscribingIndicator: UIView!
    @IBOutlet weak var TranscriptionEstimateLabel: UILabel!
    @IBOutlet weak var TranscribingLabel: UILabel!
    @IBOutlet weak var TranscribingLoadingWheel: UIActivityIndicatorView!
    @IBOutlet weak var PlaybackSlider: UISlider!
    @IBOutlet weak var RecordingStopwatch: UILabel!
    
    var recordingSession: AVAudioSession! //Communicates how you intend to use audio within your app
    var audioRecorder: AVAudioRecorder? //Responsible for recording our audio
    var audioPlayer: AVAudioPlayer?
    
    var dropboxManager: DropboxManager!
    var oneDriveManager: OneDriveManager!
    var googleDriveManager: GoogleDriveManager!
    var destinationManager: DestinationManager!
    var emailManager: EmailManager!
    
    var recordingManager: RecordingManager!
    var transcriptionManager: TranscriptionManager!
    
    var subscriptionManager: SubscriptionManager!
    
    var watch: Stopwatch!
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .darkContent
    }
    
    enum ActionState {
        case recording
        case playback
        case sending
        case none
    }
    
    var currentActionState: ActionState = .none
    private var isScrubbingSlider = false
    private var wasPlayingBeforeScrub = false
    
    //MARK: View did load
    override func viewDidLoad() {
        super.viewDidLoad()
                
        StoreKitManager.shared.startObservingTransactions()
        loadSubscriptions()
        
        let services = AppServices.shared
        recordingManager = services.recordingManager
        transcriptionManager = services.transcriptionManager
        dropboxManager = services.dropboxManager
        oneDriveManager = services.oneDriveManager
        googleDriveManager = services.googleDriveManager
        destinationManager = services.destinationManager
        emailManager = services.emailManager
        subscriptionManager = services.subscriptionManager
        
        recordingManager.attach(viewController: self, transcriptionManager: transcriptionManager)
        transcriptionManager.attach(viewController: self, recordingMananger: recordingManager)
        dropboxManager.attach(viewController: self, recordingManager: recordingManager)
        oneDriveManager.attach(viewController: self, recordingManager: recordingManager)
        googleDriveManager.attach(viewController: self, recordingManager: recordingManager)
        emailManager.attach(viewController: self, recordingManager: recordingManager)
        
        watch = Stopwatch(viewController: self)
        watch.onPlaybackTick = { [weak self] current, duration in
            guard let self = self else { return }
            guard duration > 0 else { return }

            let progress = Float(current / duration)  // 0.0 → 1.0

            guard !self.isScrubbingSlider else { return }
                
            self.PlaybackSlider.value = progress
            self.PlaybackSlider.setValue(progress, animated: true)
        }
        
        destinationManager.getDestination()
        // Do any additional setup after loading the view.
        HideRecordingInProgressUI()
        HideListeningUI()
        TranscribingIndicator.isHidden = true
        // Hide the arrow initially just in case, there is a brief moment after loading the app that both arrows show up no matter what, this will prevent the possibility of an out of range error
        PreviousRecordingLabel.isHidden = true
        NextRecordingLabel.isHidden = true
        
        PlaybackSlider.isHidden = true
        PlaybackStopwatch.isHidden = true
        RecordingStopwatch.isHidden = true
        
        loadAccessibilityText()
        
        // Initialize recording session (configure, but don't force it active yet)
        recordingSession = AVAudioSession.sharedInstance()
        try? recordingSession.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetoothHFP])

        RecordLabel.setImage(UIImage(named: "RecordButton"), for: .normal)
        PlaybackStopwatch.text = Stopwatch.StopwatchDefaultText
        RecordingStopwatch.text = Stopwatch.StopwatchDefaultText

        // Request permission
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if !granted {
                    self.displayAlert(
                        title: "Microphone Access Needed",
                        message: "Prime Dictation can’t record because microphone access is turned off. Go to Settings > Privacy & Security > Microphone and allow access for Prime Dictation."
                    )
                }
            }
        }
       
        recordingManager.SetSavedRecordingsOnLoad()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: recordingSession
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillResignActive(_:)),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        setNeedsStatusBarAppearanceUpdate()
        loadAccessibilityText()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Haptic.prepare()
        handleTranscriptionCompletionFromBackgroundOrNavigationStack()
    }
    
    func handleTranscriptionCompletionFromBackgroundOrNavigationStack() {
        guard toggledTranscriptionCompletedInBGOrAnotherVC else { return }
        toggledTranscriptionCompletedInBGOrAnotherVC = false
        if (recordingManager.toggledAudioTranscriptionObject.completedBeforeLastView && currentActionState == .none) {
            unsetCompletedTranscriptionBeforeLastViewForToggled()
        }
    }
    
    func loadAccessibilityText() {
        switch DestinationManager.SELECTED_DESTINATION {
        case .dropbox:
            SendAccessibilityLabel.text = "Dropbox"
        case .onedrive:
            SendAccessibilityLabel.text = "OneDrive"
        case .googledrive:
            SendAccessibilityLabel.text = "G Drive"
        case .email:
            SendAccessibilityLabel.text = "Email"
        default:
            SendAccessibilityLabel.text = ""
        }
    }
    
    func loadSubscriptions() {
        Task {
            let manager = StoreKitManager.shared
            // Make sure StoreKit is ready and entitlements are refreshed
            await manager.configure()
            manager.applyEntitlements(to: subscriptionManager)
            print("Current Plan: \(manager.currentPlan.debugDescription)")

            if subscriptionManager.isSubscribed {
                // User has *any* purchase => mark trial as "used"
                subscriptionManager.trialManager.usage = TrialUsage(
                    totalSeconds: TrialManager.TRIAL_LIMIT,
                    state: .completed
                )
            } else {
                // No purchase yet
                subscriptionManager.isSubscribed = false
                subscriptionManager.schedule = .none
            }
        }
    }
    
    private var wasPlayingBeforeBackground = false
    var toggledTranscriptionCompletedInBGOrAnotherVC = false
    var sendingSucceededInBackground = false
    var alertDisplayedInBackground: Bool = false
    var pendingAlertTitle: String = ""
    var pendingAlertMessage: String = ""
    @objc private func handleAppWillResignActive(_ notification: Notification) {
        // If we’re recording, stop & save as if user tapped Stop
        if let recorder = audioRecorder {
            if recorder.isRecording == true {
                recorder.stop()
                isRecordingPaused = false
                audioRecorder = nil
                HideListeningUI()
                HideRecordingInProgressUI()

                // Save the number of recordings
                UserDefaults.standard.set(recordingManager.numberOfRecordings, forKey: "myNumber")
                recordingManager.UpdateSavedRecordings()

                watch.stop()
            }
        }


        // If we’re playing back, just pause *and remember that it was playing*
        if audioPlayer?.isPlaying == true {
            wasPlayingBeforeBackground = true
            pausePlayback()
        } else {
            wasPlayingBeforeBackground = false
        }
    }

    @objc private func appDidBecomeActive(_ note: Notification) {
        // Only resume if we auto-paused because of backgrounding
        if wasPlayingBeforeBackground {
            wasPlayingBeforeBackground = false
            resumePlayback()
        }
        
        // If any alert was displayed in the background, including transibing and sending. Delay the alert until this point when they reenter the app
        if alertDisplayedInBackground {
            alertDisplayedInBackground = false
            displayAlert(
                title: pendingAlertTitle,
                message: pendingAlertMessage,
                handler: {
                    self.currentActionState = .none
                    if (self.recordingManager.toggledAudioTranscriptionObject.completedBeforeLastView) {
                        self.unsetCompletedTranscriptionBeforeLastViewForToggled()
                    }
                }
            )
        }
        
        // If a transcription finished while we were in the background, play the whoosh
        if (sendingSucceededInBackground) {
            sendingSucceededInBackground = false
            AudioFeedback.shared.playWhoosh(intensity: 0.6)
        }
        
        handleTranscriptionCompletionFromBackgroundOrNavigationStack()
        
        // 🔄 Refresh subscribed state in the background (idempotent + cheap)
        Task {
            let manager = StoreKitManager.shared
            await manager.refreshEntitlements()
            manager.applyEntitlements(to: subscriptionManager)
        }
    }
    
    //MARK: Listen to Playback
    @IBAction func ListenButton(_ sender: Any) {
        Haptic.tap(intensity: 1.0)

        isRecordingPaused = false
        watch.stop()
        
        let toggledURL: URL? = recordingManager.toggledRecordingURL
        
        guard let toggledURL else {
            print("Toggled URL not set at playback")
            displayAlert(title: "Playback Unavailable", message: "Unable to find the recording for playback. Make another recording and try again.")
            return
        }
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: toggledURL)
            
            guard let audioPlayer else { return }
            
            try recordingSession.setCategory(.playAndRecord,
                                             options: [.defaultToSpeaker, .allowBluetoothHFP])
            try recordingSession.setMode(.default)
            try recordingSession.setActive(true, options: .notifyOthersOnDeactivation)

            try recordingSession.overrideOutputAudioPort(.speaker)
            
            currentActionState = .playback
            
            audioPlayer.delegate = self
            audioPlayer.prepareToPlay()
            audioPlayer.volume = 1
            audioPlayer.enableRate = true
            audioPlayer.rate = 1
            audioPlayer.play()
            updateIdleTimer()

            ShowListeningUI()
            PlaybackSlider.minimumValue = 0
            PlaybackSlider.maximumValue = 1
            PlaybackSlider.value = 0

            Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true,block: watch.UpdateElapsedTimeListen(timer:))
            watch.start()
        } catch {
            displayAlert(title: "Playback Unavailable", message: "Prime Dictation can’t play audio while a phone or FaceTime call is active.")
        }
    }
    
    func checkHasTranscription() {
        if (recordingManager.toggledAudioTranscriptionObject.hasTranscription) {
            DispatchQueue.main.async {
                self.HasTranscriptionUI()
            }
            transcriptionManager.readToggledTextFileAndSetInAudioTranscriptObject()
        } else {
            if (recordingManager.toggledAudioTranscriptionObject.isTranscribing) {
                ShowTranscriptionInProgressUI()
            } else {
                NoTranscriptionUI()
            }
        }
    }
    
    func goToSubsequentRecording() {
        recordingManager.toggledAudioTranscriptionObject = recordingManager.savedAudioTranscriptionObjects[recordingManager.toggledRecordingsIndex]
        recordingManager.setToggledRecordingURL()
        
        FileNameLabel.setTitle(recordingManager.toggledAudioTranscriptionObject.fileName, for: .normal)
        
        checkHasTranscription()
    }
    
    @IBAction func PreviousRecordingButton(_ sender: Any) {
        Haptic.tap(intensity: 1.0)
        recordingManager.CheckToggledRecordingsIndex(goingToPreviousRecording: true)
        goToSubsequentRecording()
    }
    
    @IBAction func NextRecordingButton(_ sender: Any) {
        Haptic.tap(intensity: 1.0)
        recordingManager.CheckToggledRecordingsIndex(goingToPreviousRecording: false)
        goToSubsequentRecording()
    }
    
    @IBAction func RenameFileButton(_ sender: Any) {
        Haptic.tap(intensity: 1.0)
        let alert = UIAlertController(title: "Rename File", message: nil, preferredStyle: .alert)
        
        alert.addTextField { textField in
            textField.placeholder = "Enter file name..."
            textField.text = String(self.recordingManager.toggledAudioTranscriptionObject.fileName.split(separator: "(")[0])
            textField.keyboardType = .default
            textField.autocapitalizationType = .none
            textField.clearButtonMode = .whileEditing
        }
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        alert.addAction(UIAlertAction(title: "Save", style: .default) { _ in
            if let newName = alert.textFields?.first?.text, !newName.isEmpty {
                self.recordingManager.RenameFile(newName: newName)
            } else {
                ProgressHUD.failed("File name cannot be empty.")
            }
        })
        
        self.present(alert, animated: true)
    }
    
    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            // A call / FaceTime / VoIP (or similar) grabbed the audio session.
            if audioRecorder?.isRecording == true {
                DispatchQueue.main.async {
                    self.finishCurrentRecording(interrupted: true)
                }
            }
            // 🔊 ALSO handle playback being interrupted
            if audioPlayer?.isPlaying == true {
                self.pausePlayback()
            }
        case .ended:
            break

        @unknown default:
            break
        }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled =
            (currentActionState == .recording && !isRecordingPaused) ||
            (currentActionState == .playback && audioPlayer?.isPlaying == true)
    }

    @IBAction func RecordButton(_ sender: Any) {
        let access = subscriptionManager.accessLevel
        print("access: \(access)")
        
        if (access == .trial) {
            print("remaining trial time: \(subscriptionManager.trialManager.remainingFreeTrialTime())")
        }

        if access == .locked {
            trialEndedAlert()
            return
        }
        if access == .subscription_expired {
            subscriptionExpiredAlert()
            return
        }
        
        guard audioRecorder == nil else { return }

        Haptic.tap(intensity: 1.0)

        let permission = AVAudioApplication.shared.recordPermission

        switch permission {
        case .granted:
            // Small delay like you had before
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                self.startRecording()
            }

        case .denied:
            // Don’t even try to record; just explain what to do.
            displayAlert(
                title: "Microphone Access Needed",
                message: "Prime Dictation can’t record because microphone access is turned off. Go to Settings > Privacy & Security > Microphone and allow access for Prime Dictation."
            )

        case .undetermined:
            // Ask on first tap, then branch on the result
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    if granted {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                            self.startRecording()
                        }
                    } else {
                        self.displayAlert(
                            title: "Microphone Access Needed",
                            message: "Prime Dictation can’t record because microphone access is turned off. Go to Settings > Privacy & Security > Microphone and allow access for Prime Dictation."
                        )
                    }
                }
            }
        @unknown default:
            break
        }
    }
    
    private func startRecording() {
        guard audioRecorder == nil else { return }

        recordingManager.numberOfRecordings += 1
        recordingManager.mostRecentRecordingName = recordingManager.RecordingTimeForName()
        let newUUID = UUID()
        recordingManager.createNewAudioTranscriptionObject(uuid: newUUID)
        
        let fileName = recordingManager
            .GetDirectory()
            .appendingPathComponent(newUUID.uuidString)
            .appendingPathExtension(recordingManager.audioRecordingExtension)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            // 🟢 Reactivate session for recording; this will usually pause/duck music.
            try recordingSession.setCategory(.playAndRecord,
                                             options: [.defaultToSpeaker, .allowBluetoothHFP])
            try recordingSession.setActive(true, options: .notifyOthersOnDeactivation)
            
            audioRecorder = try AVAudioRecorder(url: fileName, settings: settings)
            currentActionState = .recording
            
            if let audioRecorder {
                audioRecorder.delegate = self
                audioRecorder.prepareToRecord()
                audioRecorder.isMeteringEnabled = false
                audioRecorder.record()
                updateIdleTimer()
                
                ListenLabel.isHidden = true
                ShowRecordingInProgressUI()
                Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true, block: watch.UpdateElapsedTime(timer:))
                watch.start()
                RecordingStopwatch.isHidden = false
            }
        } catch {
            // 🔴 Most likely: another app (phone/FaceTime/VoIP) has the mic.
            audioRecorder = nil
            DispatchQueue.main.async {
                self.displayAlert(
                    title: "Microphone In Use",
                    message: "Prime Dictation can’t access the microphone because it’s currently being used by another app, such as a phone or FaceTime call."
                )
            }
        }
    }
    
    func finishCurrentRecording(interrupted: Bool, trialEnded: Bool = false) {
        audioRecorder?.stop()
        isRecordingPaused = false
        audioRecorder = nil
        updateIdleTimer()
        
        ListenLabel.isHidden = false
        HideRecordingInProgressUI()
        PausePlayRecordingLabel.setImage(UIImage(named: "PauseButton"), for: .normal)

        // Save the number of recordings
        UserDefaults.standard.set(recordingManager.numberOfRecordings, forKey: "myNumber")

        // Refresh saved recordings + filename label
        recordingManager.UpdateSavedRecordings()

        watch.stop()
        RecordingStopwatch.isHidden = true
        RecordingStopwatch.text = Stopwatch.StopwatchDefaultText
        
        if let url = recordingManager.toggledRecordingURL {
            Task {
                let seconds = await self.recordingDuration(for: url)
                subscriptionManager.trialManager.addRecording(seconds: seconds)
            }
        }

        if interrupted {
            if (trialEnded) {
                subscriptionManager.trialManager.endFreeTrial()
                trialEndedAlert()
                return
            }
            safeDisplayAlert(
                title: "Recording Interrupted",
                message: "Another app started using the microphone. Your recording has been safely stopped and saved in Prime Dictation.",
                result: .failure
            )
        }
    }
    
    //MARK: Pause-Resume-End Recordings and Playbacks:
    @IBAction func StopRecordingButton(_ sender: Any) {
        Haptic.tap(intensity: 1.0)
        if currentActionState == .recording {
            finishCurrentRecording(interrupted: false)
            currentActionState = .none
            updateIdleTimer()
        } else {
            endPlayback()
        }
    }
    
    var isRecordingPaused: Bool = false
    @IBAction func PausePlayRecordingButton(_ sender: Any) {
        Haptic.tap()
        if currentActionState == .recording {
            guard let recorder = audioRecorder else {
                return
            }
            if recorder.isRecording {
                self.PausePlayRecordingLabel.setImage(UIImage(named: "PlayButton"), for: .normal)
                self.pauseRecording()
            } else {
                self.PausePlayRecordingLabel.setImage(UIImage(named: "PauseButton"), for: .normal)
                self.resumeRecording()
            }
        } else {
            guard let player = audioPlayer else {
                return
            }
            if player.isPlaying {
                self.PausePlayRecordingLabel.setImage(UIImage(named: "PlayButton"), for: .normal)
                self.pausePlayback()
            } else {
                self.PausePlayRecordingLabel.setImage(UIImage(named: "PauseButton"), for: .normal)
                self.resumePlayback()
            }
        }
    }
    
    private func pauseRecording() {
        guard let audioRecorder, audioRecorder.isRecording else { return }
        
        audioRecorder.pause()
        isRecordingPaused = true
        watch.pause()
        updateIdleTimer()
    }
    
    private func resumeRecording() {
        guard let audioRecorder else { return }
        
        audioRecorder.record()
        isRecordingPaused = false
        watch.resume()
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true, block: self.watch.UpdateElapsedTime(timer:))
        updateIdleTimer()
    }
    
    private func pausePlayback() {
        guard let player = audioPlayer, player.isPlaying else { return }
    
        player.pause()
        isRecordingPaused = true
        watch.pause()
        updateIdleTimer()
    }
    
    private func resumePlayback() {
        guard let player = audioPlayer else { return }
        
        let remaining = player.duration - player.currentTime
        if remaining <= 0.1 {
            endPlayback(withTransition: true)
            return
        }
        
        player.delegate = self
        player.prepareToPlay()
        player.volume = 1
        player.play()
        watch.resume()
        isRecordingPaused = false
        Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true, block: watch.UpdateElapsedTimeListen(timer:))
        updateIdleTimer()
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        print("audioPlayerDidFinishPlaying, success: \(flag)")
        endPlayback(withTransition: true)
    }
    
    func endPlayback(withTransition: Bool = false) {
        isRecordingPaused = false
        watch.stop()
        
        PausePlayRecordingLabel.setImage(UIImage(named: "PauseButton"), for: .normal)
        PausePlayRecordingLabel.isUserInteractionEnabled = false
        
        if let player = audioPlayer {
            let duration = player.duration

            // Show "end / end"
            let endText = watch.formatStopwatchTime(duration)
            PlaybackStopwatch.text = "\(endText) / \(endText)"

            // Normalized slider → set to 1.0 (100%)
            PlaybackSlider.minimumValue = 0
            PlaybackSlider.maximumValue = 1
            PlaybackSlider.value = 1

            player.stop()
            updateIdleTimer()
        }
        
        let UIUpdateWait: TimeInterval = withTransition ? 0.5 : 0.0
        DispatchQueue.main.asyncAfter(deadline: .now() + UIUpdateWait) { [weak self] in
            guard let self = self else { return }
            self.PlaybackStopwatch.text = Stopwatch.StopwatchDefaultText
            self.PlaybackSlider.value = 0
            self.HideListeningUI()
            
            audioPlayer = nil
            PausePlayRecordingLabel.isUserInteractionEnabled = true
            currentActionState = .none
            if (recordingManager.toggledAudioTranscriptionObject.completedBeforeLastView) {
                unsetCompletedTranscriptionBeforeLastViewForToggled()
            }
        }
    }
    
    @IBAction func PlaybackSliderValueChanged(_ sender: UISlider) {
        guard let player = audioPlayer else { return }
        let duration = player.duration
        let newTime = TimeInterval(sender.value) * duration
        player.currentTime = newTime
    }
    
    @IBAction func PlaybackSliderTouchDown(_ sender: UISlider) {
        guard let audioPlayer else { return }
        
        isScrubbingSlider = true
        
        if audioPlayer.isPlaying {
            wasPlayingBeforeScrub = true
        } else {
            wasPlayingBeforeScrub = false
        }
        pausePlayback()
    }
    
    @IBAction func PlaybackSliderTouchUp(_ sender: UISlider) {
        guard let player = audioPlayer else { return }
        let duration = player.duration
        let newTime = TimeInterval(sender.value) * duration
        player.currentTime = newTime

        isScrubbingSlider = false
        
        if wasPlayingBeforeScrub {
            resumePlayback()
        }
    }
    
    func pollForAllTranscribingObjectOnLoad() {
        print("Started polling for toggled transcribing object, count: \(recordingManager.transcribingAudioTranscriptionObjects.count)")
        if recordingManager.transcribingAudioTranscriptionObjects.count >= TranscriptionManager.MAX_ALLOWED_CONCURRENT_TRANSCRIPTIONS {
            TranscribeLabel.alpha = disabledAlpha
        }
        
        for (_, object) in recordingManager.transcribingAudioTranscriptionObjects.enumerated() {
            let savedIndex: Int? = recordingManager.savedAudioTranscriptionObjects.firstIndex { $0.uuid == object.uuid }
            guard let savedIndex else {
                
                removeFromTranscribingObjectsAtUUID(uuid: object.uuid)
                if (currentActionState == .none) {
                    TranscribeLabel.alpha = enabledAlpha
                }
                
                recordingManager.saveTranscribingObjectsToUserDefaults()
                
                continue
            }
            
            if let expiry = object.transcriptionExpiresAt {
                let now = Date()
                print("now: \(now), expiry: \(expiry)")
                let pollingHasExpiredForObject: Bool = now > expiry
                if (pollingHasExpiredForObject) {
                    print("expired transcribing object: \(object)")
                    
                    recordingManager.savedAudioTranscriptionObjects[savedIndex].showTimedOutBanner = true
                    recordingManager.savedAudioTranscriptionObjects[savedIndex].isTranscribing = false
                    if object.uuid == recordingManager.toggledAudioTranscriptionObject.uuid {
                        recordingManager.toggledAudioTranscriptionObject.showTimedOutBanner = true
                        recordingManager.toggledAudioTranscriptionObject.isTranscribing = false
                        NoTranscriptionUI()
                    }
                    
                    removeFromTranscribingObjectsAtUUID(uuid: object.uuid)
                    if (currentActionState == .none) {
                        TranscribeLabel.alpha = enabledAlpha
                    }
                    
                    recordingManager.saveTranscribingObjectsToUserDefaults()
                    recordingManager.saveAudioTranscriptionObjectsToUserDefaults()
                    
                    continue
                }
            }
            
            if object.uuid == recordingManager.toggledAudioTranscriptionObject.uuid {
                if (recordingManager.toggledAudioTranscriptionObject.isTranscribing) {
                    ShowTranscriptionInProgressUI()
                }
            }
            
            Task {
                var pendingObject: AudioTranscriptionObject = object
                defer {
                    pendingObject.isTranscribing = false
                    recordingManager.UpdateAudioTranscriptionObjectOnTranscriptionInProgressChange(processedObject: pendingObject)
                }
                do {
                    print("polling for: \(object.fileName)")
                    try await transcriptionManager.startPollingForTranscript(processedObject: object)
                    
                    recordingManager.savedAudioTranscriptionObjects[savedIndex].completedBeforeLastView = true
                    if object.uuid == recordingManager.toggledAudioTranscriptionObject.uuid {
                        recordingManager.toggledAudioTranscriptionObject.completedBeforeLastView = true
                    }

                    self.HideTranscriptionInProgressUI(result: .success, processedObjectUUID: object.uuid)
                } catch {
                    self.HideTranscriptionInProgressUI(result: .failure, processedObjectUUID: object.uuid)
                }
            }
        }
    }
    
    func removeFromTranscribingObjectsAtUUID(uuid: UUID?) {
        guard let uuid else { return }
        
        if let index = recordingManager.transcribingAudioTranscriptionObjects.firstIndex(where: { $0.uuid == uuid }) {
            recordingManager.transcribingAudioTranscriptionObjects.remove(at: index)
            recordingManager.saveTranscribingObjectsToUserDefaults()
        }
    }
    
    func transcriptionAlert(seconds: CGFloat, estimated: CGFloat) {
        let estimatedWaitStr: String = getEstimatedTranscriptionTimeDisplayText(recordingDuration: TimeInterval(estimated))
        
        if (seconds >= 600) {
            // Red warning
            let title = "Very long transcription"
            let msg = "Your recording is over 10 minutes long. Transcription accuracy will likely be reduced and transcription will take a long time to complete. For best results, consider breaking this into shorter recordings and transcribe each one separately. Are you sure you want to transcribe? Estimated wait: \(estimatedWaitStr)"
            displayTranscriptionAlert(title: title, message: msg, estimated: estimated)
        } else if (seconds >= 300) {
            // Yellow warning
            let title = "Long transcription"
            let msg = "Your recording is over 5 minutes long. Transcription accuracy may be affected, and it could take a while to complete. For best results, consider breaking longer recordings into shorter recordings and transcribe each one separately. Are you sure you want to transcribe? Estimated wait: \(estimatedWaitStr)"
            displayTranscriptionAlert(title: title, message: msg, estimated: estimated)
        } else {
            let title = "Start transcription?"
            let msg = "Estimated wait: \(estimatedWaitStr)"
            displayTranscriptionAlert(title: title, message: msg, estimated: estimated)
        }
    }
    
    func getEstimatedTranscriptionTimeDisplayText(recordingDuration: TimeInterval) -> String {
        // Round to nearest second for display purposes
        let totalSeconds = Int(recordingDuration.rounded())
        
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        
        if minutes == 0 {
            // Under 1 minute: "~Xs"
            return "~\(seconds)s"
        } else {
            // 1 minute or more: "~Xm Ys"
            return "~\(minutes)m \(seconds)s"
        }
    }
    
    func executeTranscription(estimated: CGFloat) {
        Task {
            let recordingManager = self.recordingManager
            guard let recordingManager else { return }
            
            let toggledObjectAtTranscribeTime: AudioTranscriptionObject = self.recordingManager.toggledAudioTranscriptionObject
            let expiryLength: TimeInterval = pendingRecordingDuration != nil ? (pendingRecordingDuration! * 1.5) + 60 : 120.0
            let expiresAtDate: Date = Date().addingTimeInterval(
                max(expiryLength, 120.0)
            )
            var pendingObject: AudioTranscriptionObject = AudioTranscriptionObject(
                uuid: toggledObjectAtTranscribeTime.uuid,
                fileName: toggledObjectAtTranscribeTime.fileName,
                hasTranscription: false,
                isTranscribing: false,
                estimatedTranscriptionTime: pendingEstimatedTranscriptionDuration,
                transcriptionExpiresAt: expiresAtDate
            )
            
            defer {
                pendingObject.isTranscribing = false
                recordingManager.UpdateAudioTranscriptionObjectOnTranscriptionInProgressChange(processedObject: pendingObject)
            }
            
            do {
                self.ShowTranscriptionInProgressUI()
                
                pendingObject.isTranscribing = true
                
                recordingManager.transcribingAudioTranscriptionObjects.append(pendingObject)
                if recordingManager.transcribingAudioTranscriptionObjects.count >= TranscriptionManager.MAX_ALLOWED_CONCURRENT_TRANSCRIPTIONS {
                    TranscribeLabel.alpha = disabledAlpha
                }
                recordingManager.saveTranscribingObjectsToUserDefaults()

                TranscriptionEstimateLabel.text = getEstimatedTranscriptionTimeDisplayText(recordingDuration: estimated)
                recordingManager.UpdateAudioTranscriptionObjectOnTranscriptionInProgressChange(processedObject: pendingObject)
                
                try await transcriptionManager.transcribeAudioFile(processedObjectInQueue: pendingObject)

                // ✅ Only log usage if they are subscribed
                if subscriptionManager.accessLevel == .subscribed,
                   let duration = pendingRecordingDuration {
                    subscriptionManager.addTranscription(seconds: duration)
                    pendingRecordingDuration = nil
                }

                HideTranscriptionInProgressUI(result: .success, processedObjectUUID: pendingObject.uuid)
                
            } catch {
                HideTranscriptionInProgressUI(result: .failure, processedObjectUUID: pendingObject.uuid)
            }
        }
    }
    
    var pendingRecordingDuration: TimeInterval?
    var pendingEstimatedTranscriptionDuration: TimeInterval?
    @IBAction func TranscribeButton(_ sender: Any) {
        if (recordingManager.transcribingAudioTranscriptionObjects.count >= TranscriptionManager.MAX_ALLOWED_CONCURRENT_TRANSCRIPTIONS) {
            displayAlert(
                title: "Transcription in Progress",
                message: "Another recording is being transcribed. Please wait until it finishes."
            )
            return
        }
        
        print("Transcribe Button current plan: \(StoreKitManager.shared.currentPlan.debugDescription)")
        print("Transcribe current usage: \(subscriptionManager.usage)")
        Haptic.tap(intensity: 1.0)
        let access = subscriptionManager.accessLevel

        if access == .subscription_expired {
            subscriptionExpiredAlert()
            return
        }

        guard let url = recordingManager.toggledRecordingURL else {
            displayAlert(
                title: "Recording Not Found",
                message: "We were unable to find this recording. Please make a new recording and try again."
            )
            ProgressHUD.dismiss()
            return
        }

        Task {
            let seconds = await recordingDuration(for: url)
            if seconds <= 0 {
                self.safeDisplayAlert(
                    title: "Transcription Failed",
                    message: "We were unable to transcribe this recording because its length couldn’t be determined. Make another recording and try again.",
                    type: .transcribe,
                    result: .failure
                )
                return
            }

            let access = subscriptionManager.accessLevel
            let manager = StoreKitManager.shared
            let currentPlan = manager.currentPlan

            // If they are subscribed, enforce daily/monthly limits (LTD has no cap)
            if access == .subscribed && currentPlan != .lifetimeDeal {
                let schedule = subscriptionManager.schedule

                // 1️⃣ Hard cap: cannot transcribe this recording
                if !subscriptionManager.canTranscribe(recordingSeconds: seconds) {
                    let remainingTimeStr = formatMinutesAndSeconds(subscriptionManager.remainingTranscriptionTime().rounded())
                    let recordingSecondsStr = formatMinutesAndSeconds(seconds.rounded())

                    switch schedule {
                    case .daily:
                        self.displayAlert(
                            title: "Insufficient minutes remaining",
                            message: "You have \(remainingTimeStr) of transcription time left today, but this recording is \(recordingSecondsStr) long. Your minutes will reset at midnight your local time. Try again tomorrow."
                        )
                    case .monthly:
                        let billingPeriodEnd: Date? = subscriptionManager.usage.lastPeriodEndFromApple
                        let billingPeriodEndStr: String
                        if let billingEnd = billingPeriodEnd {
                            billingPeriodEndStr = self.humanReadableDate(billingEnd)
                        } else {
                            billingPeriodEndStr = ""
                        }

                        self.monthlyLimitDisplayAlert(
                            title: "Insufficient minutes remaining",
                            message: "You have \(remainingTimeStr) of transcription time left in your current monthly billing period, but this recording is \(recordingSecondsStr) long. Upgrade to a daily plan to get more transcription minutes. Your minutes will reset at the start of your next billing period\(billingPeriodEndStr).",
                            onContinue: {}
                        )
                    default:
                        break
                    }

                    return
                }
                
                // 2️⃣ Soft / hard warnings at 70% / 90% for the Standard monthly plan
                if currentPlan == .standardMonthly {
                    let currentMonthlyUsage = subscriptionManager.usage.monthlySecondsUsed
                    let newMonthlyUsage = currentMonthlyUsage + seconds
                    let softWarningThreshold = SubscriptionManager.MONTHLY_LIMIT * 0.5
                    let hardWarningThreshold = SubscriptionManager.MONTHLY_LIMIT * 0.75

                    print("soft: \(softWarningThreshold), hard: \(hardWarningThreshold)")
                    print("current usage: \(currentMonthlyUsage), new usage: \(newMonthlyUsage)")

                    // Crossing 75% threshold
                    if currentMonthlyUsage < hardWarningThreshold && newMonthlyUsage >= hardWarningThreshold {
                        self.monthlyLimitDisplayAlert(
                            title: "Running low on minutes",
                            message: "You’ve used over 75% of your monthly transcription time. For more minutes and daily resets, upgrade to a daily plan before you run out.",
                            onContinue: { [weak self] in
                                guard let self = self else { return }
                                self.startTranscriptionFlow(seconds: seconds)
                            }
                        )
                        return
                    }
                    // Crossing 50% threshold
                    else if currentMonthlyUsage < softWarningThreshold && newMonthlyUsage >= softWarningThreshold {
                        self.monthlyLimitDisplayAlert(
                            title: "Need more minutes?",
                            message: "You’ve used over 50% of your monthly transcription minutes. If you need more flexibility, consider upgrading to a daily plan for increased transcription time.",
                            onContinue: { [weak self] in
                                guard let self = self else { return }
                                self.startTranscriptionFlow(seconds: seconds)
                            }
                        )
                        return
                    }
                }
            }

            // 3️⃣ No blocking + no warning case → continue directly
            self.startTranscriptionFlow(seconds: seconds)
        }
    }
    
    private func startTranscriptionFlow(seconds: TimeInterval) {
        let estimatedTranscriptionSeconds = (seconds / 2) + 15
        transcriptionAlert(seconds: seconds, estimated: estimatedTranscriptionSeconds)
        pendingRecordingDuration = seconds
        pendingEstimatedTranscriptionDuration = estimatedTranscriptionSeconds
    }
    
    func humanReadableDate(_ date: Date?) -> String {
        guard let date = date else { return "" }

        let formatter = DateFormatter()
        formatter.dateStyle = .long      // e.g., January 12, 2025
        formatter.timeStyle = .none
        formatter.locale = Locale.current

        return " on \(formatter.string(from: date))"
    }
    
    func formatMinutesAndSeconds(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds.rounded())

        // If under 60 seconds → just show seconds
        if totalSeconds < 60 {
            return "\(totalSeconds) second\(totalSeconds == 1 ? "" : "s")"
        }

        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60

        return "\(minutes) minute\(minutes == 1 ? "" : "s") and \(secs) second\(secs == 1 ? "" : "s")"
    }
    
    func monthlyLimitDisplayAlert(
        title: String,
        message: String,
        onContinue: @escaping () -> Void
    ) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)

        // "Not Now" = don't upgrade, but still continue with transcription
        alert.addAction(UIAlertAction(title: "Not Now", style: .default) { _ in
            onContinue()
        })

        alert.addAction(UIAlertAction(title: "Upgrade", style: .default) { [weak self] _ in
            guard let self = self else { return }
            self.showPaywallScreen()
        })

        present(alert, animated: true, completion: nil)
    }
    
    @IBAction func SeeTranscriptionButton(_ sender: Any) {
        Haptic.tap(intensity: 1.0)
        showTranscriptionScreen()
    }
    
    func recordingDuration(for url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)

        if #available(iOS 17.0, *) {
            do {
                let duration = try await asset.load(.duration)
                let seconds = duration.seconds   // CMTime extension
                guard seconds.isFinite, seconds > 0 else { return 0 }
                return seconds
            } catch {
                print("Unable to get duration of audio file")
                return 0
            }
        } else {
            // Fallback for older iOS: use the synchronous property
            let seconds = asset.duration.seconds
            guard seconds.isFinite, seconds > 0 else { return 0 }
            return seconds
        }
    }
    
    private func showTranscriptionScreen() {
        // 1) instantiate
        let vc = storyboard!.instantiateViewController(
            withIdentifier: "TranscriptionViewController"
        ) as! TranscriptionViewController

        // 2) pass the transcript, if you want
        vc.transcriptText = recordingManager.toggledAudioTranscriptionObject.transcriptionText

        vc.modalPresentationStyle = .fullScreen
        present(vc, animated: true)
    }
    
    private func showPaywallScreen() {
        let vc = storyboard!.instantiateViewController(
            withIdentifier: "PaywallViewController"
        ) as! PaywallViewController

        vc.modalPresentationStyle = .overFullScreen
        present(vc, animated: true)
    }

    private func showDestinationScreen() {
        let vc = storyboard!.instantiateViewController(withIdentifier: "SettingsViewController") as! SettingsViewController
        vc.modalPresentationStyle = .fullScreen
        present(vc, animated: true)
    }

    @IBAction func DestinationButton(_ sender: Any) {
        Haptic.tap(intensity: 1.0)
        showDestinationScreen()
    }
    
    @IBAction func SendButtonHighlighted(_ sender: Any) {
        SendAccessibilityLabel.alpha = 0.6
        SendLabel.alpha = 0.8
    }
    
    @IBAction func SendButtonTouchDragEnter(_ sender: Any) {
        SendAccessibilityLabel.alpha = 0.6
        SendLabel.alpha = 0.8
    }
    
    @IBAction func SendButtonTouchDragExit(_ sender: Any) {
        SendAccessibilityLabel.alpha = 1.0
        SendLabel.alpha = 1.0
    }
    
    @IBAction func SendButton(_ sender: Any) {
        Haptic.tap(intensity: 1.0)
        if recordingManager.savedAudioTranscriptionObjects.count > 0 {
            let toggledHasTranscription: Bool = recordingManager.toggledAudioTranscriptionObject.hasTranscription
            switch DestinationManager.SELECTED_DESTINATION {
            case Destination.dropbox:
                currentActionState = .sending
                dropboxManager.SendToDropbox(hasTranscription: toggledHasTranscription)
            case Destination.onedrive:
                currentActionState = .sending
                oneDriveManager.SendToOneDrive(hasTranscription: toggledHasTranscription)
            case Destination.googledrive:
                currentActionState = .sending
                googleDriveManager.SendToGoogleDrive(hasTranscription: toggledHasTranscription)
            case Destination.email:
                currentActionState = .sending
                Task { await emailManager.SendToEmail(hasTranscription: toggledHasTranscription) }
            default:
                print("No destination selected")
                SendAccessibilityLabel.alpha = 1.0
                SendLabel.alpha = 1.0
                selectDestinatinonAlert()
            }
        } else {
            displayAlert(title: "No recording found", message: "There is no recording to send, make a recording first and try again.")
        }
    }
    
    func displayAlert(title: String, message: String, handler: (@MainActor () -> Void)? = nil) {
        ProgressHUD.dismiss()
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: {_ in
            handler?()
        }))
        present(alert, animated: true, completion: nil)
    }
    
    func selectDestinatinonAlert() {
        let alert = UIAlertController(title: "No destination selected", message: "Before you send, select a destination first.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
        alert.addAction(UIAlertAction(title: "Destination", style: .default, handler: {[weak self] _ in
            guard let self else { return }
            self.showDestinationScreen()
        }))
        present(alert, animated: true, completion: nil)
    }
    
    func trialEndedAlert() {
        let alert = UIAlertController(title: "Free Trial Limit Reached", message: "You’ve used your 3 free minutes of recording. Subscribe to continue recording unlimited audio.", preferredStyle: .alert)

        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))  // just dismiss

        alert.addAction(UIAlertAction(title: "Subscribe", style: .default) { [weak self] _ in
            guard let self = self else { return }
            self.showPaywallScreen()
        })

        present(alert, animated: true, completion: nil)
    }
    
    func subscriptionExpiredAlert() {
        let alert = UIAlertController(title: "Subscription Expired", message: "Subscribe again to continue recording unlimited audio and access transcription.", preferredStyle: .alert)

        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))  // just dismiss

        alert.addAction(UIAlertAction(title: "Subscribe", style: .default) { [weak self] _ in
            guard let self = self else { return }
            self.showPaywallScreen()
        })

        present(alert, animated: true, completion: nil)
    }
    
    enum SafeAlertType {
        case transcribe
        case send
        case other
    }
    
    enum SafeAlertResult {
        case success
        case failure
    }
    
    func safeAlertInForeground(title: String, message: String, type: SafeAlertType = .other, result: SafeAlertResult) {
        if result == .success {
            if type == .send {
                AudioFeedback.shared.playWhoosh(intensity: 0.6)
                if (recordingManager.toggledAudioTranscriptionObject.completedBeforeLastView) {
                    unsetCompletedTranscriptionBeforeLastViewForToggled()
                }
            }
        } else {
            displayAlert(title: title, message: message)
        }
    }
    
    func safeAlertInBackground(title: String, message: String, type: SafeAlertType = .other, result: SafeAlertResult) {
        if type == .send && result == .success { sendingSucceededInBackground = true }
        alertDisplayedInBackground = true
        pendingAlertTitle = title
        pendingAlertMessage = message
    }
    
    func safeDisplayAlert(title: String, message: String, type: SafeAlertType = .other, result: SafeAlertResult) {
        self.currentActionState = .none
        if UIApplication.shared.applicationState == .active {
            safeAlertInForeground(title: title, message: message, type: type, result: result)
        } else {
            safeAlertInBackground(title: title, message: message, type: type, result: result)
        }
    }
    
    func displayTranscriptionAlert(title: String, message: String, estimated: CGFloat) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))  // just dismiss

        alert.addAction(UIAlertAction(title: "Transcribe", style: .default) { [weak self] _ in
            guard let self = self else { return }
            self.executeTranscription(estimated: estimated)
        })

        present(alert, animated: true, completion: nil)
    }
    
    let disabledAlpha: CGFloat = 0.4
    let enabledAlpha: CGFloat = 1.0
    func DisableDestinationAndSendButtons() {
        SendLabel.isEnabled = false
        SendLabel.alpha = disabledAlpha
        SendAccessibilityLabel.alpha = 0.3
        DestinationLabel.isEnabled = false
        DestinationLabel.alpha = disabledAlpha
    }
    
    func EnableDestinationAndSendButtons() {
        SendLabel.isEnabled = true
        SendLabel.alpha = enabledAlpha
        SendAccessibilityLabel.alpha = enabledAlpha
        DestinationLabel.isEnabled = true
        DestinationLabel.alpha = enabledAlpha
    }
    
    func ShowRecordingOrListeningUI() {
        TitleOfAppLabel.alpha = disabledAlpha
        TranscribeLabel.isEnabled = false
        TranscribeLabel.alpha = disabledAlpha
        SeeTranscriptionLabel.isEnabled = false
        SeeTranscriptionLabel.alpha = disabledAlpha
        TranscribingLabel.alpha = disabledAlpha
        TranscribingLoadingWheel.alpha = disabledAlpha
        TranscriptionEstimateLabel.alpha = disabledAlpha
        PreviousRecordingLabel.isEnabled = false
        NextRecordingLabel.isEnabled = false
        RenameFileLabel.isEnabled = false
        PreviousRecordingLabel.alpha = disabledAlpha
        NextRecordingLabel.alpha = disabledAlpha
        RenameFileLabel.alpha = disabledAlpha
        RecordLabel.isHidden = true
        StopButtonLabel.isHidden = false
        PausePlayRecordingLabel.isHidden = false
        
        DisableDestinationAndSendButtons()
    }
    
    func HideRecordingOrListeningUI() {
        TitleOfAppLabel.alpha = enabledAlpha
        TranscribeLabel.isEnabled = true
        if recordingManager.transcribingAudioTranscriptionObjects.count < TranscriptionManager.MAX_ALLOWED_CONCURRENT_TRANSCRIPTIONS {
            TranscribeLabel.alpha = enabledAlpha
        }
        SeeTranscriptionLabel.isEnabled = true
        SeeTranscriptionLabel.alpha = enabledAlpha
        TranscribingLabel.alpha = enabledAlpha
        TranscribingLoadingWheel.alpha = enabledAlpha
        TranscriptionEstimateLabel.alpha = enabledAlpha
        PreviousRecordingLabel.isEnabled = true
        NextRecordingLabel.isEnabled = true
        RenameFileLabel.isEnabled = true
        PreviousRecordingLabel.alpha = enabledAlpha
        NextRecordingLabel.alpha = enabledAlpha
        RenameFileLabel.alpha = enabledAlpha
        RecordLabel.isHidden = false
        StopButtonLabel.isHidden = true
        PausePlayRecordingLabel.isHidden = true
        
        EnableDestinationAndSendButtons()
    }
    
    func ShowRecordingInProgressUI() {
        RecordLabel.isHidden = true
        FileNameLabel.alpha = disabledAlpha
        RecordingStopwatch.isHidden = false
        ShowRecordingOrListeningUI()
    }
    
    func HideRecordingInProgressUI() {
        RecordLabel.isHidden = false
        FileNameLabel.alpha = enabledAlpha
        RecordingStopwatch.isHidden = true
        HideRecordingOrListeningUI()
    }
    
    func ShowListeningUI() {
        ListenLabel.isHidden = true
        PlaybackStopwatch.isHidden = false
        RecordLabel.isEnabled = false
        PlaybackSlider.isHidden = false
        ShowRecordingOrListeningUI()
    }
    
    func HideListeningUI() {
        ListenLabel.isHidden = false
        PlaybackStopwatch.isHidden = true
        RecordLabel.isEnabled = true
        PlaybackSlider.isHidden = true
        HideRecordingOrListeningUI()
    }

    private func paddedSymbol(_ name: String, pad: CGFloat = 2) -> UIImage? {
        UIImage(systemName: name)?
            .withAlignmentRectInsets(UIEdgeInsets(top: -pad, left: -pad, bottom: -pad, right: -pad))
    }
    
    func unsetCompletedTranscriptionBeforeLastViewForToggled() {
        animateTranscriptionReady()
        
        recordingManager.toggledAudioTranscriptionObject.completedBeforeLastView = false
        if recordingManager.toggledRecordingsIndex > 0 {
            recordingManager.savedAudioTranscriptionObjects[recordingManager.toggledRecordingsIndex].completedBeforeLastView = false
        }
        recordingManager.saveAudioTranscriptionObjectsToUserDefaults()
    }
    
    func animateTranscriptionReady() {
        guard let button = SeeTranscriptionLabel else { return }

        // Start slightly smaller and invisible
        button.alpha = 0
        button.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)

        // Optional: light haptic tap
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()

        // Phase 1: fade in + pop bigger
        UIView.animate(
            withDuration: 0.5,
            delay: 0,
            options: [.curveEaseOut],
            animations: {
                button.alpha = 1
                button.transform = CGAffineTransform(scaleX: 1.25, y: 1.25)
            },
            completion: { _ in
                // Phase 2: settle back to normal size with a little spring
                UIView.animate(
                    withDuration: 0.5,
                    delay: 0,
                    usingSpringWithDamping: 0.7,
                    initialSpringVelocity: 0.6,
                    options: [.curveEaseInOut],
                    animations: {
                        button.transform = .identity
                    },
                    completion: nil
                )
            }
        )
    }

    func NoTranscriptionUI() {
        TranscribeLabel.isHidden = false
        SeeTranscriptionLabel.isHidden = true
        TranscribingIndicator.isHidden = true
    }

    func HasTranscriptionUI() {
        TranscribeLabel.isHidden = true
        SeeTranscriptionLabel.isHidden = false
        TranscribingIndicator.isHidden = true
        if (recordingManager.toggledAudioTranscriptionObject.completedBeforeLastView) {
            guard UIApplication.shared.applicationState == .active, isCurrentlyVisible else {
                // Either app in background OR user is on another screen
                toggledTranscriptionCompletedInBGOrAnotherVC = true
                return
            }
            if currentActionState == .none {
                unsetCompletedTranscriptionBeforeLastViewForToggled()
            }
        }
    }
    
    func ShowTranscriptionInProgressUI() {
        if let estimatedTranscriptionTime = recordingManager.toggledAudioTranscriptionObject.estimatedTranscriptionTime {
            print("estimatedTranscriptionTime: \(estimatedTranscriptionTime)")
            TranscriptionEstimateLabel.text = getEstimatedTranscriptionTimeDisplayText(recordingDuration: estimatedTranscriptionTime)
        }
        TranscribeLabel.isHidden = true
        SeeTranscriptionLabel.isHidden = true
        TranscribingIndicator.isHidden = false
    }
    
    func HideTranscriptionInProgressUI(result: SafeAlertResult, processedObjectUUID: UUID) {
        if (recordingManager.toggledAudioTranscriptionObject.uuid == processedObjectUUID) {
            // We are in the slot of the recording when it finished transcribing
            TranscribingIndicator.isHidden = true
            if result == .success {
                HasTranscriptionUI()
            } else {
                NoTranscriptionUI()
            }
        }
    }
    
    func DisableUI() {
        RecordLabel.isEnabled = false
        RecordLabel.alpha = disabledAlpha
        ListenLabel.isEnabled = false
        ListenLabel.alpha = disabledAlpha
        TitleOfAppLabel.alpha = disabledAlpha
        FileNameLabel.alpha = disabledAlpha
        TranscribeLabel.isEnabled = false
        TranscribeLabel.alpha = disabledAlpha
        SeeTranscriptionLabel.isEnabled = false
        SeeTranscriptionLabel.alpha = disabledAlpha
        TranscribingLabel.alpha = disabledAlpha
        TranscribingLoadingWheel.alpha = disabledAlpha
        TranscriptionEstimateLabel.alpha = disabledAlpha
        PreviousRecordingLabel.isEnabled = false
        PreviousRecordingLabel.alpha = disabledAlpha
        NextRecordingLabel.isEnabled = false
        NextRecordingLabel.alpha = disabledAlpha
        RenameFileLabel.isEnabled = false
        RenameFileLabel.alpha = disabledAlpha
        
        DisableDestinationAndSendButtons()
    }
    
    func EnableUI() {
        RecordLabel.isEnabled = true
        RecordLabel.alpha = enabledAlpha
        ListenLabel.isEnabled = true
        ListenLabel.alpha = enabledAlpha
        TitleOfAppLabel.alpha = enabledAlpha
        FileNameLabel.alpha = enabledAlpha
        
        TranscribeLabel.isEnabled = true
        if recordingManager.transcribingAudioTranscriptionObjects.count < TranscriptionManager.MAX_ALLOWED_CONCURRENT_TRANSCRIPTIONS {
            TranscribeLabel.alpha = enabledAlpha
        }
        SeeTranscriptionLabel.isEnabled = true
        SeeTranscriptionLabel.alpha = enabledAlpha
        TranscribingLabel.alpha = enabledAlpha
        TranscribingLoadingWheel.alpha = enabledAlpha
        TranscriptionEstimateLabel.alpha = enabledAlpha
        PreviousRecordingLabel.isEnabled = true
        PreviousRecordingLabel.alpha = enabledAlpha
        NextRecordingLabel.isEnabled = true
        NextRecordingLabel.alpha = enabledAlpha
        RenameFileLabel.isEnabled = true
        RenameFileLabel.alpha = enabledAlpha
        
        EnableDestinationAndSendButtons()
    }
    
    func NoRecordingsUI() {
        ListenLabel.isHidden = true
        FileNameLabel.isHidden = true
        SendLabel.isEnabled = false
        SendLabel.alpha = disabledAlpha
        SendAccessibilityLabel.alpha = 0.3
        PreviousRecordingLabel.isHidden = true
        NextRecordingLabel.isHidden = true
        TranscribeLabel.isHidden = true
        SeeTranscriptionLabel.isHidden = true
        RenameFileLabel.isHidden = true
    }
    
    func HasRecordingsUI(numberOfRecordings: Int) {
        ListenLabel.isHidden = false
        FileNameLabel.isHidden = false
        SendLabel.isEnabled = true
        SendLabel.alpha = enabledAlpha
        SendAccessibilityLabel.alpha = enabledAlpha
        PreviousRecordingLabel.isHidden = numberOfRecordings <= 1 // Show back arrow of there are 2 or more recordings
        NextRecordingLabel.isHidden = true
        RenameFileLabel.isHidden = false
    }
}

extension ViewController: UIPopoverPresentationControllerDelegate {

    // Make iPhone behave like your Destination button: a sheet that supports swipe-down
    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
        // On compact width (iPhone), use a sheet (swipe-down supported). On iPad, keep popover.
        return traitCollection.horizontalSizeClass == .compact ? .pageSheet : .none
    }

    func presentationController(_ controller: UIPresentationController,
                                viewControllerForAdaptivePresentationStyle style: UIModalPresentationStyle)
    -> UIViewController? {
        return nil  // no UINavigationController wrapper
    }
}

extension UIViewController {
    var isCurrentlyVisible: Bool {
        return isViewLoaded && view.window != nil
    }
}

