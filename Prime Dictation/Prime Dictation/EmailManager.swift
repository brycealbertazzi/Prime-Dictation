import Foundation
import UIKit
import MessageUI
import ProgressHUD

// Mirroring the GDSelection for consistency, but with email-specific fields
struct EmailSelection: Codable {
    let emailAddress: String
    let accountId: String? // For potential future expansion, e.g., if supporting multiple email accounts

    static var none: EmailSelection {
        EmailSelection(emailAddress: "", accountId: nil)
    }
}

class EmailManager: NSObject {
    
    // Shared instance for easy access throughout the app
    static let shared = EmailManager()
    
    // Key for storing the email address in UserDefaults
    private let emailStorageKey = "EmailSelectionEmailAddress"
    private var emailAddress: String?
    
    // Delegate to be used for MFMailComposeViewController
    weak var settingsViewController: SettingsViewController? // Your Settings View Controller
    weak var viewController: ViewController?
    private var recordingManager: RecordingManager?
    
    override init() {
        super.init()
        self.emailAddress = UserDefaults.standard.string(forKey: emailStorageKey)
    }
    
    func attach(settingsViewController: SettingsViewController) {
        self.settingsViewController = settingsViewController
    }

    func attach(viewController: ViewController, recordingManager: RecordingManager) {
        self.viewController = viewController
        self.recordingManager = recordingManager
    }
    
    func handleEmailButtonTap(from presentingVC: SettingsViewController) {
        self.settingsViewController = presentingVC
        
        if let email = emailAddress, !email.isEmpty {
            // If email is stored, show modal for re-entry
            showEmailInputModal(from: presentingVC, with: email)
        } else {
            // If no email is stored, show modal for first-time entry
            showEmailInputModal(from: presentingVC, with: nil)
        }
    }
    
    private func showEmailInputModal(from presentingVC: UIViewController, with prefilledEmail: String?) {
        let alert = UIAlertController(title: "Enter Email Address", message: nil, preferredStyle: .alert)
        
        alert.addTextField { textField in
            textField.placeholder = "Your email"
            textField.text = prefilledEmail
            textField.keyboardType = .emailAddress
            textField.autocapitalizationType = .none
        }
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        alert.addAction(UIAlertAction(title: "Save", style: .default) { _ in
            if let email = alert.textFields?.first?.text, !email.isEmpty {
                self.saveEmailAddress(email)
            } else {
                ProgressHUD.failed("Email cannot be empty.")
            }
        })
        
        presentingVC.present(alert, animated: true)
    }
    
    private func saveEmailAddress(_ email: String) {
        UserDefaults.standard.set(email, forKey: emailStorageKey)
        self.emailAddress = email
        ProgressHUD.succeed("Email saved")
    }
    
    func SendToEmail(fileData: Data, fileName: String) {
        guard let email = emailAddress, !email.isEmpty else {
            ProgressHUD.failed("Please enter your email address first.")
            if let vc = settingsViewController {
                showEmailInputModal(from: vc, with: nil)
            }
            return
        }
        
        if MFMailComposeViewController.canSendMail() {
            print("email \(email)")
            let mailComposer = MFMailComposeViewController()
            mailComposer.mailComposeDelegate = self
            mailComposer.setToRecipients([email])
            mailComposer.setSubject("Your Recording from Prime Dictation")
            mailComposer.setMessageBody("Hello,\n\nHere is your requested recording.", isHTML: false)
            mailComposer.addAttachmentData(fileData, mimeType: "audio/m4a", fileName: fileName)
            
            // Present the mail composer from the appropriate view controller
            if let vc = settingsViewController {
                vc.present(mailComposer, animated: true)
            } else {
                // Fallback if settingsViewController is nil
                UIApplication.shared.findKeyWindow()?.rootViewController?.present(mailComposer, animated: true)
            }
            
        } else {
            ProgressHUD.failed("Email not configured on this device.")
        }
    }
}

// MARK: - MFMailComposeViewControllerDelegate
extension EmailManager: MFMailComposeViewControllerDelegate {
    func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
        controller.dismiss(animated: true)
        
        switch result {
        case .sent:
            ProgressHUD.succeed("Email sent!")
        case .cancelled:
            ProgressHUD.succeed("Email cancelled.")
        case .saved:
            ProgressHUD.succeed("Email saved as a draft.")
        case .failed:
            ProgressHUD.failed("Failed to send email.")
        @unknown default:
            break
        }
    }
}
