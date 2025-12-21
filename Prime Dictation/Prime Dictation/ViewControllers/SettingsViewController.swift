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
    var googleDriveManager: GoogleDriveManager!
    var destinationManager: DestinationManager!
    var emailManager: EmailManager!
    
    @IBOutlet weak var DropboxLabel: RoundedButton!
    @IBOutlet weak var OneDriveLabel: RoundedButton!
    @IBOutlet weak var GoogleDriveLabel: RoundedButton!
    @IBOutlet weak var SelectFolderIcon: UIButton!
    @IBOutlet weak var StoreIcon: UIButton!
    @IBOutlet weak var EmailLabel: RoundedButton!
    @IBOutlet weak var DestinationDisplayLabel: UILabel!
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .darkContent
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        setNeedsStatusBarAppearanceUpdate()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()

        let services = AppServices.shared
        dropboxManager = services.dropboxManager
        oneDriveManager = services.oneDriveManager
        googleDriveManager = services.googleDriveManager
        destinationManager = services.destinationManager
        emailManager = services.emailManager

        dropboxManager.attach(settingsViewController: self)
        oneDriveManager.attach(settingsViewController: self)
        googleDriveManager.attach(settingsViewController: self)
        destinationManager.attach(settingsViewController: self)
        emailManager.attach(settingsViewController: self)
        
        UpdateSelectedDestinationUI(destination: DestinationManager.SELECTED_DESTINATION)
        
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]     // optional
            sheet.prefersGrabberVisible = true        // toggle to taste
        }
        
        setStoreButtonStyling()
    }
    
    private func setStoreButtonStyling() {
        let title = "Subscription"

        let normal = NSAttributedString(
            string: title,
            attributes: [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: PDColors.black,
                .font: UIFont.systemFont(ofSize: 14, weight: .semibold)
            ]
        )

        let highlighted = NSAttributedString(
            string: title,
            attributes: [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: PDColors.black.withAlphaComponent(0.6),
                .font: UIFont.systemFont(ofSize: 14, weight: .semibold)
            ]
        )

        StoreIcon.setAttributedTitle(normal, for: .normal)
        StoreIcon.setAttributedTitle(highlighted, for: .highlighted)
    }
    
    @IBAction func EmailButton(_ sender: Any) {
        Haptic.tap(intensity: 1.0)
        emailManager.handleEmailButtonTap(from: self)
        UpdateSelectedDestinationUserDefaults(destination: .email)
        UpdateSelectedDestinationUI(destination: .email)
    }
    
    func transitionToRootVC() {
        DispatchQueue.main.asyncAfter(deadline: .now() + ProgressHUDTransitionDelay) {
            self.dismiss(animated: true)
        }
    }
    
    private let ProgressHUDTransitionDelay = 2.0
    @IBAction func DropboxButton(_ sender: Any) {
        Haptic.tap(intensity: 1.0)
        dropboxManager.OpenAuthorizationFlow { result in
            switch result {
            case .success:
                self.UpdateSelectedDestinationUserDefaults(destination: .dropbox)
                self.UpdateSelectedDestinationUI(destination: .dropbox)
                DispatchQueue.main.asyncAfter(deadline: .now() + self.ProgressHUDTransitionDelay) {
                    self.dropboxManager.PresentDropboxFolderPicker { _ in self.transitionToRootVC() }
                }
            case .alreadyAuthenticated:
                self.UpdateSelectedDestinationUserDefaults(destination: .dropbox)
                self.UpdateSelectedDestinationUI(destination: .dropbox)
            case .cancel:
                ProgressHUD.failed("Dropbox sign-in was canceled.")
            case .error(_, _):
                ProgressHUD.failed("Dropbox sign-in failed. Please try again.")
            case .none:
                ProgressHUD.failed("Dropbox sign-in failed. Please try again.")
            }
        }
    }
    
    @IBAction func OneDriveButton(_ sender: Any) {
        Haptic.tap(intensity: 1.0)
        oneDriveManager.SignInIfNeeded { result in
            switch result {
            case .success:
                self.UpdateSelectedDestinationUserDefaults(destination: .onedrive)
                self.UpdateSelectedDestinationUI(destination: .onedrive)
                DispatchQueue.main.asyncAfter(deadline: .now() + self.ProgressHUDTransitionDelay) {
                    self.oneDriveManager.PresentOneDriveFolderPicker { _ in self.transitionToRootVC() }
                }
            case .alreadyAuthenticated:
                self.UpdateSelectedDestinationUserDefaults(destination: .onedrive)
                self.UpdateSelectedDestinationUI(destination: .onedrive)
            case .cancel:
                ProgressHUD.failed("OneDrive sign-in was canceled.")
            case .error:
                ProgressHUD.failed("OneDrive sign-in failed. Please try again.")
            }
        }
    }
    
    @IBAction func GoogleDriveButton(_ sender: Any) {
        Haptic.tap(intensity: 1.0)
        googleDriveManager.openAuthorizationFlow { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.UpdateSelectedDestinationUserDefaults(destination: .googledrive)
                self.UpdateSelectedDestinationUI(destination: .googledrive)
                DispatchQueue.main.asyncAfter(deadline: .now() + ProgressHUDTransitionDelay) {
                    self.googleDriveManager.presentGoogleDriveFolderPicker { _ in self.transitionToRootVC() }
                }
            case .alreadyAuthenticated:
                self.UpdateSelectedDestinationUserDefaults(destination: .googledrive)
                self.UpdateSelectedDestinationUI(destination: .googledrive)
            case .cancel:
                ProgressHUD.failed("Google Drive sign-in was canceled.")
            case .error(_, _):
                ProgressHUD.failed("Google Drive sign-in failed. Please try again.")
            case .none:
                ProgressHUD.failed("Google Drive sign-in failed. Please try again.")
            }
        }
    }
    
    @IBAction func SelectFolderButton(_ sender: Any) {
        Haptic.tap(intensity: 1.0)
        let currentDestination = DestinationManager.SELECTED_DESTINATION

        switch currentDestination {
        case .email:
            displayAlert(title: "Unavailable for Email", message: "Folder selection is unavailable for Email. Select Google Drive, OneDrive, or Dropbox to use this feature.")
        case .dropbox:
            ProgressHUD.animate("Opening folder picker…", .activityIndicator)
            dropboxManager.PresentDropboxFolderPicker { _ in self.transitionToRootVC() }
        case .onedrive:
            ProgressHUD.animate("Opening folder picker…", .activityIndicator)
            oneDriveManager.PresentOneDriveFolderPicker { _ in self.transitionToRootVC() }
        case .googledrive:
            ProgressHUD.animate("Opening folder picker…", .activityIndicator)
            googleDriveManager.presentGoogleDriveFolderPicker { _ in self.transitionToRootVC() }
        default:
            ProgressHUD.failed("Select a destination above before choosing a folder.")
        }
    }
    
    private func showPaywallScreen() {
        let vc = storyboard!.instantiateViewController(
            withIdentifier: "PaywallViewController"
        ) as! PaywallViewController

        vc.modalPresentationStyle = .overFullScreen
        present(vc, animated: true)
    }
    
    @IBAction func StoreButton(_ sender: Any) {
        Haptic.tap(intensity: 1.0)
        showPaywallScreen()
    }
    
    @IBAction func DismissPopover(_ sender: Any) {
        Haptic.tap(intensity: 1.0)
        dismiss(animated: true)
    }
    
    func UpdateSelectedDestinationUserDefaults(destination: Destination) {
        destinationManager.setSelectedDestination(destination)
    }
    
    func UpdateButton(button: RoundedButton, color: UIColor) {
        button.color = color
    }
    
    func UpdateSelectedDestinationUI(destination: Destination? = Destination.none) {
        let selectedColor: UIColor = PDColors.blue
        let graphite: UIColor = PDColors.black
        SelectFolderIcon.isEnabled = true
        SelectFolderIcon.alpha = 1.0
        DestinationDisplayLabel.isHidden = false

        UpdateButton(button: DropboxLabel, color: graphite)
        UpdateButton(button: OneDriveLabel, color: graphite)
        UpdateButton(button: GoogleDriveLabel, color: graphite)
        UpdateButton(button: EmailLabel, color: graphite)

        switch destination {
        case .dropbox:
            UpdateButton(button: DropboxLabel, color: selectedColor)
            DestinationDisplayLabel.text = "Choose Dropbox Folder"
        case .onedrive:
            UpdateButton(button: OneDriveLabel, color: selectedColor)
            DestinationDisplayLabel.text = "Choose OneDrive Folder"
        case .googledrive:
            UpdateButton(button: GoogleDriveLabel, color: selectedColor)
            DestinationDisplayLabel.text = "Choose G Drive Folder"
        case .email: // No need for the nested if check
            UpdateButton(button: EmailLabel, color: selectedColor)
            SelectFolderIcon.alpha = 0.4
            DestinationDisplayLabel.isHidden = true
        case .none?: // Handles the nil case directly
            SelectFolderIcon.isEnabled = false
            SelectFolderIcon.alpha = 0.4
        default:
            break
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
