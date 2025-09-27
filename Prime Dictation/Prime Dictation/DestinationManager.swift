//
//  DestinationManager.swift
//  Prime Dictation
//
//  Created by Bryce Albertazzi on 9/26/25.
//  Copyright © 2025 Bryce Albertazzi. All rights reserved.
//
import UIKit
import AVFoundation
import SwiftyDropbox
import MSAL

enum Destination: String {
    case dropbox
    case onedrive
    case none
}

class DestinationManager {
    var settingsViewController: SettingsViewController!
    static var SELECTED_DESTINATION: Destination = .none
    let defaults = UserDefaults.standard
    let key: String = "SELECTED_DESTINATION"
    
    init() {}
    
    func attach(settingsViewController: SettingsViewController) {
        self.settingsViewController = settingsViewController
    }
    
    func setSelectedDestination(_ destination: Destination) {
        defaults.set(destination.rawValue, forKey: key)
        Self .SELECTED_DESTINATION = destination
    }
    
    func getDestination() {
        if let saved = defaults.string(forKey: key),
           let selectedDestination = Destination(rawValue: saved) {
            Self .SELECTED_DESTINATION = selectedDestination
        } else {
            Self .SELECTED_DESTINATION = .none
        }
    }
}
