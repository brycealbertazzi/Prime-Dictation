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

class SettingsViewController: UIViewController {
    var dropboxManager: DropboxManager!
    var oneDriveManager: OneDriveManager!
    var destinationManager: DestinationManager!
    
    @IBOutlet weak var DropboxLabel: UIButton!
    @IBOutlet weak var OneDriveLabel: UIButton!
    
    override func viewDidLoad() {
        destinationManager = DestinationManager(settingsViewController: self)
        dropboxManager = DropboxManager(settingsViewController: self)
        oneDriveManager = OneDriveManager(settingsViewController: self)
        
        destinationManager.getDestination()
        print("SELECTED_DESTINATION: \(DestinationManager.SELECTED_DESTINATION)")
        UpdateSelectedDestinationUI(destination: DestinationManager.SELECTED_DESTINATION)
    }
    
    @IBAction func DropboxButton(_ sender: Any) {
//        dropboxManager.OpenDropboxAuthorizationFlow()
        destinationManager.setSelectedDestination(Destination.dropbox)
        UpdateSelectedDestinationUI(destination: .dropbox)
    }
    
    @IBAction func OneDriveButton(_ sender: Any) {
//        oneDriveManager.SignInInteractively()
        destinationManager.setSelectedDestination(Destination.onedrive)
        UpdateSelectedDestinationUI(destination: .onedrive)
    }
    
    func UpdateSelectedDestinationUI(destination: Destination? = Destination.none) {
        let selectedColor: UIColor = .systemBlue
        print(destination!)
        if destination == .dropbox {
            DropboxLabel.setTitleColor(selectedColor, for: .normal)
            OneDriveLabel.setTitleColor(.black, for: .normal)
        } else if destination == .onedrive {
            OneDriveLabel.setTitleColor(selectedColor, for: .normal)
            DropboxLabel.setTitleColor(.black, for: .normal)
        } else {
            DropboxLabel.setTitleColor(.black, for: .normal)
            OneDriveLabel.setTitleColor(.black, for: .normal)
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
