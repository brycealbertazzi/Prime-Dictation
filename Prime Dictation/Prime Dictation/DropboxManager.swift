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
    
    func SendToDropbox(url: URL)
    {
        if let client: DropboxClient = DropboxClientsManager.authorizedClient {
            //Send recording to dropbox folder for this app
            _ = client.files.upload(path: "/" + recordingManager.toggledRecordingName + "." + recordingManager.destinationRecordingExtension, input: url)
                .response { (response, error) in
                    if let response = response {
                        print(response)
                        ProgressHUD.succeed("Recording was sent to dropbox")
                    } else if let error = error {
                        print(error)
                        ProgressHUD.failed("Failed to send recording, try checking your connection or signing in again")
                    }
                    self.viewController.HideSendingUI()
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
