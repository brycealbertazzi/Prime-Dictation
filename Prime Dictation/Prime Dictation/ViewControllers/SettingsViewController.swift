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
    @IBOutlet weak var SelectFolderIcon: RoundedButton!
    @IBOutlet weak var EmailLabel: RoundedButton!
    
    @IBOutlet weak var arrowTopConstraint: NSLayoutConstraint!
    @IBOutlet weak var titleTopConstraint: NSLayoutConstraint!
    
    private let desiredArrowTop: CGFloat = 20
    private let desiredTitleTop: CGFloat = 85
    
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
    }
    
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        adjustHeaderTop()
    }

    private var didAdjustOnce = false
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        print("viewDidLayoutSubviews: didAdjustOnce: \(didAdjustOnce)")
        if !didAdjustOnce { adjustHeaderTop() }
    }

    private func adjustHeaderTop() {
        didAdjustOnce = true
        print("Adjusting header top")
        // We only compensate when it's an adapted sheet (not a popover),
        // and only if there's NO navigation bar (safe area already accounts for it).
        let isSheet = (sheetPresentationController != nil) && (popoverPresentationController == nil)
        let hasNavBar = (navigationController != nil) && !(navigationController?.navigationBar.isHidden ?? false)

        let extraInset = (isSheet && !hasNavBar) ? view.safeAreaInsets.top : 0

        titleTopConstraint.constant = desiredTitleTop - extraInset
        arrowTopConstraint.constant = desiredArrowTop - extraInset
        // Clamp so we never go negative offscreen
        titleTopConstraint.constant = max(titleTopConstraint.constant, 0)
        arrowTopConstraint.constant = max(arrowTopConstraint.constant, 0)
        view.layoutIfNeeded()
    }
    
    @IBAction func EmailButton(_ sender: Any) {
        Haptic.tap(intensity: 1.0)
        emailManager.handleEmailButtonTap(from: self)
        UpdateSelectedDestinationUserDefaults(destination: .email)
        UpdateSelectedDestinationUI(destination: .email)
    }
    
    @IBAction func DropboxButton(_ sender: Any) {
        Haptic.tap(intensity: 1.0)
        dropboxManager.OpenAuthorizationFlow { result in
            switch result {
            case .success:
                self.UpdateSelectedDestinationUserDefaults(destination: .dropbox)
                self.UpdateSelectedDestinationUI(destination: .dropbox)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.dropboxManager.PresentDropboxFolderPicker { selection in }
                }
            case .alreadyAuthenticated:
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
        Haptic.tap(intensity: 1.0)
        oneDriveManager.SignInIfNeeded { result in
            switch result {
            case .success:
                self.UpdateSelectedDestinationUserDefaults(destination: .onedrive)
                self.UpdateSelectedDestinationUI(destination: .onedrive)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.oneDriveManager.PresentOneDriveFolderPicker { selection in }
                }
            case .alreadyAuthenticated:
                self.UpdateSelectedDestinationUserDefaults(destination: .onedrive)
                self.UpdateSelectedDestinationUI(destination: .onedrive)
            case .cancel:
                ProgressHUD.failed("Canceled OneDrive Login")
            case .error:
                ProgressHUD.failed("Unable to log into OneDrive")
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.googleDriveManager.presentGoogleDriveFolderPicker { selection in }
                }
            case .alreadyAuthenticated:
                self.UpdateSelectedDestinationUserDefaults(destination: .googledrive)
                self.UpdateSelectedDestinationUI(destination: .googledrive)
            case .cancel:
                ProgressHUD.failed("Canceled Google Drive Login")
            case .error(_, _):
                ProgressHUD.failed("Unable to log into Google Drive")
            case .none:
                ProgressHUD.failed("Unable to log into Google Drive")
            }
        }
    }
    
    @IBAction func SelectFolderButton(_ sender: Any) {
        Haptic.tap(intensity: 1.0)
        let currentDestination = DestinationManager.SELECTED_DESTINATION
        
        switch currentDestination {
        case .dropbox:
            ProgressHUD.animate("Opening file picker", .activityIndicator)
            dropboxManager.PresentDropboxFolderPicker { selection in }
            break
        case .onedrive:
            ProgressHUD.animate("Opening file picker", .activityIndicator)
            oneDriveManager.PresentOneDriveFolderPicker { selection in }
            break
        case .googledrive:
            ProgressHUD.animate("Opening file picker", .activityIndicator)
            googleDriveManager.presentGoogleDriveFolderPicker { selection in }
            break
        default:
            ProgressHUD.failed("No destination selected")
            break
        }
    }
    
    @IBAction func DismissPopover(_ sender: Any) {
        Haptic.tap(intensity: 1.0)
        dismiss(animated: true)
    }
    
    func UpdateSelectedDestinationUserDefaults(destination: Destination) {
        destinationManager.setSelectedDestination(destination)
    }
    
    func UpdateSelectedDestinationUI(destination: Destination? = Destination.none) {
        let selectedColor: UIColor = PDColors.blue
        let graphite: UIColor = PDColors.black
        SelectFolderIcon.isEnabled = true
        SelectFolderIcon.alpha = 1.0

        DropboxLabel.borderColor = graphite
        OneDriveLabel.borderColor = graphite
        GoogleDriveLabel.borderColor = graphite
        EmailLabel.borderColor = graphite

        switch destination {
        case .dropbox:
            DropboxLabel.borderColor = selectedColor
        case .onedrive:
            OneDriveLabel.borderColor = selectedColor
        case .googledrive:
            GoogleDriveLabel.borderColor = selectedColor
        case .email: // No need for the nested if check
            EmailLabel.borderColor = selectedColor
            SelectFolderIcon.isEnabled = false
            SelectFolderIcon.alpha = 0.4
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
