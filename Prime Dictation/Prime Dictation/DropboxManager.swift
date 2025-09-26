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
    
    var viewController: ViewController?
    var settingsViewController: SettingsViewController?
    var recordingManager: RecordingManager?
    
    init(viewController: ViewController, recordingManager: RecordingManager) {
        self.viewController = viewController
        self.recordingManager = recordingManager
    }
    
    init(settingsViewController: SettingsViewController) {
        self.settingsViewController = settingsViewController
    }
    
    func SendToDropbox(url: URL)
    {
        guard let viewController = viewController else { return }
        
        if let client: DropboxClient = DropboxClientsManager.authorizedClient {
            //Send recording to dropbox folder for this app
            ProgressHUD.animate("Sending...", .triangleDotShift)
            viewController.ShowSendingUI()
            var recordingName = "dropbox_recording"
            if let recordingManager = recordingManager {
                recordingName = recordingManager.toggledRecordingName + "." + recordingManager.destinationRecordingExtension
            }
            _ = client.files.upload(path: "/" + recordingName, input: url)
                .response { (response, error) in
                    if let response = response {
                        print(response)
                        ProgressHUD.succeed("Recording was sent to Dropbox")
                        viewController.HideSendingUI()
                    } else if let _ = error {
                        ProgressHUD.dismiss()
                        viewController.displayAlert(title: "Recording send failed", message: "Check your internet connection and try again.", handler: {
                            viewController.HideSendingUI()
                            ProgressHUD.failed("Failed to send recording to Dropbox")
                        })
                    }
                    
                }
        } else {
            OpenDropboxAuthorizationFlow()
        }
    }
    
    var url: URL = URL(string: "https://www.dropbox.com/oauth2/authorize")!
    func OpenDropboxAuthorizationFlow()
    {
        guard let settingsViewController = settingsViewController else { return }
        
        DropboxClientsManager.authorizeFromControllerV2(
            UIApplication.shared,
            controller: settingsViewController,
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
