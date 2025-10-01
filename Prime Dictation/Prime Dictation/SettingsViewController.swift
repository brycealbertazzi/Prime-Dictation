//
//  SettingsViewController.swift
//  Prime Dictation
//
//  Created by Bryce Albertazzi on 9/25/25.
//  Copyright © 2025 Bryce Albertazzi. All rights reserved.
//
import UIKit
import AVFoundation
import SwiftyDropbox
import ProgressHUD

class SettingsViewController: UIViewController {
    var dropboxManager: DropboxManager!
    var oneDriveManager: OneDriveManager!
    var destinationManager: DestinationManager!
    
    @IBOutlet weak var DropboxLabel: UIButton!
    @IBOutlet weak var OneDriveLabel: UIButton!
    @IBOutlet weak var SelectFolderIcon: UIButton!
    
    override func viewDidLoad() {
        super.viewDidLoad()

        let services = AppServices.shared
        dropboxManager = services.dropboxManager
        oneDriveManager = services.oneDriveManager
        destinationManager = services.destinationManager

        dropboxManager.attach(settingsViewController: self)
        oneDriveManager.attach(settingsViewController: self)
        destinationManager.attach(settingsViewController: self)
        
        UpdateSelectedDestinationUI(destination: DestinationManager.SELECTED_DESTINATION)
    }
    
    @IBAction func DropboxButton(_ sender: Any) {
        dropboxManager.OpenAuthorizationFlow { result in
            switch result {
            case .success:
                self.UpdateSelectedDestinationUserDefaults(destination: .dropbox)
                self.UpdateSelectedDestinationUI(destination: .dropbox)
            case .cancel:
                ProgressHUD.failed("Canceled Dropbox Login")
            case .error(_, _):
                ProgressHUD.failed("Unable to log into Dropbox")
            case .none:
                ProgressHUD.failed("Unable to log into Dropbox")
            }
        }
    }
    
    @IBAction func OneDriveButton(_ sender: Any) {
        oneDriveManager.SignInIfNeeded { result in
            switch result {
            case .success:
                self.UpdateSelectedDestinationUserDefaults(destination: .onedrive)
                self.UpdateSelectedDestinationUI(destination: .onedrive)
                break
            case .cancel:
                ProgressHUD.failed("Canceled OneDrive Login")
            case .error:
                ProgressHUD.failed("Unable to log into OneDrive")
            }
        }
    }
    
    @IBAction func SelectFolderButton(_ sender: Any) {
        switch DestinationManager.SELECTED_DESTINATION {
        case.dropbox:
            ProgressHUD.animate("Opening file picker", .activityIndicator)
            dropboxManager.PresentDropboxFolderPicker { selection in
                ProgressHUD.succeed("Dropbox folder selected")
            }
            break
        case .onedrive:
            ProgressHUD.animate("Opening file picker", .activityIndicator)
            oneDriveManager.PresentOneDriveFolderPicker { selection in
                // Optional: update your UI to show the chosen folder
                ProgressHUD.succeed("OneDrive folder selected")
            }
            break
        default:
            ProgressHUD.failed("No destination selected")
            break
        }
    }
    
    
    @IBAction func SignOutButton(_ sender: Any) {
        switch DestinationManager.SELECTED_DESTINATION {
        case .dropbox:
            print("Signing out of Dropbox")
            dropboxManager.signOutAppOnly(completion: {(error) in
                ProgressHUD.succeed("Signed out of Dropbox")
                self.UpdateSelectedDestinationUserDefaults(destination: Destination.none)
                self.UpdateSelectedDestinationUI(destination: Destination.none)
            })
            break
        case .onedrive:
            print("Signing out of OneDrive")
            oneDriveManager.SignOutAppOnly(completion: { (error) in
                ProgressHUD.succeed("Signed out of OneDrive")
                self.UpdateSelectedDestinationUserDefaults(destination: Destination.none)
                self.UpdateSelectedDestinationUI(destination: Destination.none)
            })
            break
        default:
            break
        }
    }
    
    func UpdateSelectedDestinationUserDefaults(destination: Destination) {
        destinationManager.setSelectedDestination(destination)
    }
    
    func UpdateSelectedDestinationUI(destination: Destination? = Destination.none) {
        let selectedColor: UIColor = .systemBlue
        SelectFolderIcon.isEnabled = true
        SelectFolderIcon.alpha = 1.0
        if destination == .dropbox {
            DropboxLabel.setTitleColor(selectedColor, for: .normal)
            OneDriveLabel.setTitleColor(.black, for: .normal)
        } else if destination == .onedrive {
            OneDriveLabel.setTitleColor(selectedColor, for: .normal)
            DropboxLabel.setTitleColor(.black, for: .normal)
        } else {
            DropboxLabel.setTitleColor(.black, for: .normal)
            OneDriveLabel.setTitleColor(.black, for: .normal)
            SelectFolderIcon.isEnabled = false
            SelectFolderIcon.alpha = 0.36
        }
    }
    
    func displayAlert(title: String, message: String, handler: (@MainActor () -> Void)? = nil) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: {_ in
            handler?()
        }))
        present(alert, animated: true, completion: nil)
    }
}
