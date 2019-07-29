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
    @IBOutlet weak var ChooseFileTypeLabel: UIButton!
    @IBOutlet weak var FlacLabel: UIButton!
    @IBOutlet weak var M4aLabel: UIButton!
    
    
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
        SetDefaultState()
    }
    
    var recordingExtension: String = String()
    var recordingName: String = "prime_dictation"
    var formatIDKey: Int = Int()
    
    func SetDefaultState() {
        //Set selected file type to preselected file type if there is one
        if let selFileType: Int = UserDefaults.standard.object(forKey: "fileType") as? Int {
            userSelectedFileType = selFileType
        } else {
            //If not selected file type is saved, set it to .m4a by default
            userSelectedFileType = 0
        }
        
        switch userSelectedFileType {
        case 0:
            M4aLabel.setTitleColor(UIColor.orange, for: .normal)
            FlacLabel.setTitleColor(UIColor.black, for: .normal)
            recordingExtension = "m4a"
            formatIDKey = Int(kAudioFormatMPEG4AAC)
            break
        case 1:
            M4aLabel.setTitleColor(UIColor.black, for: .normal)
            FlacLabel.setTitleColor(UIColor.orange, for: .normal)
            recordingExtension = "flac"
            formatIDKey = Int(kAudioFormatFLAC)
            break
        default:
            print("Invalid userSelectedFileType")
    }
    }
    
    @IBAction func ListenButton(_ sender: Any) {
        //Store the path to the recording in this "path" variable
        let previousRecordingPath = GetDirectory().appendingPathComponent(recordingName).appendingPathExtension(recordingExtension)
        //Play the previously recorded recording
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: previousRecordingPath)
            audioPlayer.play()
        } catch {
            displayAlert(title: "Error!", message: "Could not play recording, no recording exists or you have bad connection")
        }
    }
    
    
    
    @IBAction func RecordButton(_ sender: Any) {
        //Check if we have an active recorder
        if audioRecorder == nil {
            //If we are not already recording audio, start the recording
            numberOfRecordings += 1
            
            let fileName = GetDirectory().appendingPathComponent(recordingName).appendingPathExtension(recordingExtension)
            
            var settings = [ AVFormatIDKey: formatIDKey, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
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
            
            //Save the recording
            UserDefaults.standard.set(numberOfRecordings, forKey: "myNumber")
        }
        
    }
    
    var soundEffect: AVAudioPlayer = AVAudioPlayer()
    var isPlaying: Bool = false;
    @IBAction func SendButton(_ sender: Any) {
        
    }
    
    @IBAction func ChooseFileTypeButton(_ sender: Any) {
    }
    
    @IBAction func FlacButton(_ sender: Any) {
        userSelectedFileType = 1
        UserDefaults.standard.set(userSelectedFileType, forKey: "fileType")
        M4aLabel.setTitleColor(UIColor.black, for: .normal)
        FlacLabel.setTitleColor(UIColor.orange, for: .normal)
        recordingExtension = "flac"
        formatIDKey = Int(kAudioFormatFLAC)
    }
    
    @IBAction func M4aButton(_ sender: Any) {
        userSelectedFileType = 0
        UserDefaults.standard.set(userSelectedFileType, forKey: "fileType")
        M4aLabel.setTitleColor(UIColor.orange, for: .normal)
        FlacLabel.setTitleColor(UIColor.black, for: .normal)
        recordingExtension = "m4a"
        formatIDKey = Int(kAudioFormatMPEG4AAC)
    }
    
    //Get path to directory
    func GetDirectory() -> URL {
        //Search for all urls in document directory
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        
        //Get the first URL in the document directory
        let documentDirectory = path[0]
        //Return the url to that directory
        print(documentDirectory)
        return documentDirectory
    }
    
    //Display an alert if something goes wrong
    func displayAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
        present(alert, animated: true, completion: nil)
    }
}



