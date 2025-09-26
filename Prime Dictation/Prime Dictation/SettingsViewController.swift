//
//  SettingsViewController.swift
//  Prime Dictation
//
//  Created by Bryce Albertazzi on 9/25/25.
//  Copyright © 2025 Bryce Albertazzi. All rights reserved.
//
import UIKit
import AVFoundation

enum Destination: String {
    case dropbox
    case onedrive
    case none
}

class SettingsViewController: UIViewController {
    var dropboxManager: DropboxManager!
    var oneDriveManager: OneDriveManager!
    static var SELECTED_DESTINATION: Destination?
    let defaults = UserDefaults.standard
    let key: String = "SELECTED_DESTINATION"
    
    @IBOutlet weak var DropboxLabel: UIButton!
    @IBOutlet weak var OneDriveLabel: UIButton!
    
    override func viewDidLoad() {
        dropboxManager = DropboxManager(settingsViewController: self)
        oneDriveManager = OneDriveManager(settingsViewController: self)
        if let saved = defaults.string(forKey: key),
           let selectedDestination = Destination(rawValue: saved) {
            Self.SELECTED_DESTINATION = selectedDestination
            UpdateSelectedDestinationUI(destination: selectedDestination)
        } else {
            Self.SELECTED_DESTINATION = Destination.none
            UpdateSelectedDestinationUI(destination: Destination.none)
        }
        
    }
    
    @IBAction func DropboxButton(_ sender: Any) {
//        dropboxManager.OpenDropboxAuthorizationFlow()
        defaults.set(Destination.dropbox.rawValue, forKey: key)
        Self .SELECTED_DESTINATION = .dropbox
        UpdateSelectedDestinationUI(destination: .dropbox)
    }
    
    @IBAction func OneDriveButton(_ sender: Any) {
//        oneDriveManager.SignInInteractively()
        defaults.set(Destination.onedrive.rawValue, forKey: key)
        Self .SELECTED_DESTINATION = .onedrive
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
