//
//  OneDriveManager.swift
//  Prime Dictation
//
//  OneDrive folder picker with:
//  - “Done” button (select current folder if no child chosen)
//  - Tap to toggle selection on a row (tap again to deselect)
//  - Do not navigate deeper if the tapped item is a leaf (no subfolders)
//  - Minimal chevron flicker via a leaf-cache + async probe
//

import UIKit
import ProgressHUD
import MSAL
import Foundation
import UniformTypeIdentifiers

// MARK: - Auth result
enum AuthResult {
    case success
    case alreadyAuthenticated
    case cancel
    case error(Error?)
}

final class OneDriveManager {
    // MARK: - Config
    private let scopes = ["User.Read", "Files.ReadWrite"]

    private lazy var redirectUri: String = {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.example.app"
        return "msauth.\(bundleID)://auth"
    }()

    // Use "common" if you support both personal + work/school accounts
    private lazy var authorityURLString: String = "https://login.microsoftonline.com/common"

    private weak var viewController: ViewController?
    private weak var settingsViewController: SettingsViewController?
    private var recordingManager: RecordingManager?

    private var msalApp: MSALPublicClientApplication?
    private var signedInAccount: MSALAccount?

    // MARK: - Init / Attach
    init() {
        configureMSAL() // safe to set up immediately
    }

    func attach(settingsViewController: SettingsViewController) {
        self.settingsViewController = settingsViewController
    }

    func attach(viewController: ViewController, recordingManager: RecordingManager) {
        self.viewController = viewController
        self.recordingManager = recordingManager
    }

