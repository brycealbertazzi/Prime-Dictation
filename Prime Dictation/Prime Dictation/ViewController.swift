//
//  ViewController.swift
//  Prime Dictation
//
//  Created by Bryce Albertazzi on 7/28/19.
//  Copyright © 2019 Bryce Albertazzi. All rights reserved.
//

import UIKit
import AVFoundation
import ProgressHUD
import MSGraphMSALAuthProvider
import MSGraphClientSDK


class ViewController: UIViewController, AVAudioRecorderDelegate, UIApplicationDelegate, AVAudioPlayerDelegate {

    //MARK: - IBOutlets
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
    @IBOutlet weak var LowQualityLabel: UIButton!
    @IBOutlet weak var MediumQualityLabel: UIButton!
    @IBOutlet weak var HighQualityLabel: UIButton!
    @IBOutlet weak var QualityLabel: UIButton!
    
    
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
        CloseQualitySelect()
        
        /*****/
        //FileNameLabel should be disabled at all times
        FileNameLabel.isEnabled = false
        /*****/
        //Initialize recording session
        recordingSession = AVAudioSession.sharedInstance()
        RecordLabel.setImage(UIImage(named: "RecordButton"), for: .normal)
        //Request permission
        AVAudioSession.sharedInstance().requestRecordPermission { (hasPermission) in
            
        }
        savedRecordingNames = UserDefaults.standard.object(forKey: savedRecordingsKey) as? [String] ?? [String]()
        
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
        
        switch UserDefaults.standard.integer(forKey: SOUND_QUALITY_KEY) {
            case 0:
                sampleRate = 8000
                break
            case 1:
                sampleRate = 16000
                break
            case 2:
                sampleRate = 44100
                break
            default:
                UserDefaults.standard.set(1, forKey: SOUND_QUALITY_KEY)
                sampleRate = 16000
        }
        
