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
    @IBOutlet weak var SendLabel: RoundedButton!
    @IBOutlet weak var DestinationLabel: UIButton!
    @IBOutlet weak var FileNameLabel: UIButton!
    @IBOutlet weak var RenameFileLabel: UIButton!
    @IBOutlet weak var PreviousRecordingLabel: UIButton!
    @IBOutlet weak var NextRecordingLabel: UIButton!
    @IBOutlet weak var StopButtonLabel: UIButton!
    @IBOutlet weak var PausePlaybackLabel: UIButton!
    @IBOutlet weak var EndPlaybackLabel: UIButton!
    @IBOutlet weak var StopWatchLabel: UILabel!
    @IBOutlet weak var TranscribeLabel: UIButton!
    @IBOutlet weak var SeeTranscriptionLabel: UIButton!
    @IBOutlet weak var PoorConnectionLabel: UILabel!
    
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
    
    var subscriptionManager: SubscriptionManager!
    
    var watch: Stopwatch!
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .darkContent
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        setNeedsStatusBarAppearanceUpdate()
    }
    
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
        
        destinationManager.getDestination()
        // Do any additional setup after loading the view.
        HideRecordingInProgressUI()
        HideListeningUI()
        // Hide the arrow initially just in case, there is a brief moment after loading the app that both arrows show up no matter what, this will prevent the possibility of an out of range error
        PreviousRecordingLabel.isHidden = true
        NextRecordingLabel.isHidden = true
        
        //FileNameLabel should be disabled at all times
        FileNameLabel.isEnabled = false
        /*****/
        
        // Initialize recording session (configure, but don't force it active yet)
        recordingSession = AVAudioSession.sharedInstance()
        try? recordingSession.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetoothHFP])

        RecordLabel.setImage(UIImage(named: "RecordButton"), for: .normal)
        PoorConnectionLabel.isHidden = true

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
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Haptic.prepare()
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
    private var transcriptionCompletedInBackground = false
    var sendingCompletedInBackground = false
    var alertDisplayedInBackground: Bool = false
    var pendingAlertTitle: String = ""
    var pendingAlertMessage: String = ""
    @objc private func handleAppWillResignActive(_ notification: Notification) {
        // If we’re recording, stop & save as if user tapped Stop
        if audioRecorder?.isRecording == true {
            audioRecorder.stop()
            isRecordingPaused = false
            audioRecorder = nil
            ListenLabel.isHidden = false
            HideRecordingInProgressUI()

            // Save the number of recordings
            UserDefaults.standard.set(recordingManager.numberOfRecordings, forKey: "myNumber")
            recordingManager.UpdateSavedRecordings()

            watch.stop()
            StopWatchLabel.isHidden = true
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
                message: pendingAlertMessage
            )
        }

        // If a transcription finished while we were in the background, play the
        if transcriptionCompletedInBackground {
            transcriptionCompletedInBackground = false
            AudioFeedback.shared.playDing(intensity: 0.6)
        }
        
        // If a transcription finished while we were in the background, play the whoosh
        if (sendingCompletedInBackground) {
            sendingCompletedInBackground = false
            AudioFeedback.shared.playWhoosh(intensity: 0.6)
        }
        
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

        let previousRecordingPath = recordingManager.GetDirectory()
            .appendingPathComponent(recordingManager.toggledAudioTranscriptionObject.fileName)
            .appendingPathExtension(recordingManager.audioRecordingExtension)

        do {
            try recordingSession.setCategory(.playAndRecord,
                                             options: [.defaultToSpeaker, .allowBluetoothHFP])
            try recordingSession.setMode(.default)
            try recordingSession.setActive(true, options: .notifyOthersOnDeactivation)

            try recordingSession.overrideOutputAudioPort(.speaker)
            audioPlayer = try AVAudioPlayer(contentsOf: previousRecordingPath)
            audioPlayer?.delegate = self
            audioPlayer.prepareToPlay()
            audioPlayer.volume = 1
            audioPlayer.enableRate = true
            audioPlayer.rate = 1
            audioPlayer.play()

            ShowListeningUI()
            Timer.scheduledTimer(withTimeInterval: 0.1,
                                 repeats: true,
                                 block: watch.UpdateElapsedTimeListen(timer:))
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
            Task {try await transcriptionManager.readToggledTextFileAndSetInAudioTranscriptObject() }
        } else {NoTranscriptionUI()}
    }
    
    @IBAction func PreviousRecordingButton(_ sender: Any) {
        Haptic.tap(intensity: 1.0)
        recordingManager.CheckToggledRecordingsIndex(goingToPreviousRecording: true)
        recordingManager.toggledAudioTranscriptionObject = recordingManager.savedAudioTranscriptionObjects[recordingManager.toggledRecordingsIndex]
        recordingManager.setToggledRecordingURL()
        
        FileNameLabel.setTitle(recordingManager.toggledAudioTranscriptionObject.fileName, for: .normal)
        checkHasTranscription()
        
    }
    
    @IBAction func NextRecordingButton(_ sender: Any) {
        Haptic.tap(intensity: 1.0)
        recordingManager.CheckToggledRecordingsIndex(goingToPreviousRecording: false)
        recordingManager.toggledAudioTranscriptionObject = recordingManager.savedAudioTranscriptionObjects[recordingManager.toggledRecordingsIndex]
        recordingManager.setToggledRecordingURL()
        
        FileNameLabel.setTitle(recordingManager.toggledAudioTranscriptionObject.fileName, for: .normal)
        checkHasTranscription()
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
        let fileName = recordingManager
            .GetDirectory()
            .appendingPathComponent(recordingManager.mostRecentRecordingName)
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
            audioRecorder.delegate = self
            audioRecorder.prepareToRecord()
            audioRecorder.isMeteringEnabled = false
            audioRecorder.record()

            ListenLabel.isHidden = true
            ShowRecordingInProgressUI()
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true, block: watch.UpdateElapsedTime(timer:))
            watch.start()
            StopWatchLabel.isHidden = false
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
        guard audioRecorder != nil else { return }

        audioRecorder.stop()
        isRecordingPaused = false
        audioRecorder = nil

        ListenLabel.isHidden = false
        HideRecordingInProgressUI()

        // Save the number of recordings
        UserDefaults.standard.set(recordingManager.numberOfRecordings, forKey: "myNumber")

        // Refresh saved recordings + filename label
        recordingManager.UpdateSavedRecordings()

        watch.stop()
        StopWatchLabel.isHidden = true
        
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
        finishCurrentRecording(interrupted: false)
    }
    
    var isRecordingPaused: Bool = false
    @IBAction func PausePlayRecordingButton(_ sender: Any) {
        Haptic.tap()
        if self.audioRecorder.isRecording {
            self.audioRecorder.pause()
            self.isRecordingPaused = true
            self.watch.pause()
        } else {
            self.audioRecorder.record()
            self.isRecordingPaused = false
            self.watch.resume()
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true, block: self.watch.UpdateElapsedTime(timer:))
        }
    }
    
    private func pausePlayback() {
        audioPlayer.pause()
        isRecordingPaused = true
        PausePlaybackLabel.setTitle("Resume", for: .normal)
        watch.pause()
    }
    
    private func resumePlayback() {
        audioPlayer?.delegate = self
        audioPlayer.prepareToPlay()
        audioPlayer.volume = 1
        audioPlayer.play()
        PausePlaybackLabel.setTitle("Pause", for: .normal)
        watch.resume()
        isRecordingPaused = false
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true, block: watch.UpdateElapsedTimeListen(timer:))
    }
    
    private func endPlayback() {
        PausePlaybackLabel.setTitle("Pause", for: .normal)
        isRecordingPaused = false
        audioPlayer.stop()
        watch.stop()
        HideListeningUI()
    }
    
    @IBAction func EndPlaybackButton(_ sender: Any) {
        Haptic.tap(intensity: 1.0)
        endPlayback()
    }
    
    @IBAction func PausePlaybackButton(_ sender: Any) {
        Haptic.tap(intensity: 1.0)
        if audioPlayer.isPlaying {
            pausePlayback()
        } else {
            resumePlayback()
        }
    }
    
    private var transcriptionProgressTimer: Timer?
    private var transcriptionProgressStage = 0

    private var poorConnectionStartTimer: Timer?
    
    func transcriptionAlert(seconds: CGFloat, estimated: CGFloat) {
        let estimatedWaitStr: String = getEstimatedWaitLabel(seconds: TimeInterval(estimated))
        
        if (seconds >= 600) {
            // Red warning
            let title = "Very long transcription"
            let msg = "Your recording is over 10 minutes long. Transcription accuracy will likely be reduced and transcription may take a long time to complete. For best results, consider breaking this into shorter recordings and transcribing each one separately. You’ll need to keep Prime Dictation open while we transcribe. Are you sure you want to transcribe? \(estimatedWaitStr)"
            displayTranscriptionAlert(title: title, message: msg, estimated: estimated)
        } else if (seconds >= 300) {
            // Yellow warning
            let title = "Long transcription"
            let msg = "Your recording is over 5 minutes long. Transcription accuracy may be affected, and it could take a while to complete. For best results, consider breaking long recordings into smaller parts and transcribing each one separately. You’ll need to keep Prime Dictation open while we transcribe. Are you sure you want to transcribe? \(estimatedWaitStr)"
            displayTranscriptionAlert(title: title, message: msg, estimated: estimated)
        } else {
            let title = "Start transcription?"
            let msg = "The app will be locked while transcribing, please keep Prime Dictation open during the process. \(estimatedWaitStr)"
            displayTranscriptionAlert(title: title, message: msg, estimated: estimated)
        }
    }
    
    func executeTranscription(estimated: CGFloat) {
        transcriptionInProgressUI(time: estimated)

        Task {
            defer {
                self.transcriptionProgressTimer?.invalidate()
                self.poorConnectionStartTimer?.invalidate()
                self.transcriptionProgressTimer = nil
                self.poorConnectionStartTimer = nil

                self.PoorConnectionLabel.layer.removeAllAnimations()
                self.PoorConnectionLabel.alpha = 1.0
                self.PoorConnectionLabel.isHidden = true
            }

            do {
                try await transcriptionManager.transcribeAudioFile()
                recordingManager.SetToggledAudioTranscriptObjectAfterTranscription()

                // ✅ Only log usage if they are subscribed
                if subscriptionManager.accessLevel == .subscribed,
                   let duration = pendingTranscriptionDuration {
                    subscriptionManager.addTranscription(seconds: duration)
                    pendingTranscriptionDuration = nil
                }

                await MainActor.run {
                    ProgressHUD.succeed("Transcription Complete")

                    self.safeDisplayAlert(
                        title: "Transcription Complete",
                        message: "Your recording was transcribed while Prime Dictation was in the background.",
                        type: .transcribe,
                        result: .success
                    )
                }
            } catch {
                await MainActor.run {
                    self.safeDisplayAlert(
                        title: "Transcription Failed",
                        message: "We were unable to transcribe your recording. Your connection may be slow, try again later.",
                        type: .transcribe,
                        result: .failure
                    )
                }
            }
        }
    }
    
    private var pendingTranscriptionDuration: TimeInterval?
    @IBAction func TranscribeButton(_ sender: Any) {
        print("Transcribe Button current plan: \(StoreKitManager.shared.currentPlan.debugDescription)")
        print("Transcribe current usage: \(subscriptionManager.usage)")
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
        pendingTranscriptionDuration = seconds
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
    
    @MainActor
    private func recordingDuration(for url: URL) async -> TimeInterval {
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
    
    private func getEstimatedWaitLabel(seconds: TimeInterval) -> String {
        var estimatedWaitLabel: String = ""
        if seconds < 45 {
            estimatedWaitLabel = "Estimated wait: under 1 min"
        } else {
            estimatedWaitLabel = "Estimated wait: ~\(Int(ceil(seconds / 60))) min"
        }
        return estimatedWaitLabel
    }
    
    private func transcriptionInProgressUI(time: TimeInterval) {
        // Cancel any prior timers
        transcriptionProgressTimer?.invalidate()
        poorConnectionStartTimer?.invalidate()

        transcriptionProgressTimer = nil
        poorConnectionStartTimer = nil

        // Reset label
        PoorConnectionLabel.isHidden = true
        PoorConnectionLabel.alpha = 1.0

        transcriptionProgressStage = 0
        let total = max(time, 6.0)     // avoid flicker for tiny clips
        let seg = total / 3.0

        // Stage 1 immediately
        ProgressHUD.animate("Sending audio to servers", .triangleDotShift)

        // Stage 2 & 3
        transcriptionProgressTimer = Timer.scheduledTimer(withTimeInterval: seg, repeats: true) { [weak self] t in
            guard let self = self else { return }
            self.transcriptionProgressStage += 1
            switch self.transcriptionProgressStage {
            case 1:
                ProgressHUD.animate("Transcribing audio file", .triangleDotShift)
            case 2:
                ProgressHUD.animate("Finalizing transcription", .triangleDotShift)
            default:
                t.invalidate()
                self.transcriptionProgressTimer = nil
            }
        }
        RunLoop.main.add(transcriptionProgressTimer!, forMode: .common)

        // Poor connection hint at 130% of estimate
        let threshold = total * 1.3
        poorConnectionStartTimer = Timer.scheduledTimer(withTimeInterval: threshold, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            showPoorConnectionUI()

            // Fade 1.0 -> 0.0 -> 1.0 ... forever (until you cancel)
            UIView.animate(withDuration: 1.0,
                           delay: 0,
                           options: [.autoreverse, .repeat, .allowUserInteraction, .curveEaseInOut],
                           animations: { [weak self] in
                               self?.PoorConnectionLabel.alpha = 0.0
                           },
                           completion: nil)
        }
        RunLoop.main.add(poorConnectionStartTimer!, forMode: .common)
    }
    
    private func showPoorConnectionUI() {
        PoorConnectionLabel.alpha = 1.0
        PoorConnectionLabel.isHidden = false
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
    
    @IBAction func SendButton(_ sender: Any) {
        Haptic.tap(intensity: 1.0)
        if recordingManager.savedAudioTranscriptionObjects.count > 0 {
            let toggledHasTranscription: Bool = recordingManager.toggledAudioTranscriptionObject.hasTranscription
            switch DestinationManager.SELECTED_DESTINATION {
            case Destination.dropbox:
                dropboxManager.SendToDropbox(hasTranscription: toggledHasTranscription)
            case Destination.onedrive:
                oneDriveManager.SendToOneDrive(hasTranscription: toggledHasTranscription)
            case Destination.googledrive:
                googleDriveManager.SendToGoogleDrive(hasTranscription: toggledHasTranscription)
            case Destination.email:
                Task { await emailManager.SendToEmail(hasTranscription: toggledHasTranscription) }
            default:
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
    
    func safeDisplayAlert(title: String, message: String, type: SafeAlertType = .other, result: SafeAlertResult) {
        if UIApplication.shared.applicationState == .active {
            // The task completed while the app was open
            if result == .success {
                if type == .transcribe {
                    AudioFeedback.shared.playDing(intensity: 0.6)
                } else if type == .send {
                    AudioFeedback.shared.playWhoosh(intensity: 0.6)
                }
            } else {
                displayAlert(title: title, message: message)
            }
        } else {
            // The task completed in the background
            if type == .transcribe {
                transcriptionCompletedInBackground = true
            } else if type == .send {
                sendingCompletedInBackground = true
            }
            alertDisplayedInBackground = true
            pendingAlertTitle = title
            pendingAlertMessage = message
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
        DestinationLabel.isEnabled = false
        DestinationLabel.alpha = disabledAlpha
    }
    
    func EnableDestinationAndSendButtons() {
        SendLabel.isEnabled = true
        SendLabel.alpha = enabledAlpha
        DestinationLabel.isEnabled = true
        DestinationLabel.alpha = enabledAlpha
    }
    
    func ShowRecordingOrListeningUI() {
        TitleOfAppLabel.alpha = disabledAlpha
        TranscribeLabel.isEnabled = false
        TranscribeLabel.alpha = disabledAlpha
        SeeTranscriptionLabel.isEnabled = false
        SeeTranscriptionLabel.alpha = disabledAlpha
        PreviousRecordingLabel.isEnabled = false
        NextRecordingLabel.isEnabled = false
        RenameFileLabel.isEnabled = false
        PreviousRecordingLabel.alpha = disabledAlpha
        NextRecordingLabel.alpha = disabledAlpha
        RenameFileLabel.alpha = disabledAlpha
        
        DisableDestinationAndSendButtons()
    }
    
    func HideRecordingOrListeningUI() {
        TitleOfAppLabel.alpha = enabledAlpha
        TranscribeLabel.isEnabled = true
        TranscribeLabel.alpha = enabledAlpha
        SeeTranscriptionLabel.isEnabled = true
        SeeTranscriptionLabel.alpha = enabledAlpha
        PreviousRecordingLabel.isEnabled = true
        NextRecordingLabel.isEnabled = true
        RenameFileLabel.isEnabled = true
        PreviousRecordingLabel.alpha = enabledAlpha
        NextRecordingLabel.alpha = enabledAlpha
        RenameFileLabel.alpha = enabledAlpha
        
        EnableDestinationAndSendButtons()
    }
    
    func ShowRecordingInProgressUI() {
        RecordLabel.isHidden = true
        StopButtonLabel.isHidden = false
        FileNameLabel.alpha = disabledAlpha
        ShowRecordingOrListeningUI()
    }
    
    func HideRecordingInProgressUI() {
        RecordLabel.isHidden = false
        StopButtonLabel.isHidden = true
        FileNameLabel.alpha = enabledAlpha
        HideRecordingOrListeningUI()
    }
    
    func ShowListeningUI() {
        ListenLabel.isHidden = true
        StopWatchLabel.isHidden = false
        PausePlaybackLabel.isHidden = false
        EndPlaybackLabel.isHidden = false
        RecordLabel.isEnabled = false
        ShowRecordingOrListeningUI()
    }
    
    func HideListeningUI() {
        ListenLabel.isHidden = false
        StopWatchLabel.isHidden = true
        PausePlaybackLabel.isHidden = true
        EndPlaybackLabel.isHidden = true
        RecordLabel.isEnabled = true
        HideRecordingOrListeningUI()
    }

    private func paddedSymbol(_ name: String, pad: CGFloat = 2) -> UIImage? {
        UIImage(systemName: name)?
            .withAlignmentRectInsets(UIEdgeInsets(top: -pad, left: -pad, bottom: -pad, right: -pad))
    }

    func NoTranscriptionUI() {
        TranscribeLabel.isHidden = false
        SeeTranscriptionLabel.isHidden = true
    }

    func HasTranscriptionUI() {
        TranscribeLabel.isHidden = true
        SeeTranscriptionLabel.isHidden = false
    }
    
    func DisableUI() {
        RecordLabel.isEnabled = false
        RecordLabel.alpha = disabledAlpha
        ListenLabel.isEnabled = false
        ListenLabel.alpha = disabledAlpha
        TitleOfAppLabel.alpha = disabledAlpha
        FileNameLabel.alpha = disabledAlpha
        ShowRecordingOrListeningUI()
    }
    
    func EnableUI() {
        RecordLabel.isEnabled = true
        RecordLabel.alpha = enabledAlpha
        ListenLabel.isEnabled = true
        ListenLabel.alpha = enabledAlpha
        TitleOfAppLabel.alpha = enabledAlpha
        FileNameLabel.alpha = enabledAlpha
        HideRecordingOrListeningUI()
    }
    
    func NoRecordingsUI() {
        ListenLabel.isHidden = true
        FileNameLabel.isHidden = true
        SendLabel.isEnabled = false
        SendLabel.alpha = disabledAlpha
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

