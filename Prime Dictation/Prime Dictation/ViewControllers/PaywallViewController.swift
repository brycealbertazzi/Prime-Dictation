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
    @IBOutlet weak var ScrollView: UIScrollView!
    @IBOutlet weak var StackView: UIStackView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .light
        
        // Just to be explicit
        StackView.translatesAutoresizingMaskIntoConstraints = false

        // Make the content width match the scroll view’s visible width
        NSLayoutConstraint.activate([
            ScrollView.contentLayoutGuide.widthAnchor.constraint(
                equalTo: ScrollView.frameLayoutGuide.widthAnchor
            )
        ])
    }
    
    @IBAction func BackButtonPressed(_ sender: Any) {
        Haptic.tap(intensity: 0.7)
        dismiss(animated: true)
    }
}