        EnablePlaybackSpeedControls()
        UpdateSliderDisplay(with: 5)
        PlaybackSpeedSliderLabel.value = PlaybackSpeedSliderLabel.maximumValue
    }
    //MARK: MSAL Functions

    
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
                audioPlayer.enableRate = true
                audioPlayer.rate = 1 / Float(playbackListenSpeed)
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
                DisableQualityControls()
                DisablePlaybackSpeedControls()
                
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
            EnableQualityControls()
            EnablePlaybackSpeedControls()
            watch.stop()
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

    var sampleRate = 8000
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
                DisableQualityControls()
                DisablePlaybackSpeedControls()
                
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
            let elapsedTime = watch.elapsedTime / Double(playbackListenSpeed)
            let minutes = Int(elapsedTime / 60)
            let seconds = Int(elapsedTime.truncatingRemainder(dividingBy: 60))
            let tensOfSeconds = Int((elapsedTime * 10).truncatingRemainder(dividingBy: 10))
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
        PausePlayButtonLabel.setImage(UIImage(named: "PauseButton-2"), for: .normal)
        SendLabel.setTitleColor(UIColor.black, for: .normal)
        SendLabel.isEnabled = true
        SignInLabel.isEnabled = true
        SignInLabel.setTitleColor(UIColor.black, for: .normal)
        EnableQualityControls()
        EnablePlaybackSpeedControls()
        
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
            PausePlayButtonLabel.setImage(UIImage(named: "PlayButton-2"), for: .normal)
            audioRecorder.pause()
            isRecordingPaused = true
            watch.pause()
        } else {
            PausePlayButtonLabel.setImage(UIImage(named: "PauseButton-2"), for: .normal)
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
        EnableQualityControls()
        EnablePlaybackSpeedControls()
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
    
    
    // One Drive for Business
    @IBAction func SendButton(_ sender: Any) {
        print(AppDelegate.config)
        print(AppDelegate.MSPublicClientApp)
        print(AppDelegate.MSAuthProviderOptions)
        print(AppDelegate.MSAuthProvider)
        print(AppDelegate.httpClient)
        // Construct the request to send the recording
        let request: NSMutableURLRequest = NSMutableURLRequest(url: URL(string: AppDelegate.kGraphEndpoint)!)

        print(request)
//        //Execute the request
        let sendRecordingTask: MSURLSessionDataTask? = AppDelegate.httpClient?.dataTask(with: request, completionHandler: { (data, response, error) in

            print(request)
            if (error != nil) {
                print("Error:")
                print(error)
                ProgressHUD.showError("Please sign into your Microsoft account")
            } else {
                print("Data:")
                print(data)
                print("Response:")
                print(response)
            }
        })

        sendRecordingTask?.execute()
        
        
//        if let client: DropboxClient = DropboxClientsManager.authorizedClient {
//            print("Client is already authorized")
//            if savedRecordingNames.count > 0 {
//                // UI interactions
//                ProgressHUD.show("Sending...")
//                SignInLabel.isEnabled = false
//                SendLabel.isEnabled = false
//                SignInLabel.setTitleColor(UIColor(red: 0, green: 0, blue: 0, alpha: 0.3), for: .normal)
//                SendLabel.setTitleColor(UIColor(red: 0, green: 0, blue: 0, alpha: 0.3), for: .normal)
//                RecordLabel.isEnabled = false
//                ListenLabel.isEnabled = false
//                FileNameLabel.setTitleColor(UIColor(red: 0, green: 0, blue: 0, alpha: 0.3), for: .normal)
//                TitleOfAppLabel.textColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0.3)
//                PreviousRecordingLabel.isEnabled = false
//                NextRecordingLabel.isEnabled = false
//                PreviousRecordingLabel.setTitleColor(UIColor(red: 0, green: 0, blue: 0, alpha: 0.3), for: .normal)
//                NextRecordingLabel.setTitleColor(UIColor(red: 0, green: 0, blue: 0, alpha: 0.3), for: .normal)
//                DisableQualityControls()
//                DisablePlaybackSpeedControls()
//
//                //Send recording to dropbox folder for this app
//                //TODO: Send to OneDrive instead
//                let recordingToUpload: URL = GetDirectory().appendingPathComponent(toggledRecordingName).appendingPathExtension(destinationRecordingExtension)
//                    _ = client.files.upload(path: "/" + toggledRecordingName + "." + destinationRecordingExtension, input: recordingToUpload)
//                        .response { (response, error) in
//                            if let response = response {
//                                print(response)
//                                ProgressHUD.showSuccess("Recording was sent to Dropbox", interaction: true)
//                            } else if let error = error {
//                                print(error)
//                                ProgressHUD.showError("Failed to send recording to dropbox, check your connections", interaction: true)
//                            }
//                            //Update UI on send
//                            self.SignInLabel.setTitleColor(UIColor.black, for: .normal)
//                            self.SendLabel.setTitleColor(UIColor.black, for: .normal)
//                            self.SignInLabel.isEnabled = true
//                            self.SendLabel.isEnabled = true
//                            self.RecordLabel.isEnabled = true
//                            self.ListenLabel.isEnabled = true
//                            self.FileNameLabel.setTitleColor(UIColor.black, for: .normal)
//                            self.TitleOfAppLabel.textColor = UIColor.black
//                            self.PreviousRecordingLabel.isEnabled = true
//                            self.NextRecordingLabel.isEnabled = true
//                            self.PreviousRecordingLabel.setTitleColor(UIColor.black, for: .normal)
//                            self.NextRecordingLabel.setTitleColor(UIColor.black, for: .normal)
//                            self.EnableQualityControls()
//                            self.EnablePlaybackSpeedControls()
//                            ////////////
//                        }
//            } else {
//                ProgressHUD.showError("No recording to send")
//            }
//        } else {
//            OpenAuthorizationFlow()
//        }
    }
    
    
    
    @IBAction func SignInButton(_ sender: Any) {
        if let msPublicClientApp = try? MSALPublicClientApplication(clientId: AppDelegate.kClientID) {
            #if os(iOS)
                let viewController = self // Pass a reference to the view controller that should be used when getting a token interactively
            let webviewParameters = MSALWebviewParameters(parentViewController: viewController)
                #else
                let webviewParameters = MSALWebviewParameters()
                #endif
                
            let interactiveParameters = MSALInteractiveTokenParameters(scopes: AppDelegate.kScopes, webviewParameters: webviewParameters)
                msPublicClientApp.acquireToken(with: interactiveParameters, completionBlock: { (result, error) in
                            
                    guard let authResult = result, error == nil else {
                        print(error!.localizedDescription)
                        ProgressHUD.showError("Unable to sign in to OneDrive, access denied")
                        return
                    }
                                
                    // Get access token from result
                    let accessToken = authResult.accessToken
                                
                    // You'll want to get the account identifier to retrieve and reuse the account for later acquireToken calls
                    let accountIdentifier = authResult.account.identifier
                    
                    if let msAuthProviderOptions = try? MSALAuthenticationProviderOptions(scopes: AppDelegate.kScopes) {
                        print("AuthProviderOptions")
                        print(msAuthProviderOptions.scopesArray as Any)
                        AppDelegate.MSAuthProviderOptions = msAuthProviderOptions
                    } else {
                        ProgressHUD.showError("Unable to sign into OneDrive")
                        return
                    }
                    
                    if let msAuthProvider = try? MSALAuthenticationProvider(publicClientApplication: AppDelegate.MSPublicClientApp!, andOptions: AppDelegate.MSAuthProviderOptions!) {
                        print("AuthProvider")
                        print(msAuthProvider)
                        AppDelegate.MSAuthProvider = msAuthProvider
                    } else {
                        ProgressHUD.showError("Unable to sign into OneDrive")
                        return
                    }
                    
                    AppDelegate.httpClient = MSClientFactory.createHTTPClient(with: AppDelegate.MSAuthProvider)
                    print(AppDelegate.httpClient)
                    ProgressHUD.showSuccess("Successfully signed into OneDrive!")
                })
            print(msPublicClientApp.configuration.clientId)
            AppDelegate.MSPublicClientApp = msPublicClientApp
            
            
            
        } else {
            ProgressHUD.showError("Unable to sign into OneDrive")
            return
        }
        
    }
    

    
    //MARK: - Playback Controls
    @IBOutlet weak var PlaybackSpeedToggleLabel: UIButton!
    @IBOutlet weak var PlaybackSpeedDisplayLabel: UILabel!
    @IBOutlet weak var PlaybackSpeedSliderLabel: UISlider!
    
    @IBAction func PlaybackButtonPressed(_ sender: UIButton) {
        ShowSlider()
    }
    
    @IBAction func SliderValueChanged(_ sender: UISlider) {
        PlaybackSpeedSliderLabel.value = roundf(PlaybackSpeedSliderLabel.value)
        UpdateSliderDisplay(with: Int(PlaybackSpeedSliderLabel.value))
    }
    
    @IBAction func TouchUpInside(_ sender: UISlider) {
        EnablePlaybackSpeedControls()
    }
    
    func DisablePlaybackSpeedControls() {
        PlaybackSpeedToggleLabel.isHidden = true
        PlaybackSpeedDisplayLabel.isHidden = true
        PlaybackSpeedSliderLabel.isHidden = true
    }
    
    //Also hides the slider
    func EnablePlaybackSpeedControls() {
        PlaybackSpeedToggleLabel.isHidden = false
        PlaybackSpeedDisplayLabel.isHidden = true
        PlaybackSpeedSliderLabel.isHidden = true
    }
    
    func ShowSlider() {
        PlaybackSpeedToggleLabel.isHidden = true
        PlaybackSpeedDisplayLabel.isHidden = false
        PlaybackSpeedSliderLabel.isHidden = false
    }
    
    var playbackListenSpeed : Int = 1
    func UpdateSliderDisplay(with value: Int) {
        var playbackSpeed : String = "1"
        switch value {
        case 1:
            playbackSpeed = "1/16x"
            playbackListenSpeed = 16
            break
        case 2:
            playbackSpeed = "1/8x"
            playbackListenSpeed = 8
            break
        case 3:
            playbackSpeed = "1/4x"
            playbackListenSpeed = 4
            break
        case 4:
            playbackSpeed = "1/2x"
            playbackListenSpeed = 2
            break
        case 5:
            playbackSpeed = "1x"
            playbackListenSpeed = 1
            break
        default:
            playbackSpeed = "1x"
            playbackListenSpeed = 1
        }
        PlaybackSpeedDisplayLabel.text = playbackSpeed
    }
    
    //MARK: - Quality Controls
    @IBAction func LowQualityButtonPressed(_ sender: Any) {
        SetQuality(rate: 8000, SKInt: 0)
        CloseQualitySelect()
    }
    
    @IBAction func MediumQualityButtonPressed(_ sender: Any) {
        SetQuality(rate: 16000, SKInt: 1)
        CloseQualitySelect()
    }
    
    @IBAction func HighQualityButtonPressed(_ sender: Any) {
        SetQuality(rate: 44100, SKInt: 2)
        CloseQualitySelect()
    }
    
    @IBAction func QualityButtonPressed(_ sender: Any) {
        OpenQualitySelect()
    }
    
}

