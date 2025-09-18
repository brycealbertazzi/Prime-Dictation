import UIKit
import MSAL

final class OneDriveManager {
    // MARK: - Config
    private let scopes = ["User.Read", "Files.ReadWrite"]

    private lazy var redirectUri: String = {
        // Must equal your Entra app's redirect & your Info.plist URL scheme
        let bundleID = Bundle.main.bundleIdentifier ?? "com.example.app"
        return "msauth.\(bundleID)://auth"
    }()

    // If you chose single-tenant, use your tenant ID; otherwise use "common" or "organizations"
    private lazy var authorityURLString: String = "https://login.microsoftonline.com/common"

    private let presentingVC: UIViewController
    private let recordingManager: RecordingManager

    private var msalApp: MSALPublicClientApplication?

    // MARK: - Init
    init(viewController: UIViewController, recordingMananger: RecordingManager) {
        self.presentingVC = viewController
        self.recordingManager = recordingMananger
        configureMSAL()
    }

    // MARK: - Setup
    private func configureMSAL() {
        print("Configuring MSAL…")
        let clientId = loadMSClientApplicationId()

        do {
            guard let authorityURL = URL(string: authorityURLString) else {
                preconditionFailure("Bad authority URL: \(authorityURLString)")
            }
            
            let authority = try MSALAADAuthority(url: authorityURL)
            let config = MSALPublicClientApplicationConfig(
                clientId: clientId,
                redirectUri: redirectUri,
                authority: authority
            )
            
            print("Config", config)
            self.msalApp = try MSALPublicClientApplication(configuration: config)
            print("MSAL configured ✅")

        } catch {
            let ns = error as NSError
            print("MSAL init failed ❌")
            print("  domain:", ns.domain)
            print("  code:", ns.code)
            print("  userInfo:", ns.userInfo)
        }
    }

    // MARK: - Sign-in
    func SignInInteractively() {
        guard let app = msalApp else {
            print("MSAL app not configured")
            return
        }

        let web = MSALWebviewParameters(authPresentationViewController: presentingVC)
        let params = MSALInteractiveTokenParameters(scopes: scopes, webviewParameters: web)

        app.acquireToken(with: params) { result, error in
            if let result = result {
                print("✅ token acquired, scopes:", result.scopes)
                print("accessToken prefix:", result.accessToken.prefix(16), "…")
                return
            }

            let ns = error as NSError?
            print("❌ MSAL acquireToken")
            print("  domain:", ns?.domain ?? "nil")
            print("  code:", ns?.code ?? -1)
            print("  userInfo:", ns?.userInfo ?? [:])
            if let sub = ns?.userInfo[MSALHTTPResponseCodeKey] {
                print("  http:", sub)
            }
            if let err = ns?.userInfo[MSALOAuthErrorKey] {
                print("  aad:", err)
            }
        }

    }

    // Example upload (call after you have a token)
    func SendToOneDrive() {
//        guard let url = URL(string: "https://graph.microsoft.com/v1.0/me/drive/root:/\(fileName):/content") else {
//            completion(false); return
//        }
//        var req = URLRequest(url: url)
//        req.httpMethod = "PUT"
//        req.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
//        req.httpBody = data
//        URLSession.shared.dataTask(with: req) { _, resp, err in
//            if let err = err { print("Upload error:", err); completion(false); return }
//            completion(true)
//        }.resume()
    }

    // MARK: - Helpers (your existing loaders)
    private func loadMSClientApplicationId() -> String {
        guard var key = Bundle.main.object(forInfoDictionaryKey: "MS_CLIENT_APPLICATION_ID") as? String else {
            fatalError("Missing MS_CLIENT_APPLICATION_ID in Info.plist")
        }
        key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        print("key trimmed MS_CLIENT_APPLICATION_ID: \(key)")
        if key.hasPrefix("$(") { fatalError("MS_CLIENT_APPLICATION_ID not resolved") }
        print("MS_CLIENT_APPLICATION_ID: \(key)")
        return key
    }

    private func loadMSTenantDirectoryId() -> String {
        guard var key = Bundle.main.object(forInfoDictionaryKey: "MS_TENANT_DIRECTORY_ID") as? String else {
            fatalError("Missing MS_TENANT_DIRECTORY_ID in Info.plist")
        }
        key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasPrefix("$(") { fatalError("MS_TENANT_DIRECTORY_ID not resolved") }
        return key
    }
}
