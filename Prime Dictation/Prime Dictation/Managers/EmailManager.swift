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
struct EmailResponse: Decodable { let messageId: String? }

struct PresignResponse: Decodable {
    let url: String
    let method: String
    let headers: [String:String]
    let key: String
    let bucket: String
    let region: String
    let expiresIn: Int
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
    
    let PresignedUploadAWSLambdaFunctionURL = Bundle.main.object(forInfoDictionaryKey: "PRESIGNED_UPLOAD_AWS_LAMBDA_FUNCTION") as? String
    let EmailSenderAWSLambdaFunctionURL = Bundle.main.object(forInfoDictionaryKey: "EMAIL_SENDER_AWS_LAMBDA_FUNCTION") as? String
    
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
    
    @MainActor
    func SendToEmail(
        hasTranscription: Bool,
    ) async {
        ProgressHUD.animate("Sending...", .triangleDotShift)
        viewController?.DisableUI()
        do {
            guard let signer =  PresignedUploadAWSLambdaFunctionURL else {
                print("PresignedUploadAWSLambdaFunctionURL not set")
                ProgressHUD.failed("Failed to send email, try again later")
                viewController?.EnableUI()
                return
            }
            guard let EmailSenderAWSLambdaFunctionURL else {
                print("EmailSenderAWSLambdaFunctionURL not set")
                ProgressHUD.failed("Failed to send email, try again later")
                viewController?.EnableUI()
                return
            }
            let signerURL = URL(string: signer)!
            let emailURL = URL(string: EmailSenderAWSLambdaFunctionURL)!
            
            guard let toEmail = emailAddress else {
                print("Email not set")
                ProgressHUD.failed("You have not set your email address")
                viewController?.EnableUI()
                return
            }
            
            guard let recordingFileURL = recordingManager?.toggledRecordingURL else {
                print("No recording to send")
                ProgressHUD.failed("No recording to send")
                viewController?.EnableUI()
                return
            }
            
            guard let recordingName = recordingManager?.toggledAudioTranscriptionObject.fileName else {
                print("No recording to send")
                ProgressHUD.failed("No recording to send")
                viewController?.EnableUI()
                return
            }
            
            let urlWithoutExtension = recordingFileURL.deletingPathExtension()
            
            var transcriptionFileURL: URL? = nil
            if (hasTranscription) {
                transcriptionFileURL = urlWithoutExtension.appendingPathExtension(recordingManager?.transcriptionRecordingExtension ?? "txt")
            }
            
            // Prepare keys & data
            let recData = try Data(contentsOf: recordingFileURL, options: .mappedIfSafe)
            let recKey = "recordings/\(recordingName).\(recordingManager?.audioRecordingExtension ?? "m4a")"

            // 1) Presign + upload recording
            let recPresign = try await mintPresignedPUT(
                functionURL: signerURL,
                key: recKey,
                contentType: "audio/mp4",
                contentLength: recData.count
            )
            try await uploadToS3(presigned: recPresign, fileData: recData)

            // 2) Presign + upload transcription (optional)
            var txKey: String? = nil
            if let tURL = transcriptionFileURL {
                let txData = try Data(contentsOf: tURL, options: .mappedIfSafe)
                let tKey = "transcriptions/\(recordingName).\(recordingManager?.transcriptionRecordingExtension ?? "txt")"
                let txPresign = try await mintPresignedPUT(
                    functionURL: signerURL,
                    key: tKey,
                    contentType: "text/plain",
                    contentLength: txData.count
                )
                try await uploadToS3(presigned: txPresign, fileData: txData)
                txKey = tKey
            }
            // 3) Email (Lambda will attach if small else include links)
            _ = try await sendEmail(
                endpoint: emailURL,
                toEmail: toEmail,
                recordingKey: recKey,
                transcriptionKey: txKey
            )

            if (hasTranscription) {
                ProgressHUD.succeed("Recording & transcript sent to Email")
            } else {
                ProgressHUD.succeed("Recording sent to Email")
            }
            viewController?.EnableUI()
        } catch {
            viewController?.displayAlert(title: "Email not sent", message: "Failed to send email, try again later")
            viewController?.EnableUI()
        }
    }
    
    func sendEmail(
        endpoint: URL,
        toEmail: String,
        recordingKey: String?,
        transcriptionKey: String?,
        secretHeader: (name: String, value: String)? = nil
    ) async throws -> EmailResponse {
        var body: [String: Any] = [
            "toEmail": toEmail,
        ]
        if let r = recordingKey { body["recordingKey"] = r }
        if let t = transcriptionKey { body["transcriptionKey"] = t }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let s = secretHeader { req.setValue(s.value, forHTTPHeaderField: s.name) } // optional
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "pd-email-sender", code: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: ["body": String(data: data, encoding: .utf8) ?? ""])
        }
        return try JSONDecoder().decode(EmailResponse.self, from: data)
    }
    
    func mintPresignedPUT(
        functionURL: URL,
        key: String,
        contentType: String,
        contentLength: Int,
        secretHeader: (name: String, value: String)? = nil
    ) async throws -> PresignResponse {
        var req = URLRequest(url: functionURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let s = secretHeader { req.setValue(s.value, forHTTPHeaderField: s.name) } // optional
        let body: [String: Any] = [
            "key": key,
            "contentType": contentType,
            "contentLength": contentLength
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "presign", code: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: ["body": String(data: data, encoding: .utf8) ?? ""])
        }
        return try JSONDecoder().decode(PresignResponse.self, from: data)
    }
    
    func uploadToS3(presigned: PresignResponse, fileData: Data) async throws {
        guard let putURL = URL(string: presigned.url) else { throw URLError(.badURL) }
        var putReq = URLRequest(url: putURL)
        putReq.httpMethod = "PUT"
        // Must match exactly the headers returned by your signer
        for (k, v) in presigned.headers {
            putReq.setValue(v, forHTTPHeaderField: k)
        }
        let (_, resp) = try await URLSession.shared.upload(for: putReq, from: fileData)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "s3put", code: (resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }
    
}
