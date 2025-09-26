//
//  SettingsViewController.swift
//  Prime Dictation
//
//  Created by Bryce Albertazzi on 9/25/25.
//  Copyright © 2025 Bryce Albertazzi. All rights reserved.
//
import UIKit
import AVFoundation

class SettingsViewController: UIViewController {
    var dropboxManager: DropboxManager!
    var oneDriveManager: OneDriveManager!
    
    override func viewDidLoad() {
        dropboxManager = DropboxManager(settingsViewController: self)
        oneDriveManager = OneDriveManager(settingsViewController: self)
    }
    
    @IBAction func DropboxButton(_ sender: Any) {
        dropboxManager.OpenDropboxAuthorizationFlow()
    }
    
    @IBAction func OneDriveButton(_ sender: Any) {
        oneDriveManager.SignInInteractively()
    }
    
    func displayAlert(title: String, message: String, handler: (@MainActor () -> Void)? = nil) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: {_ in
            handler?()
        }))
        present(alert, animated: true, completion: nil)
    }
}
