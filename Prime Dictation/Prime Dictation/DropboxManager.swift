//
//  Dropbox.swift
//  Prime Dictation
//
//  Created by Bryce Albertazzi on 9/16/25.
//  Copyright © 2025 Bryce Albertazzi. All rights reserved.
//
import UIKit
import AVFoundation
import SwiftyDropbox
import ProgressHUD

class DropboxManager {
    
    var viewController: ViewController!
    var recordingManager: RecordingManager!
    
    init(viewController: ViewController, recordingManager: RecordingManager) {
        self.viewController = viewController
        self.recordingManager = recordingManager
    }
    
    func SendToDropbox()
    {
        if let client: DropboxClient = DropboxClientsManager.authorizedClient {
            print("Client is already authorized")
            if recordingManager.savedRecordingNames.count > 0 {
                ProgressHUD.animate("Sending...")
                viewController.SignInLabel.isEnabled = false
                viewController.SendLabel.isEnabled = false
                viewController.SignInLabel.setTitleColor(UIColor(red: 0, green: 0, blue: 0, alpha: 0.3), for: .normal)
                viewController.SendLabel.setTitleColor(UIColor(red: 0, green: 0, blue: 0, alpha: 0.3), for: .normal)
                viewController.RecordLabel.isEnabled = false
                viewController.ListenLabel.isEnabled = false
                viewController.FileNameLabel.setTitleColor(UIColor(red: 0, green: 0, blue: 0, alpha: 0.3), for: .normal)
                viewController.TitleOfAppLabel.textColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0.3)
                viewController.PreviousRecordingLabel.isEnabled = false
                viewController.NextRecordingLabel.isEnabled = false
                viewController.PreviousRecordingLabel.setTitleColor(UIColor(red: 0, green: 0, blue: 0, alpha: 0.3), for: .normal)
                viewController.NextRecordingLabel.setTitleColor(UIColor(red: 0, green: 0, blue: 0, alpha: 0.3), for: .normal)
                
                //Send recording to dropbox folder for this app
                let recordingToUpload: URL = recordingManager.GetDirectory().appendingPathComponent(recordingManager.toggledRecordingName).appendingPathExtension(recordingManager.destinationRecordingExtension)
                _ = client.files.upload(path: "/" + recordingManager.toggledRecordingName + "." + recordingManager.destinationRecordingExtension, input: recordingToUpload)
                        .response { (response, error) in
                            if let response = response {
                                print(response)
                                ProgressHUD.succeed("Recording was sent to dropbox")
                            } else if let error = error {
                                print(error)
                                ProgressHUD.failed("Failed to send recording, try checking your connection or signing in again")
                            }
                            self.viewController.SignInLabel.setTitleColor(UIColor.black, for: .normal)
                            self.viewController.SendLabel.setTitleColor(UIColor.black, for: .normal)
                            self.viewController.SignInLabel.isEnabled = true
                            self.viewController.SendLabel.isEnabled = true
                            self.viewController.RecordLabel.isEnabled = true
                            self.viewController.ListenLabel.isEnabled = true
                            self.viewController.FileNameLabel.setTitleColor(UIColor.black, for: .normal)
                            self.viewController.TitleOfAppLabel.textColor = UIColor.black
                            self.viewController.PreviousRecordingLabel.isEnabled = true
                            self.viewController.NextRecordingLabel.isEnabled = true
                            self.viewController.PreviousRecordingLabel.setTitleColor(UIColor.black, for: .normal)
                            self.viewController.NextRecordingLabel.setTitleColor(UIColor.black, for: .normal)
                        }
            } else {
                ProgressHUD.failed("No recording to send")
            }
        } else {
            OpenDropboxAuthorizationFlow()
        }
    }
    
    var url: URL = URL(string: "https://www.dropbox.com/oauth2/authorize")!
    func OpenDropboxAuthorizationFlow() {
        DropboxClientsManager.authorizeFromControllerV2(
            UIApplication.shared,
            controller: viewController,
            loadingStatusDelegate: nil, // optional
            openURL: { url in
                UIApplication.shared.open(url)
            },
            scopeRequest: ScopeRequest(
                scopeType: .user,
                scopes: ["files.content.write", "files.content.read"],
                includeGrantedScopes: false
            )
        )
    }
}
