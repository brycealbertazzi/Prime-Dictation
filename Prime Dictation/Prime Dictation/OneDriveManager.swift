import UIKit
import ProgressHUD
import MSAL
import Foundation
import UniformTypeIdentifiers

final class OneDriveManager {
    // MARK: - Config
    private let scopes = ["User.Read", "Files.ReadWrite"]

    private lazy var redirectUri: String = {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.example.app"
        return "msauth.\(bundleID)://auth"
    }()

    // Use "common" if you support both personal + work/school accounts
    private lazy var authorityURLString: String = "https://login.microsoftonline.com/common"

    private let viewController: ViewController
    private let recordingManager: RecordingManager

    private var msalApp: MSALPublicClientApplication?
    private var signedInAccount: MSALAccount?

    // MARK: - Init
    init(viewController: ViewController, recordingMananger: RecordingManager) {
        self.viewController = viewController
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
            // If using the Microsoft shared keychain group, ensure entitlements include:
            // $(AppIdentifierPrefix)com.microsoft.adalcache
            // config.cacheConfig.keychainSharingGroup = "com.microsoft.adalcache"

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

        // Optional: show while opening the web view
        DispatchQueue.main.async { ProgressHUD.animate("Opening Microsoft sign-in…") }
        viewController.ShowSendingUI()

        let web = MSALWebviewParameters(authPresentationViewController: viewController)
        let params = MSALInteractiveTokenParameters(scopes: scopes, webviewParameters: web)

        app.acquireToken(with: params) { result, error in
            if let result = result {
                self.signedInAccount = result.account
                print("✅ token acquired, scopes:", result.scopes)
                print("accessToken prefix:", result.accessToken.prefix(16), "…")
                DispatchQueue.main.async { ProgressHUD.succeed("Logged into OneDrive") }
                self.viewController.HideSendingUI()
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
            DispatchQueue.main.async { ProgressHUD.failed("Unable to log into OneDrive") }
            self.viewController.HideSendingUI()
        }
    }

    // MARK: - Public: upload entry point
    func SendToOneDrive(url: URL, preferredFileName: String? = nil, progress: ((Double) -> Void)? = nil) {
        Task { [weak self] in
            guard let self = self else { return }
            await ProgressHUD.animate("Sending...")
            await viewController.ShowSendingUI()

            // Always runs when this Task scope exits (success or error)
            defer {
                // Don’t `await` in defer; schedule a MainActor task instead
                Task { @MainActor in
                    self.viewController.HideSendingUI()
                }
            }

            do {
                let token = try await self.getAccessTokenSilently()
                let fileName = preferredFileName ?? url.lastPathComponent
                let item = try await self.uploadRecording(accessToken: token,
                                                          fileURL: url,
                                                          fileName: fileName,
                                                          progress: progress)
                await MainActor.run {
                    print("✅ Uploaded \(item.name) → \(item.webUrl ?? "(no webUrl)")")
                    ProgressHUD.succeed("Recording was sent to OneDrive")
                }
            } catch {
                await MainActor.run {
                    ProgressHUD.failed("Failed to send recording. Check connection or sign in again.")
                }
            }
        }
    }

    // MARK: - Token (silent)
    private func getAccessTokenSilently() async throws -> String {
        guard let app = msalApp else { throw ODRError.notConfigured }

        let account: MSALAccount
        if let acc = signedInAccount {
            account = acc
        } else {
            let accounts = try app.allAccounts()
            guard let first = accounts.first else { throw ODRError.notSignedIn }
            account = first
        }

        return try await withCheckedThrowingContinuation { cont in
            let silent = MSALSilentTokenParameters(scopes: scopes, account: account)
            app.acquireTokenSilent(with: silent) { result, error in
                if let result = result {
                    cont.resume(returning: result.accessToken)
                } else {
                    cont.resume(throwing: error ?? ODRError.tokenFailure)
                }
            }
        }
    }

    // MARK: - OneDrive upload (Graph)

    private func uploadRecording(accessToken: String, fileURL: URL, fileName: String,
                                 progress: ((Double) -> Void)?) async throws -> DriveItem {
        // Ensure folder exists
        _ = try await ensurePrimeDictationFolder(token: accessToken)

        // Choose strategy by size
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        let size = Int64(values.fileSize ?? 0)
        if size <= 4 * 1024 * 1024 {
            return try await uploadSmallFile(token: accessToken, fileURL: fileURL, as: fileName)
        } else {
            return try await uploadLargeFile(token: accessToken, fileURL: fileURL, as: fileName, progress: progress)
        }
    }

    // Create or fetch /Prime Dictation folder
    private func ensurePrimeDictationFolder(token: String) async throws -> DriveItem {
        struct CreateFolderBody: Encodable {
            let name: String
            let folder: [String:String] = [:]
            let conflictBehavior: String
        }
        let createURL = URL(string: "https://graph.microsoft.com/v1.0/me/drive/root/children")!
        var req = authorizedRequest(url: createURL,
                                    token: token,
                                    method: "POST",
                                    headers: ["Content-Type":"application/json"],
                                    body: try JSONEncoder().encode(CreateFolderBody(name: "Prime Dictation",
                                                                                    conflictBehavior: "replace")))
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
            return try decode(DriveItem.self, from: data)
        }

        // If it already exists, GET it
        let folderPath = percentPathComponent("Prime Dictation")
        let getURL = URL(string: "https://graph.microsoft.com/v1.0/me/drive/root:/\(folderPath)")!
        let (gData, gResp) = try await URLSession.shared.data(for: authorizedRequest(url: getURL, token: token))
        guard let gHttp = gResp as? HTTPURLResponse, (200...299).contains(gHttp.statusCode) else {
            throw ODRError.badResponse(status: (gResp as? HTTPURLResponse)?.statusCode ?? -1,
                                       body: String(data: gData, encoding: .utf8) ?? "")
        }
        return try decode(DriveItem.self, from: gData)
    }

