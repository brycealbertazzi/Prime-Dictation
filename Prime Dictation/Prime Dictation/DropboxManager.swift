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
    enum AuthResult
    {
        case success
        case cancel
        case error(Error?, String?)
        case none
    }
    
    var viewController: ViewController?
    var settingsViewController: SettingsViewController?
    var recordingManager: RecordingManager?
    
    private var authCompletion: ((AuthResult) -> Void)?
    static var DROPBOX_AUTH_RESULT: DropboxOAuthResult? = nil
    
    init() {}

    func attach(settingsViewController: SettingsViewController) {
        self.settingsViewController = settingsViewController
    }
    
    func attach(viewController: ViewController, recordingManager: RecordingManager) {
        self.viewController = viewController
        self.recordingManager = recordingManager
    }
    
    var isSignedIn: Bool {
        DropboxClientsManager.authorizedClient != nil || DropboxClientsManager.authorizedTeamClient != nil
    }
    
    @MainActor
    func signOutAppOnly(completion: @escaping (Bool) -> Void) {
        // If nothing is linked, treat as success
        guard isSignedIn else { completion(true); return }

        // Clear local tokens for both user & team clients (if any)
        DropboxClientsManager.unlinkClients()
        completion(true)
    }
    
    var url: URL = URL(string: "https://www.dropbox.com/oauth2/authorize")!
    // Start auth; do NOT handle result here
    func OpenAuthorizationFlow(completion: @escaping (AuthResult) -> Void) {
        // Short-circuit if already signed in
        if DropboxClientsManager.authorizedClient != nil {
            completion(.success)
            return
        }

        guard let presenter = settingsViewController else { return }
        self.authCompletion = completion

        DropboxClientsManager.authorizeFromControllerV2(
            UIApplication.shared,
            controller: presenter,
            loadingStatusDelegate: nil,
            openURL: { UIApplication.shared.open($0) },
            scopeRequest: ScopeRequest(
                scopeType: .user,
                scopes: ["files.content.write", "files.content.read"],
                includeGrantedScopes: false
            )
        )
    }
    
    // Called from AppDelegate (or your OAuth router) on redirect
    @discardableResult
    func handleRedirect(url: URL) -> Bool {
        DropboxClientsManager.handleRedirectURL(url, includeBackgroundClient: false) { [weak self] result in
            guard let self = self else { return }
            ProgressHUD.dismiss()

            switch result {
            case .success:
                ProgressHUD.succeed("Signed into Dropbox")
                self.authCompletion?(.success)
            case .cancel:
                self.authCompletion?(.cancel)
            case .error(let e, let desc):
                self.authCompletion?(.error(e, desc))
            case .none:
                self.authCompletion?(.none)
            }
            self.authCompletion = nil
        }
        return true
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
            OpenAuthorizationFlow { result in
                switch result {
                case .success:
                    self.settingsViewController?.UpdateSelectedDestinationUserDefaults(destination: .dropbox)
                    self.settingsViewController?.UpdateSelectedDestinationUI(destination: .dropbox)
                case .cancel:
                    ProgressHUD.failed("Canceled Dropbox Login")
                case .error(_, _):
                    ProgressHUD.failed("Unable to log into Dropbox")
                case .none:
                    ProgressHUD.failed("Unable to log into Dropbox")
                }
            }
        }
    }
}