    // MARK: - MSAL Setup
    private func configureMSAL() {
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
            self.msalApp = try MSALPublicClientApplication(configuration: config)

            // Restore cached account, if any
            if let accounts = try? self.msalApp?.allAccounts(),
               let first = accounts.first {
                self.signedInAccount = first
            } else {
                print("MSAL: no cached account")
            }

            print("MSAL configured ✅")
        } catch {
            print("MSAL init failed")
        }
    }

    // MARK: - Sign out
    @MainActor
    func SignOutAppOnly(completion: @escaping (Bool) -> Void) {
        guard let app = msalApp else { completion(false); return }
        let accounts = (try? app.allAccounts()) ?? []
        for acc in accounts { try? app.remove(acc) }  // clears tokens for your app
        signedInAccount = nil
        completion(true)
    }

    @MainActor
    func SignOutEverywhere(completion: @escaping (Bool) -> Void) {
        guard let app = msalApp else { completion(false); return }
        guard let account = (try? app.allAccounts().first) else { completion(true); return }
        guard let settingsViewController = settingsViewController else { completion(false); return }

        // This will present the iOS browser consent dialog
        let web = MSALWebviewParameters(authPresentationViewController: settingsViewController)
        let params = MSALSignoutParameters(webviewParameters: web)
        params.signoutFromBrowser = true
        params.wipeAccount = false  // be careful with wipeAccount

        app.signout(with: account, signoutParameters: params) { [weak self] success, _ in
            Task { @MainActor in
                if success { self?.signedInAccount = nil }
                completion(success)
            }
        }
    }

    // MARK: - Sign-in
    func SignInIfNeeded(completion: @escaping (AuthResult) -> Void) {
        guard let app = msalApp else {
            DispatchQueue.main.async { completion(.error(ODRError.notConfigured)) }
            return
        }

        // Prefer a hydrated account; otherwise query cache now.
        let account: MSALAccount? = signedInAccount ?? (try? app.allAccounts().first)

        if let account {
            let silent = MSALSilentTokenParameters(scopes: scopes, account: account)
            app.acquireTokenSilent(with: silent) { [weak self] result, error in
                guard let self = self else { return }

                if let result {
                    self.signedInAccount = result.account
                    DispatchQueue.main.async { completion(.alreadyAuthenticated) }
                    return
                }

                // Only fall back to interactive when MSAL says interaction is required.
                let ns = error as NSError?
                let needsUI = (ns?.domain == MSALErrorDomain &&
                               ns?.code == MSALError.interactionRequired.rawValue)

                if needsUI {
                    self.presentInteractive(completion: completion)
                } else {
                    DispatchQueue.main.async {
                        ProgressHUD.failed("Unable to sign into OneDrive. Check your internet connection and try again.")
                        completion(.error(error))
                    }
                }
            }
            return
        }

        // No cached account → interactive if we can present UI
        presentInteractive(completion: completion)
    }

    private func presentInteractive(completion: @escaping (AuthResult) -> Void) {
        guard let app = msalApp else {
            DispatchQueue.main.async { completion(.error(ODRError.notConfigured)) }
            return
        }
        guard let settingsViewController = settingsViewController else {
            DispatchQueue.main.async { completion(.error(ODRError.notConfigured)) }
            return
        }

        DispatchQueue.main.async { ProgressHUD.animate("Opening Microsoft sign-in…") }

        let web = MSALWebviewParameters(authPresentationViewController: settingsViewController)
        let params = MSALInteractiveTokenParameters(scopes: scopes, webviewParameters: web)

        app.acquireToken(with: params) { [weak self] result, error in
            guard let self = self else { return }

            if let result {
                self.signedInAccount = result.account
                DispatchQueue.main.async {
                    ProgressHUD.succeed("Signed into OneDrive")
                    completion(.success)
                }
                return
            }

            let ns = error as NSError?
            let userCanceled = (ns?.domain == MSALErrorDomain &&
                                ns?.code == MSALError.userCanceled.rawValue)

            DispatchQueue.main.async {
                ProgressHUD.dismiss()
                if userCanceled {
                    // User explicitly canceled the Microsoft sign-in flow.
                    completion(.cancel)
                } else {
                    ProgressHUD.failed("Unable to sign into OneDrive. Please try again later.")
                    completion(.error(error))
                }
            }
        }
    }

    private func getAccessTokenSilently() async throws -> String {
        guard let app = msalApp else { throw ODRError.notConfigured }
        let account: MSALAccount
        if let acc = signedInAccount { account = acc }
        else {
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

    // Called from AppDelegate (or your OAuth router) on redirect
    @discardableResult
    func handleRedirect(url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        let handled = MSALPublicClientApplication.handleMSALResponse(
            url,
            sourceApplication: options[UIApplication.OpenURLOptionsKey.sourceApplication] as? String
        )

        if !handled {
            DispatchQueue.main.async {
                ProgressHUD.failed("Unable to complete OneDrive sign-in. Please try again.")
            }
        }
        return handled
    }

    // MARK: - Public: present OneDrive folder picker (programmatic UI)
    @MainActor
    func PresentOneDriveFolderPicker(onPicked: ((OneDriveSelection) -> Void)? = nil) {
        guard let settingsVC = settingsViewController else {
            ProgressHUD.failed("Unable to open the OneDrive folder picker. Try again later.")
            print("Settings view controller is nil")
            return
        }
        Task {
            do {
                let token = try await getAccessTokenSilently()
                let driveId = try await getDefaultDriveId(token: token)
                let startCtx = DriveContext(driveId: driveId, itemId: "root", name: "OneDrive")

                // Load last saved selection to show in the header only
                let lastSel = self.loadSelection()

                let vc = FolderPickerViewController(
                    manager: self,
                    accessToken: token,
                    start: startCtx,
                    lastSavedSelection: lastSel,
                    currentFolderId: "root",            // parent == current folder for this level
                    onPicked: { [weak self] sel in
                        self?.saveSelection(sel)
                        onPicked?(sel)
                    }
                )
                let nav = UINavigationController(rootViewController: vc)
                nav.modalPresentationStyle = .formSheet
                settingsVC.present(nav, animated: true)
            } catch {
                ProgressHUD.failed("Unable to open the OneDrive folder picker. Make sure you are signed into OneDrive and try again.")
            }
        }
    }

    func sanitizeForOneDriveFileName(_ name: String, fallback: String = "Recording") -> String {
        // Illegal in OneDrive/Windows:  \ / : * ? " < > |  and control chars
        let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|").union(.controlCharacters)

        // Replace illegal characters with "-"
        var cleaned = ""
        cleaned.reserveCapacity(name.count)
        for scalar in name.unicodeScalars {
            if invalid.contains(scalar) {
                cleaned.append("-")
            } else {
                cleaned.append(String(scalar))
            }
        }

        // OneDrive/Windows: name cannot end with a space or a dot
        while let last = cleaned.unicodeScalars.last, last == " " || last == "." {
            cleaned.removeLast()
            cleaned.append("-")
        }

        // Ensure non-empty result
        if cleaned.isEmpty { return fallback }

        // Enforce 255-character component limit (preserving extension if present)
        if cleaned.count > 255 {
            let ext = (cleaned as NSString).pathExtension
            var base = (cleaned as NSString).deletingPathExtension
            let maxBase = max(1, 255 - (ext.isEmpty ? 0 : ext.count + 1))
            if base.count > maxBase { base = String(base.prefix(maxBase)) }
            cleaned = ext.isEmpty ? base : "\(base).\(ext)"
        }

        return cleaned
    }

    // MARK: - Public: upload entry point (uses selected folder or default)
    @MainActor
    func SendToOneDrive(hasTranscription: Bool,
                        preferredFileName: String? = nil,
                        progress: ((Double) -> Void)? = nil) {
        Task { [weak self] in
            guard let self = self else { return }
            guard let viewController = self.viewController,
                  let recordingManager = self.recordingManager else { return }

            ProgressHUD.animate("Sending...", .triangleDotShift)
            viewController.DisableUI()
            defer { Task { @MainActor in viewController.EnableUI() } }

            // Build local file URLs
            let baseName = recordingManager.toggledAudioTranscriptionObject.fileName
            let dir      = recordingManager.GetDirectory()
            let audioURL = dir.appendingPathComponent(recordingManager.toggledAudioTranscriptionObject.uuid.uuidString)
                              .appendingPathExtension(recordingManager.audioRecordingExtension)
            let txtURL   = dir.appendingPathComponent(recordingManager.toggledAudioTranscriptionObject.uuid.uuidString)
                              .appendingPathExtension(recordingManager.transcriptionRecordingExtension)

            do {
                // 1) Token + destination
                let token  = try await self.getAccessTokenSilently()
                let target = try await self.resolveSelectionOrDefault(token: token) // user-picked or default
                
                let prettyAudioURL: URL? = try recordingManager.createPrettyFileURLForExport(for: audioURL, exportedFilename: recordingManager.toggledAudioTranscriptionObject.fileName, ext: recordingManager.audioRecordingExtension)
                guard let prettyAudioURL else {
                    ProgressHUD.dismiss()
                    ProgressHUD.failed("Unable to send to OneDrive, make another recording and try again later.")
                    viewController.EnableUI()
                    return
                }
                // 2) Upload audio
                _ = try await self.uploadRecording(
                    accessToken: token,
                    fileURL: prettyAudioURL,
                    fileName: baseName + "." + recordingManager.audioRecordingExtension,
                    to: target,
                    progress: progress
                )
                // 3) Optionally upload transcript (respect the toggle + param + file existence)
                let shouldSendTranscript =
                    recordingManager.toggledAudioTranscriptionObject.hasTranscription &&
                    hasTranscription &&
                    FileManager.default.fileExists(atPath: txtURL.path)
                
                let prettyTranscriptURL: URL? = try recordingManager.createPrettyFileURLForExport(for: txtURL, exportedFilename: recordingManager.toggledAudioTranscriptionObject.fileName, ext: recordingManager.transcriptionRecordingExtension)
                if shouldSendTranscript {
                    if let prettyTranscriptURL {
                        _ = try await self.uploadRecording(
                            accessToken: token,
                            fileURL: prettyTranscriptURL,
                            fileName: baseName + "." + recordingManager.transcriptionRecordingExtension,
                            to: target,
                            progress: nil // keep progress tied to the main audio if you want
                        )
                        await MainActor.run {
                            ProgressHUD.succeed("Recording and transcript sent to OneDrive")
                            viewController.safeDisplayAlert(
                                title: "Recording and transcript sent to OneDrive",
                                message: "Your recording and transcript were sent to OneDrive while Prime Dictation was in the background.",
                                type: .send,
                                result: .success
                            )
                        }
                    }
                } else {
                    await MainActor.run {
                        ProgressHUD.succeed("Recording sent to OneDrive")
                        viewController.safeDisplayAlert(
                            title: "Recording sent to OneDrive",
                            message: "Your recording was sent to OneDrive while Prime Dictation was in the background.",
                            type: .send,
                            result: .success
                        )
                    }
                }
            } catch {
                // If audio failed (or transcript failed after audio), show a concise message
                await MainActor.run {
                    viewController.safeDisplayAlert(
                        title: "Send failed",
                        message: "Unable to send the recording and/or transcript to OneDrive. Check your internet connection and try again.",
                        type: .send,
                        result: .failure
                    )
                }
            }
        }
    }

    // MARK: - Upload implementations (Graph) targeting selected folder
    private func uploadRecording(accessToken: String,
                                 fileURL: URL,
                                 fileName: String,
                                 to selection: OneDriveSelection,
                                 progress: ((Double) -> Void)?) async throws -> DriveItem {

        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        let size = Int64(values.fileSize ?? 0)
        if size <= 4 * 1024 * 1024 {
            return try await uploadSmallFile(token: accessToken, fileURL: fileURL, as: fileName, to: selection)
        } else {
            return try await uploadLargeFile(token: accessToken, fileURL: fileURL, as: fileName, to: selection, progress: progress)
        }
    }

    // Simple upload (≤ 4 MB)
    private func uploadSmallFile(token: String,
                                 fileURL: URL,
                                 as fileName: String,
                                 to sel: OneDriveSelection) async throws -> DriveItem {
        let enc = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        let url = URL(string: "https://graph.microsoft.com/v1.0/drives/\(sel.driveId)/items/\(sel.itemId):/\(enc):/content")!
        let data = try Data(contentsOf: fileURL)
        let req = authorizedRequest(url: url,
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
    private func uploadLargeFile(token: String,
                                 fileURL: URL,
                                 as fileName: String,
                                 to sel: OneDriveSelection,
                                 progress: ((Double) -> Void)? = nil,
                                 chunkSize: Int = 5 * 1024 * 1024) async throws -> DriveItem {

        let sessionURL = URL(string: "https://graph.microsoft.com/v1.0/drives/\(sel.driveId)/items/\(sel.itemId):/\(percentPathComponent(fileName)):/createUploadSession")!

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

    // MARK: - Selection persistence + default folder resolution
    struct OneDriveSelection: Codable { let driveId: String; let itemId: String }

    private func saveSelection(_ sel: OneDriveSelection) {
        let data = try! JSONEncoder().encode(sel)
        print("Saving to user defaults")
        UserDefaults.standard.set(data, forKey: "OneDriveFolderSelection")
    }

    private func loadSelection() -> OneDriveSelection? {
        guard let data = UserDefaults.standard.data(forKey: "OneDriveFolderSelection") else { return nil }
        return try? JSONDecoder().decode(OneDriveSelection.self, from: data)
    }

    /// If user picked a folder, use it; otherwise send to the root
    private func resolveSelectionOrDefault(token: String) async throws -> OneDriveSelection {
        if let sel = loadSelection() { return sel }
        let driveId = try await getDefaultDriveId(token: token)

        return OneDriveSelection(driveId: driveId, itemId: "root")
    }

    // MARK: - Folder Picker plumbing (Graph)
    // Drive discovery
    private struct DriveIdentity: Decodable { let id: String } // from /me/drive

    private func getDefaultDriveId(token: String) async throws -> String {
        let url = URL(string: "https://graph.microsoft.com/v1.0/me/drive?$select=id")!
        let (data, resp) = try await URLSession.shared.data(for: authorizedRequest(url: url, token: token))
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ODRError.badResponse(status: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                                       body: String(data: data, encoding: .utf8) ?? "")
        }
        return try decode(DriveIdentity.self, from: data).id
    }

    // Picker models (only what we need)
    fileprivate struct PickerDriveItem: Decodable {
        let id: String
        let name: String
        let folder: FolderFacet?
        let shortcut: ShortcutFacet?
        let remoteItem: RemoteItem?
        let parentReference: ParentReference?
        struct FolderFacet: Decodable { let childCount: Int? }
        struct ShortcutFacet: Decodable {}
        struct RemoteItem: Decodable {
            let id: String?
            let name: String?
            let folder: FolderFacet?
            let parentReference: ParentReference?
        }
        struct ParentReference: Decodable {
            let driveId: String?
            let id: String?
            let path: String?
        }
    }

    private struct PickerListResponse: Decodable {
        let value: [PickerDriveItem]
        let nextLink: String?  // "@odata.nextLink"
        enum CodingKeys: String, CodingKey { case value; case nextLink = "@odata.nextLink" }
    }

    fileprivate struct DriveContext {
        let driveId: String
        let itemId: String
        let name: String?
    } // itemId can be "root"

    fileprivate func listChildren(token: String, ctx: DriveContext, next: URL? = nil) async throws -> (items: [PickerDriveItem], next: URL?) {
        let url: URL = {
            if let next { return next }
            let base: String
            if ctx.itemId == "root" {
                base = "https://graph.microsoft.com/v1.0/drives/\(ctx.driveId)/root/children"
            } else {
                base = "https://graph.microsoft.com/v1.0/drives/\(ctx.driveId)/items/\(ctx.itemId)/children"
            }
            return URL(string: base + "?$select=id,name,folder,shortcut,remoteItem,parentReference&$orderby=name&$top=200")!
        }()
        let (data, resp) = try await URLSession.shared.data(for: authorizedRequest(url: url, token: token))
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ODRError.badResponse(status: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                                       body: String(data: data, encoding: .utf8) ?? "")
        }
        let parsed = try decode(PickerListResponse.self, from: data)
        let nextURL = parsed.nextLink.flatMap(URL.init(string:))
        return (parsed.value, nextURL)
    }

    fileprivate func nextContext(from current: DriveContext, tapped item: PickerDriveItem) -> DriveContext? {
        // Real folder in current drive
        if item.folder != nil {
            return DriveContext(driveId: current.driveId, itemId: item.id, name: item.name)
        }
        // Shortcut (Add to OneDrive) targeting a folder, possibly in another drive
        if let remote = item.remoteItem, remote.folder != nil,
           let targetDriveId = remote.parentReference?.driveId,
           let targetItemId  = remote.id {
            return DriveContext(driveId: targetDriveId, itemId: targetItemId, name: item.name)
        }
        return nil
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
    
    // Special key for "root" when parentReference.id is nil
    private static let rootKey = "__root__"

    // Fetch parentReference for an item
    private func fetchParentRef(token: String, driveId: String, itemId: String) async throws -> (parentId: String?, parentDriveId: String?) {
        struct ItemParentOnly: Decodable {
            let id: String
            let parentReference: ParentReference?
            struct ParentReference: Decodable { let id: String?; let driveId: String?; let path: String? }
        }
        let url = URL(string: "https://graph.microsoft.com/v1.0/drives/\(driveId)/items/\(itemId)?$select=id,parentReference")!
        let (data, resp) = try await URLSession.shared.data(for: authorizedRequest(url: url, token: token))
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ODRError.badResponse(status: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                                       body: String(data: data, encoding: .utf8) ?? "")
        }
        let parsed = try decode(ItemParentOnly.self, from: data)
        return (parsed.parentReference?.id, parsed.parentReference?.driveId)
    }
    
    // Cache: driveId -> rootItemId
    private var driveRootIdCache: [String:String] = [:]

    private func getDriveRootItemId(token: String, driveId: String) async throws -> String {
        if let cached = driveRootIdCache[driveId] { return cached }
        // This returns the *item id* of the root folder
        let url = URL(string: "https://graph.microsoft.com/v1.0/drives/\(driveId)/root?$select=id")!
        let (data, resp) = try await URLSession.shared.data(for: authorizedRequest(url: url, token: token))
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ODRError.badResponse(status: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                                       body: String(data: data, encoding: .utf8) ?? "")
        }
        struct RootIdOnly: Decodable { let id: String }
        let rootId = try decode(RootIdOnly.self, from: data).id
        driveRootIdCache[driveId] = rootId
        return rootId
    }

    /// Build a mapping of { parentItemId(or RootKey) -> childItemId } along the saved selection path up to root.
    /// Returns empty map if no saved selection or drive mismatch.
    private func buildSelectedBranchMap(token: String, driveId: String) async -> [String:String] {
        guard let saved = loadSelection() else { return [:] }

        // If the saved destination is in another drive (e.g., SharePoint via shortcut),
        // mark root -> target so the root-level shortcut row (remoteItem.id) can match.
        if saved.driveId != driveId {
            return [Self.rootKey: saved.itemId]
        }

        // Same drive: walk up until the *real* drive root item id
        var map: [String:String] = [:]
        var childId = saved.itemId
        var hops = 0

        do {
            let rootItemId = try await getDriveRootItemId(token: token, driveId: driveId)

            while hops < 100 {
                let (parentId, parentDriveId) = try await fetchParentRef(token: token, driveId: driveId, itemId: childId)

                // Crossed drives or no parent -> treat current child as under root
                if parentDriveId != driveId || parentId == nil {
                    map[Self.rootKey] = childId
                    break
                }

                // If the parent is the *root item*, stop: current child is the first-level folder
                if parentId == rootItemId {
                    map[Self.rootKey] = childId
                    break
                }

                // Otherwise map parent -> child and move up
                map[parentId!] = childId
                childId = parentId!
                hops += 1
            }
        } catch {
            // If anything fails, return whatever mapping we have so far
            return map
        }
        return map
    }


    // MARK: - Models & Errors used by uploads/default-folder
    struct DriveItem: Decodable {
        let id: String
        let name: String
        let size: Int64?
        let webUrl: String?
    }

    private struct DriveItemWithParent: Decodable {
        let id: String
        let name: String
        let parentReference: ParentReference?
        struct ParentReference: Decodable { let driveId: String? }
    }

    enum ODRError: Error {
        case notConfigured
        case notSignedIn
        case tokenFailure
        case badResponse(status: Int, body: String)
        case missingUploadUrl
    }

    // MARK: - Load Info.plist keys
    private func loadMSClientApplicationId() -> String {
        guard var key = Bundle.main.object(forInfoDictionaryKey: "MS_CLIENT_APPLICATION_ID") as? String else {
            fatalError("Missing MS_CLIENT_APPLICATION_ID in Info.plist")
        }
        key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasPrefix("$(") { fatalError("MS_CLIENT_APPLICATION_ID not resolved") }
        return key
    }

    // Optional, if you need a specific tenant
    private func loadMSTenantDirectoryId() -> String {
        guard var key = Bundle.main.object(forInfoDictionaryKey: "MS_TENANT_DIRECTORY_ID") as? String else {
            fatalError("Missing MS_TENANT_DIRECTORY_ID in Info.plist")
        }
        key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasPrefix("$(") { fatalError("MS_TENANT_DIRECTORY_ID not resolved") }
        return key
    }

    // MARK: - Simplified UIKit Folder Picker (✓ + Done + black chevrons + header)
    private final class FolderPickerViewController: UITableViewController {
        private weak var manager: OneDriveManager?
        private let token: String
        private var ctx: DriveContext
        private var items: [PickerDriveItem] = []
        private var nextPage: URL?
        private let onPicked: (OneDriveSelection) -> Void

        // Header shows last saved selection (read-only label)
        private let lastSavedSelection: OneDriveSelection?

        // The "parent/current folder" for this screen; Done uses this if no leaf picked
        private let currentFolderId: String

        // Only leaves get ✓ (no initial ✓)
        private var selectedId: String?

        // UI
        private let rowHeight: CGFloat = 56.0
        private let footerHeight: CGFloat = 68.0

        init(manager: OneDriveManager,
             accessToken: String,
             start: DriveContext,
             lastSavedSelection: OneDriveSelection?,
             currentFolderId: String,
             onPicked: @escaping (OneDriveSelection) -> Void) {
            self.manager = manager
            self.token = accessToken
            self.ctx = start
            self.lastSavedSelection = lastSavedSelection
            self.currentFolderId = currentFolderId
            self.onPicked = onPicked
            super.init(style: .insetGrouped)
            self.title = start.itemId == "root" ? "OneDrive" : (start.name ?? "OneDrive")
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidLoad() {
            super.viewDidLoad()

            // Done is enabled initially → represents current folder selection by default
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: "Done",
                style: .done,
                target: self,
                action: #selector(confirmSelectionAndDismiss)
            )

            navigationItem.leftBarButtonItem = UIBarButtonItem(
                primaryAction: UIAction(title: "Sign Out") { [weak self] _ in
                    guard let self = self, let manager = self.manager else { return }
                    ProgressHUD.animate("Signing out…")
                    manager.SignOutAppOnly { success in
                        Task { @MainActor in
                            guard let settingsVC = manager.settingsViewController else { return }
                            if success {
                                settingsVC.UpdateSelectedDestinationUserDefaults(destination: Destination.none)
                                settingsVC.UpdateSelectedDestinationUI(destination: Destination.none)
                                self.dismiss(animated: true)
                                ProgressHUD.succeed("Signed out of OneDrive")
                            } else {
                                ProgressHUD.failed("Sign out failed")
                            }
                        }
                    }
                }
            )

            // Header: "Last selected: …"
            tableView.tableHeaderView = buildLastSelectedHeader()

            // Row visuals
            tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
            tableView.rowHeight = rowHeight
            tableView.estimatedRowHeight = rowHeight

            Task { await loadPage(reset: true) }
            ProgressHUD.dismiss()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            // Keep header/footer widths in sync
            if let header = tableView.tableHeaderView {
                let targetWidth = tableView.bounds.width
                if abs(header.frame.width - targetWidth) > 0.5 {
                    header.frame.size.width = targetWidth
                    tableView.tableHeaderView = header
                }
            }
            if let footer = tableView.tableFooterView {
                let targetWidth = tableView.bounds.width
                if abs(footer.frame.width - targetWidth) > 0.5 {
                    footer.frame.size.width = targetWidth
                    tableView.tableFooterView = footer
                }
            }
        }

        private func buildLastSelectedHeader() -> UIView {
            let v = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 44))
            v.backgroundColor = .clear

            let label = UILabel()
            label.font = .systemFont(ofSize: 14)
            label.textColor = .secondaryLabel
            label.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(label)

            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
                label.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -20),
                label.topAnchor.constraint(equalTo: v.topAnchor, constant: 12),
                label.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
            ])

            // Default text, then try to resolve a friendly name asynchronously
            label.text = "Last selected: " + {
                guard let sel = lastSavedSelection else { return "Root" }
                return sel.itemId == "root" ? "Root" : "Loading…"
            }()

            if let sel = lastSavedSelection, sel.itemId != "root" {
                Task { [weak self] in
                    guard let self = self, let manager = self.manager else { return }
                    do {
                        // Fetch the item to show its name
                        let url = URL(string: "https://graph.microsoft.com/v1.0/drives/\(sel.driveId)/items/\(sel.itemId)?$select=id,name")!
                        let (data, resp) = try await URLSession.shared.data(for: manager.authorizedRequest(url: url, token: self.token))
                        if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let name = obj["name"] as? String {
                            await MainActor.run { label.text = "Last selected: \(name)" }
                        } else {
                            await MainActor.run { label.text = "Last selected: Unknown" }
                        }
                    } catch {
                        await MainActor.run { label.text = "Last selected: Unknown" }
                    }
                }
            }
            return v
        }

        @MainActor
        private func loadPage(reset: Bool) async {
            guard let manager else { return }
            if reset {
                items.removeAll(); nextPage = nil; tableView.reloadData()
            }
            do {
                let (newItems, next) = try await manager.listChildren(token: token, ctx: ctx, next: nextPage)
                // Keep only folder-like items (real folders or shortcut to folder)
                self.items.append(contentsOf: newItems.filter { $0.folder != nil || $0.remoteItem?.folder != nil })
                self.nextPage = next
                self.tableView.reloadData()
                self.title = (ctx.itemId == "root") ? "OneDrive" : (ctx.name ?? "OneDrive Folder")
            } catch {
                ProgressHUD.failed("Unable to load OneDrive folders. Check your internet connection and try again.")
                print("Unable to list OneDrive folders")
            }
        }

        // MARK: - Table datasource

        override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            items.count + (nextPage != nil ? 1 : 0)
        }

        override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            if nextPage != nil && indexPath.row == items.count {
                let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
                cell.textLabel?.text = "Load more…"
                cell.accessoryType = .none
                cell.accessoryView = nil
                cell.imageView?.image = nil
                return cell
            }

            let item = items[indexPath.row]
            let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)

            // Left folder icon
            let symConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            cell.imageView?.preferredSymbolConfiguration = symConfig
            cell.imageView?.image = UIImage(systemName: "folder")
            cell.imageView?.tintColor = .label

            // Title
            cell.textLabel?.text = item.name
            cell.textLabel?.font = .systemFont(ofSize: 16)

            // Clear reused accessories
            cell.accessoryType = .none
            cell.accessoryView = nil

            let rowId = item.remoteItem?.id ?? item.id
            if selectedId != currentFolderId, rowId == selectedId {
                cell.accessoryType = .checkmark
                return cell
            }

            // Black chevron for non-leaf folders
            let childCount = item.folder?.childCount ?? item.remoteItem?.folder?.childCount
            let hasSubfolders = (childCount ?? 0) > 0 || (childCount == nil) // if unknown, assume expandable
            if hasSubfolders {
                let iv = UIImageView(image: UIImage(systemName: "chevron.right"))
                iv.tintColor = .label
                cell.accessoryView = iv
            }
            return cell
        }

        // MARK: - Table delegate

        override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
            tableView.deselectRow(at: indexPath, animated: true)

            // "Load more…"
            if nextPage != nil && indexPath.row == items.count {
                Task { await loadPage(reset: false) }
                return
            }

            guard let manager else { return }
            let item = items[indexPath.row]
            let tappedId = item.remoteItem?.id ?? item.id

            // Decide leaf/non-leaf using childCount if available; if unknown, treat as non-leaf and navigate.
            let childCount = item.folder?.childCount ?? item.remoteItem?.folder?.childCount
            let isLeaf = (childCount == 0)

            if isLeaf {
                // Toggle ✓; Done stays enabled (represents current folder if cleared)
                let previousSelectedId = selectedId
                if selectedId == tappedId {
                    selectedId = currentFolderId
                } else {
                    selectedId = tappedId
                }

                var rowsToReload = [indexPath]
                if let prevId = previousSelectedId,
                   prevId != tappedId,
                   prevId != currentFolderId, // ← guard
                   let prevIdx = items.firstIndex(where: { ($0.remoteItem?.id ?? $0.id) == prevId }) {
                    rowsToReload.append(IndexPath(row: prevIdx, section: 0))
                }
                tableView.reloadRows(at: rowsToReload, with: .none)
                return
            }

            // Non-leaf: navigate deeper. (No ✓ here.)
            if let next = manager.nextContext(from: ctx, tapped: item) {
                let vc = FolderPickerViewController(
                    manager: manager,
                    accessToken: token,
                    start: next,
                    lastSavedSelection: lastSavedSelection,
                    currentFolderId: tappedId,   // parent for next level
                    onPicked: onPicked
                )
                navigationController?.pushViewController(vc, animated: true)
            }
        }

        // MARK: - Done

        @objc private func confirmSelectionAndDismiss() {
            guard let manager = self.manager else { return }

            let idToUse = selectedId ?? currentFolderId
            
            // Root special-case
            if idToUse == "root" {
                let sel = OneDriveSelection(driveId: ctx.driveId, itemId: "root")
                manager.saveSelection(sel)
                onPicked(sel)
                dismiss(animated: true)
                ProgressHUD.succeed("Root selected")
                return
            }

            // Save selection
            let sel = OneDriveSelection(driveId: ctx.driveId, itemId: idToUse)
            manager.saveSelection(sel)
            onPicked(sel)
            dismiss(animated: true)

            // Pick a friendly name for the HUD
            if idToUse == currentFolderId {
                // Selected the parent/current folder
                let display = (currentFolderId == "root")
                    ? "Root"
                    : (ctx.name ?? "OneDrive Folder")
                ProgressHUD.succeed("\(display) selected")
            } else if let found = items.first(where: { ($0.remoteItem?.id ?? $0.id) == idToUse })?.name {
                ProgressHUD.succeed("\(found) selected")
            } else {
                ProgressHUD.succeed("Folder selected")
            }
        }
    }

}