    // Simple upload (≤ 4 MB)
    private func uploadSmallFile(token: String, fileURL: URL, as fileName: String) async throws -> DriveItem {
        let folder = percentPathComponent("Prime Dictation")
        let name = percentPathComponent(fileName)
        let url = URL(string: "https://graph.microsoft.com/v1.0/me/drive/root:/\(folder)/\(name):/content")!
        let data = try Data(contentsOf: fileURL)
        var req = authorizedRequest(url: url,
                                    token: token,
                                    method: "PUT",
                                    headers: ["Content-Type": mimeType(for: fileURL)],
                                    body: data)
        let (respData, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ODRError.badResponse(status: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                                       body: String(data: respData, encoding: .utf8) ?? "")
        }
        return try decode(DriveItem.self, from: respData)
    }

    // Resumable upload (> 4 MB)
    private func uploadLargeFile(token: String, fileURL: URL, as fileName: String,
                                 progress: ((Double) -> Void)? = nil,
                                 chunkSize: Int = 5 * 1024 * 1024) async throws -> DriveItem {
        let folder = percentPathComponent("Prime Dictation")
        let name = percentPathComponent(fileName)
        let sessionURL = URL(string: "https://graph.microsoft.com/v1.0/me/drive/root:/\(folder)/\(name):/createUploadSession")!

        // Use JSONSerialization to set the @-key
        let sessionBody: [String: Any] = [
            "item": [
                "name": fileName,
                "@microsoft.graph.conflictBehavior": "replace"
            ]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: sessionBody, options: [])

        let createReq = authorizedRequest(url: sessionURL,
                                          token: token,
                                          method: "POST",
                                          headers: ["Content-Type":"application/json"],
                                          body: bodyData)
        let (csData, csResp) = try await URLSession.shared.data(for: createReq)
        guard let csHttp = csResp as? HTTPURLResponse, (200...299).contains(csHttp.statusCode),
              let obj = try JSONSerialization.jsonObject(with: csData) as? [String: Any],
              let uploadUrlStr = obj["uploadUrl"] as? String,
              let uploadURL = URL(string: uploadUrlStr) else {
            throw ODRError.missingUploadUrl
        }

        // PUT chunks
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let total = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var sent: Int64 = 0
        while sent < total {
            let thisChunk = min(Int64(chunkSize), total - sent)
            try handle.seek(toOffset: UInt64(sent))
            let data = try handle.read(upToCount: Int(thisChunk)) ?? Data()

            var req = URLRequest(url: uploadURL)
            req.httpMethod = "PUT"
            req.httpBody = data
            req.setValue("bytes \(sent)-\(sent + Int64(data.count) - 1)/\(total)", forHTTPHeaderField: "Content-Range")
            req.setValue(String(data.count), forHTTPHeaderField: "Content-Length")

            let (uData, uResp) = try await URLSession.shared.data(for: req)
            guard let http = uResp as? HTTPURLResponse else {
                throw ODRError.badResponse(status: -1, body: "")
            }

            if http.statusCode == 202 {
                sent += Int64(data.count)
                progress?(Double(sent) / Double(total))
                continue
            }

            if (200...299).contains(http.statusCode) {
                return try decode(DriveItem.self, from: uData)
            }

            throw ODRError.badResponse(status: http.statusCode,
                                       body: String(data: uData, encoding: .utf8) ?? "")
        }

        throw ODRError.badResponse(status: -1, body: "Unexpected end of upload")
    }

    // MARK: - Helpers

    private func authorizedRequest(url: URL,
                                   token: String,
                                   method: String = "GET",
                                   headers: [String:String] = [:],
                                   body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        for (k,v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        return req
    }

    private func percentPathComponent(_ s: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private func mimeType(for fileURL: URL) -> String {
        if let ut = UTType(filenameExtension: fileURL.pathExtension),
           let mt = ut.preferredMIMEType {
            return mt
        }
        return "application/octet-stream"
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(T.self, from: data)
    }

    // MARK: - Models & Errors
    struct DriveItem: Decodable {
        let id: String
        let name: String
        let size: Int64?
        let webUrl: String?
    }

    enum ODRError: Error {
        case notConfigured
        case notSignedIn
        case tokenFailure
        case badResponse(status: Int, body: String)
        case missingUploadUrl
    }

    // MARK: - Helpers (your existing loaders)
    private func loadMSClientApplicationId() -> String {
        guard var key = Bundle.main.object(forInfoDictionaryKey: "MS_CLIENT_APPLICATION_ID") as? String else {
            fatalError("Missing MS_CLIENT_APPLICATION_ID in Info.plist")
        }
        key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasPrefix("$(") { fatalError("MS_CLIENT_APPLICATION_ID not resolved") }
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
