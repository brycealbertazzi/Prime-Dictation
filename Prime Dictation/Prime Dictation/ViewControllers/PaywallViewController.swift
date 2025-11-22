//
//  PaywallViewController.swift
//  Prime Dictation
//
//  Created by Bryce Albertazzi on 11/21/25.
//  Copyright © 2025 Bryce Albertazzi. All rights reserved.
//

import UIKit
import AVFoundation
import ProgressHUD

class PaywallViewController: UIViewController {
    
    @IBOutlet weak var BackButtonIcon: UIButton!
    
    @IBAction func BackButtonPressed(_ sender: Any) {
        Haptic.tap(intensity: 0.7)
        dismiss(animated: true)
    }
}
