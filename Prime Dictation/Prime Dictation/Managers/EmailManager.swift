import Foundation
import UIKit
import MessageUI
import ProgressHUD
import FirebaseAuth

// Mirroring the GDSelection for consistency, but with email-specific fields
struct EmailSelection: Codable {
    let emailAddress: String
    let accountId: String? // For potential future expansion

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

final class EmailManager: NSObject {

    static let shared = EmailManager()

    private let emailStorageKey = "EmailSelectionEmailAddress"
    private var emailAddress: String?

    weak var settingsViewController: SettingsViewController?
    weak var viewController: ViewController?
    private var recordingManager: RecordingManager?

    // Trim whitespace to avoid malformed URLs
    private var presignURLString: String? {
        (Bundle.main.object(forInfoDictionaryKey: "PRESIGNED_UPLOAD_AWS_LAMBDA_FUNCTION") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var emailURLString: String? {
        (Bundle.main.object(forInfoDictionaryKey: "EMAIL_SENDER_AWS_LAMBDA_FUNCTION") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

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

    // MARK: - UI Flow

    func handleEmailButtonTap(from presentingVC: SettingsViewController) {
        self.settingsViewController = presentingVC
        if let email = emailAddress, !email.isEmpty {
            showEmailInputModal(from: presentingVC, with: email)
        } else {
            showEmailInputModal(from: presentingVC, with: nil)
        }
    }

    private func showEmailInputModal(from presentingVC: UIViewController, with prefilledEmail: String?) {
        let alert = UIAlertController(title: "Enter Email Address", message: nil, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "Your email"
            tf.text = prefilledEmail
            tf.keyboardType = .emailAddress
            tf.autocapitalizationType = .none
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

    // MARK: - Main action

    @MainActor
    func SendToEmail(hasTranscription: Bool) async {
        ProgressHUD.animate("Sending...", .triangleDotShift)
        viewController?.DisableUI()

        do {
            guard let presignStr = presignURLString, let signerURL = URL(string: presignStr), signerURL.scheme == "https" else {
                print("❌ PRESIGNED_UPLOAD_AWS_LAMBDA_FUNCTION missing/invalid or not https")
                ProgressHUD.failed("Email service not configured (presign)")
                viewController?.EnableUI()
                return
            }
            guard let emailStr = emailURLString, let emailURL = URL(string: emailStr), emailURL.scheme == "https" else {
                print("❌ EMAIL_SENDER_AWS_LAMBDA_FUNCTION missing/invalid or not https")
                ProgressHUD.failed("Email service not configured (sender)")
                viewController?.EnableUI()
                return
            }

            guard let toEmail = emailAddress, !toEmail.isEmpty else {
                print("❌ Email not set")
                ProgressHUD.failed("You have not set your email address")
                viewController?.EnableUI()
                return
            }
            guard let recordingFileURL = recordingManager?.toggledRecordingURL else {
                print("❌ No recording to send")
                ProgressHUD.failed("No recording to send")
                viewController?.EnableUI()
                return
            }
            guard let recordingName = recordingManager?.toggledAudioTranscriptionObject.fileName else {
                print("❌ No recording name")
                ProgressHUD.failed("No recording to send")
                viewController?.EnableUI()
                return
            }

            let urlWithoutExtension = recordingFileURL.deletingPathExtension()

            var transcriptionFileURL: URL? = nil
            if hasTranscription {
                transcriptionFileURL = urlWithoutExtension.appendingPathExtension(recordingManager?.transcriptionRecordingExtension ?? "txt")
            }

            // Heavy I/O off main actor
            let recData: Data = try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { cont.resume(returning: try Data(contentsOf: recordingFileURL, options: .mappedIfSafe)) }
                    catch { cont.resume(throwing: error) }
                }
            }

            let recKey = "recordings/\(recordingName).\(recordingManager?.audioRecordingExtension ?? "m4a")"

            let bearer = try await AppServices.shared.getFreshIDToken()

            // 1) Presign + upload recording
            let recPresign = try await mintPresignedPUT(
                functionURL: signerURL,
                key: recKey,
                contentType: "audio/mp4",
                contentLength: recData.count,
                bearer: bearer
            )
            try await uploadToS3(presigned: recPresign, fileData: recData)

            // 2) Presign + upload transcription (optional)
            var transcriptionKey: String? = nil
            if let tURL = transcriptionFileURL {
                let txData: Data = try await withCheckedThrowingContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do { cont.resume(returning: try Data(contentsOf: tURL, options: .mappedIfSafe)) }
                        catch { cont.resume(throwing: error) }
                    }
                }
                let tKey = "transcriptions/\(recordingName).\(recordingManager?.transcriptionRecordingExtension ?? "txt")"

                let txPresign = try await mintPresignedPUT(
                    functionURL: signerURL,
                    key: tKey,
                    contentType: "text/plain",
                    contentLength: txData.count,
                    bearer: bearer
                )
                transcriptionKey = tKey
                try await uploadToS3(presigned: txPresign, fileData: txData)
            }
            
            // 3) Send Email to user's email address
            do {
                _ = try await sendEmail(endpoint: emailURL, toEmail: toEmail, recordingKey: recKey, transcriptionKey: transcriptionKey, bearer: bearer)
                if hasTranscription {
                    ProgressHUD.succeed("Recording & transcript sent to Email")
                } else {
                    ProgressHUD.succeed("Recording sent to Email")
                }
                AudioFeedback.shared.playWhoosh(intensity: 0.6)
                print("✅ email lambda returned 2xx")
            } catch {
                print("❌ email lambda failed")
            }
            viewController?.EnableUI()
        } catch {
            ProgressHUD.dismiss()
            print("❌ SendToEmail error")
            viewController?.displayAlert(title: "Email not sent", message: "Failed to send email, try again later")
            viewController?.EnableUI()
        }
    }

    // MARK: - Network calls
    func sendEmail(
        endpoint: URL,
        toEmail: String,
        recordingKey: String?,
        transcriptionKey: String?,
        bearer: String
    ) async throws -> EmailResponse {
        let body: [String: Any] = [
            "toEmail": toEmail,
            "recordingKey": recordingKey as Any,
            "transcriptionKey": transcriptionKey as Any
        ].compactMapValues { $0 }

        var (data, http) = try await authorizedJSONPost(url: endpoint, body: body, token: bearer)

        if http.statusCode == 401 {
            print("⚠️ email 401, refreshing token and retrying")
            let fresh = try await AppServices.shared.getFreshIDToken()
            (data, http) = try await authorizedJSONPost(url: endpoint, body: body, token: fresh)
        }

        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            throw NSError(domain: "pd-email-sender", code: http.statusCode,
                          userInfo: ["body": bodyText])
        }
        return try JSONDecoder().decode(EmailResponse.self, from: data)
    }

    func mintPresignedPUT(
        functionURL: URL,
        key: String,
        contentType: String,
        contentLength: Int,
        bearer: String
    ) async throws -> PresignResponse {
        let body: [String: Any] = [
            "key": key,
            "contentType": contentType,
            "contentLength": contentLength
        ]

        var (data, http) = try await authorizedJSONPost(url: functionURL, body: body, token: bearer)

        if http.statusCode == 401 {
            print("⚠️ presign 401, refreshing token and retrying")
            let fresh = try await AppServices.shared.getFreshIDToken()
            (data, http) = try await authorizedJSONPost(url: functionURL, body: body, token: fresh)
        }

        guard http.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            print("❌ presign non-200")
            throw NSError(domain: "presign", code: http.statusCode,
                          userInfo: ["body": bodyText])
        }
        return try JSONDecoder().decode(PresignResponse.self, from: data)
    }

    func uploadToS3(presigned: PresignResponse, fileData: Data) async throws {
        guard let putURL = URL(string: presigned.url) else { throw URLError(.badURL) }
        var putReq = URLRequest(url: putURL)
        putReq.httpMethod = "PUT"
        putReq.timeoutInterval = 120
        for (k, v) in presigned.headers {
            putReq.setValue(v, forHTTPHeaderField: k)
        }
        let (_, resp) = try await URLSession.shared.upload(for: putReq, from: fileData)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            print("❌ s3 put failed")
            throw NSError(domain: "s3put", code: (resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    // MARK: - Helpers

    private func authorizedJSONPost(url: URL, body: [String: Any], token: String) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, resp as! HTTPURLResponse)
    }
}