let SOUND_QUALITY_KEY = "SoundQualityKey"
extension ViewController {
    func SetQuality(rate: Int, SKInt: Int) {
        sampleRate = rate
        UserDefaults.standard.set(SKInt, forKey: SOUND_QUALITY_KEY)
    }
    
    func OpenQualitySelect() {
        QualityLabel.isHidden = true
        LowQualityLabel.isHidden = false
        MediumQualityLabel.isHidden = false
        HighQualityLabel.isHidden = false
        
        //Check which one should be in orange
        switch UserDefaults.standard.integer(forKey: SOUND_QUALITY_KEY) {
        case 0:
            LowQualityLabel.setTitleColor(UIColor.orange, for: .normal)
            MediumQualityLabel.setTitleColor(UIColor.black, for: .normal)
            HighQualityLabel.setTitleColor(UIColor.black, for: .normal)
            break
        case 1:
            LowQualityLabel.setTitleColor(UIColor.black, for: .normal)
            MediumQualityLabel.setTitleColor(UIColor.orange, for: .normal)
            HighQualityLabel.setTitleColor(UIColor.black, for: .normal)
            break
        case 2:
            LowQualityLabel.setTitleColor(UIColor.black, for: .normal)
            MediumQualityLabel.setTitleColor(UIColor.black, for: .normal)
            HighQualityLabel.setTitleColor(UIColor.orange, for: .normal)
            break
        default:
            LowQualityLabel.setTitleColor(UIColor.black, for: .normal)
            MediumQualityLabel.setTitleColor(UIColor.black, for: .normal)
            HighQualityLabel.setTitleColor(UIColor.black, for: .normal)
        }
    }
    
    func CloseQualitySelect() {
        QualityLabel.isHidden = false
        LowQualityLabel.isHidden = true
        MediumQualityLabel.isHidden = true
        HighQualityLabel.isHidden = true
    }
    
    func DisableQualityControls() {
        CloseQualitySelect()
        QualityLabel.isEnabled = false
        QualityLabel.setTitleColor(UIColor(red: 0, green: 0, blue: 0, alpha: 0.3), for: .normal)
    }
    
    func EnableQualityControls() {
        QualityLabel.isEnabled = true
        QualityLabel.setTitleColor(UIColor.black, for: .normal)
    }
    
}



