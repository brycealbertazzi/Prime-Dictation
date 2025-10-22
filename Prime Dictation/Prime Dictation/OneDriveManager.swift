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
                print("MSAL: restored cached account → \(first.username ?? "(no username)")")
            } else {
                print("MSAL: no cached account")
            }

            print("MSAL configured ✅")
        } catch {
            print("MSAL init failed ❌ \(error)")
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
                        ProgressHUD.failed("OneDrive sign-in error")
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
                    completion(.cancel)
                } else {
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
                ProgressHUD.failed("Unable to sign into OneDrive")
            }
        }
        return handled
    }

    // MARK: - Public: present OneDrive folder picker (programmatic UI)
    @MainActor
    func PresentOneDriveFolderPicker(onPicked: ((OneDriveSelection) -> Void)? = nil) {
        guard let settingsVC = settingsViewController else {
            ProgressHUD.failed("Open Settings first")
            return
        }
        Task {
            do {
                let token = try await getAccessTokenSilently()
                let driveId = try await getDefaultDriveId(token: token)
                let startCtx = DriveContext(driveId: driveId, itemId: "root", name: "OneDrive")
                let map = await buildSelectedBranchMap(token: token, driveId: driveId)

                let vc = FolderPickerViewController(manager: self, accessToken: token, start: startCtx, branchMap: map) { [weak self] sel in
                    self?.saveSelection(sel)
                    onPicked?(sel)
                }
                let nav = UINavigationController(rootViewController: vc)
                nav.modalPresentationStyle = .formSheet
                settingsVC.present(nav, animated: true)
            } catch {
                ProgressHUD.failed("Sign in to OneDrive first")
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
    func SendToOneDrive(url: URL, preferredFileName: String? = nil, progress: ((Double) -> Void)? = nil) {
        Task { [weak self] in
            guard let self = self else { return }
            guard let viewController = viewController else { return }

            await ProgressHUD.animate("Sending...", .triangleDotShift)
            await viewController.DisableUI()
            defer { Task { @MainActor in viewController.EnableUI() } }

            do {
                let token = try await self.getAccessTokenSilently()
                let target = try await self.resolveSelectionOrDefault(token: token) // user choice or "/Prime Dictation"
                let fileName = preferredFileName ?? url.lastPathComponent
                let sanitizedFileName = self.sanitizeForOneDriveFileName(fileName)
                
                print("sanitizedFileName: \(sanitizedFileName)")
                _ = try await self.uploadRecording(accessToken: token,
                                                   fileURL: url,
                                                   fileName: sanitizedFileName,
                                                   to: target,
                                                   progress: progress)
                await MainActor.run {
                    ProgressHUD.succeed("Recording was sent to OneDrive")
                }
            } catch {
                await MainActor.run {
                    ProgressHUD.dismiss()
                    viewController.displayAlert(title: "Recording send failed", message: "Please select a OneDrive folder.", handler: {
                        ProgressHUD.failed("Failed to send recording to OneDrive")
                    })
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
        UserDefaults.standard.set(data, forKey: "OneDriveFolderSelection")
    }

    private func loadSelection() -> OneDriveSelection? {
        guard let data = UserDefaults.standard.data(forKey: "OneDriveFolderSelection") else { return nil }
        return try? JSONDecoder().decode(OneDriveSelection.self, from: data)
    }

    /// If user picked a folder, use it; otherwise ensure/create "Prime Dictation" and return its IDs
    private func resolveSelectionOrDefault(token: String) async throws -> OneDriveSelection {
        if let sel = loadSelection() { return sel }
        let driveId = try await getDefaultDriveId(token: token)

        // Try create (idempotent via 'replace'); if it existed, fetch by path
        struct CreateFolderBody: Encodable {
            let name: String
            let folder: [String:String] = [:]
            let conflictBehavior: String
        }
        let createURL = URL(string: "https://graph.microsoft.com/v1.0/drives/\(driveId)/root/children")!
        let body = CreateFolderBody(name: "Prime Dictation", conflictBehavior: "replace")
        let (cData, cResp) = try await URLSession.shared.data(for: authorizedRequest(
            url: createURL, token: token, method: "POST",
            headers: ["Content-Type":"application/json"], body: try JSONEncoder().encode(body)
        ))
        if let http = cResp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
            let item = try decode(DriveItemWithParent.self, from: cData)
            return OneDriveSelection(driveId: item.parentReference?.driveId ?? driveId, itemId: item.id)
        }

        // Get by path (if already there)
        let path = percentPathComponent("Prime Dictation")
        let getURL = URL(string: "https://graph.microsoft.com/v1.0/drives/\(driveId)/root:/\(path)")!
        let (gData, gResp) = try await URLSession.shared.data(for: authorizedRequest(url: getURL, token: token))
        guard let gHttp = gResp as? HTTPURLResponse, (200...299).contains(gHttp.statusCode) else {
            throw ODRError.badResponse(status: (gResp as? HTTPURLResponse)?.statusCode ?? -1,
                                       body: String(data: gData, encoding: .utf8) ?? "")
        }
        let item = try decode(DriveItemWithParent.self, from: gData)
        return OneDriveSelection(driveId: item.parentReference?.driveId ?? driveId, itemId: item.id)
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

    // MARK: - UIKit Folder Picker (with ✓ + Done + leaf cache)
    private final class FolderPickerViewController: UITableViewController {
        private weak var manager: OneDriveManager?
        private let token: String
        private var ctx: DriveContext
        private var items: [PickerDriveItem] = []
        private var nextPage: URL?
        private let onPicked: (OneDriveSelection) -> Void
        /// Base set of itemIds that are on the saved/active destination path (ancestors + leaf).
        private let basePathSet: Set<String>
        /// Effective path also includes the in-flight selection at this level (so chevrons update immediately).
        private var effectivePathSet: Set<String> {
            var s = basePathSet
            if let w = workingSelectedChildId { s.insert(w) }
            return s
        }
        private var selectedLeafId: String?
        /// Override of { parentKey -> selected childId } at THIS level (supersedes branchMap)
        private var pathChildOverride: [String:String] = [:]

        /// Parent key for the current table (root gets a special key)
        private var currentParentKey: String {
            return (ctx.itemId == "root") ? OneDriveManager.rootKey : ctx.itemId
        }
        /// Map of { parentId (or RootKey) -> childId } along the saved/active destination path.
        private var branchMap: [String:String]

        /// Working selection at THIS level (used for Done button semantics)
        private var workingSelectedChildId: String? {
            get { branchMap[currentParentKey] }
            set { branchMap[currentParentKey] = newValue }
        }


        /// Track previously-checked row so we can reload it when selection changes
        private var selectedIndexPath: IndexPath?

        /// Leaf cache to avoid async in cellForRow + reduce flicker
        private var leafCache: [String: Bool] = [:] // key: canonical item id → true if NO subfolders

        /// Initial selected child for this level from branchMap (if any)
        private func initialSelectedChildId() -> String? {
            let parentKey = (ctx.itemId == "root") ? OneDriveManager.rootKey : ctx.itemId
            return branchMap[parentKey]
        }

        // Footer button (Clear Selection)
        private let footerHeight: CGFloat = 68.0
        private lazy var footerViewContainer: UIView = {
            let v = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: footerHeight))
            v.backgroundColor = .clear
            return v
        }()
        private lazy var clearButton: UIButton = {
            let b = UIButton(type: .system)
            b.setTitle("Clear Selection", for: .normal)
            b.addTarget(self, action: #selector(clearSelectionTapped), for: .touchUpInside)
            b.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
            b.sizeToFit()
            b.center = CGPoint(x: footerViewContainer.bounds.midX, y: footerViewContainer.bounds.midY)
            b.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
            return b
        }()

        init(manager: OneDriveManager,
             accessToken: String,
             start: DriveContext,
             branchMap: [String:String],
             onPicked: @escaping (OneDriveSelection) -> Void)
        {
            self.manager = manager
            self.token = accessToken
            self.ctx = start
            self.onPicked = onPicked
            self.branchMap = branchMap
            self.basePathSet = Set(branchMap.values)
            // Derive the final leaf in the chain: a value that never appears as a key.
            let childSet = Set(branchMap.values)
            let parentSet = Set(branchMap.keys.filter { $0 != OneDriveManager.rootKey })
            self.selectedLeafId = childSet.subtracting(parentSet).first
            super.init(style: .insetGrouped)
            self.title = "OneDrive"
            self.workingSelectedChildId = initialSelectedChildId()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidLoad() {
            super.viewDidLoad()
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                systemItem: .done,
                primaryAction: UIAction { [weak self] _ in
                    guard let self else { return }
                    // Determine chosen selection (child or current folder)
                    let chosen = workingSelectedChildId
                        .flatMap { OneDriveSelection(driveId: self.ctx.driveId, itemId: $0) }
                        ?? OneDriveSelection(driveId: ctx.driveId, itemId: ctx.itemId)

                    // Compute display name for HUD
                    let displayName: String = {
                        if let w = self.workingSelectedChildId,
                           let item = self.items.first(where: { ($0.remoteItem?.id ?? $0.id) == w }) {
                            return item.name
                        }
                        // current folder
                        if self.ctx.itemId == "root" { return "Root" }
                        return self.ctx.name ?? "OneDrive"
                    }()

                    onPicked(chosen)
                    self.dismiss(animated: true)
                    ProgressHUD.succeed("\(displayName) selected")
                }
            )
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                primaryAction: UIAction(title: "Sign Out") { [weak self] _ in
                    guard let self = self, let manager = self.manager else { return }
                    ProgressHUD.animate("Signing out…")
                    manager.SignOutAppOnly { success in
                        Task { @MainActor in
                            guard let settingsVC = manager.settingsViewController else {
                                print("Unable to find settings view controller on OneDrive signout")
                                return
                            }
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

            // Footer with Clear button
            footerViewContainer.addSubview(clearButton)
            tableView.tableFooterView = footerViewContainer

            tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
            Task { await loadPage(reset: true) }
            ProgressHUD.dismiss()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            // Ensure footer width matches table width (tableFooterView doesn't auto-layout)
            guard let footer = tableView.tableFooterView, footer === footerViewContainer else { return }
            let targetWidth = tableView.bounds.width
            if abs(footer.frame.width - targetWidth) > 0.5 {
                footer.frame.size.width = targetWidth
                tableView.tableFooterView = footer // reassign to apply new size
            }
        }

        private func setTitleFor(ctx: DriveContext) {
            if ctx.itemId == "root" { self.title = "OneDrive" }
            else { self.title = ctx.name ?? "OneDrive Folder" }
        }

        // Clear Selection footer action (mirrors Dropbox behavior)
        @objc private func clearSelectionTapped() {
            // Clear selection at THIS level so the current folder (parent) is effectively selected
            selectedLeafId = nil
            workingSelectedChildId = nil
            pathChildOverride[currentParentKey] = nil
            tableView.reloadData()
        }

        @MainActor
        private func loadPage(reset: Bool) async {
            guard let manager else { return }
            if reset {
                items.removeAll(); nextPage = nil; tableView.reloadData()
            }
            do {
                let (newItems, next) = try await manager.listChildren(token: token, ctx: ctx, next: nextPage)
                // Only folder-like items
                self.items.append(contentsOf: newItems.filter { $0.folder != nil || $0.remoteItem?.folder != nil })
                self.nextPage = next
                self.tableView.reloadData()
                setTitleFor(ctx: ctx)

                // If our initial selection exists in this page, mark its indexPath
                if let selId = selectedLeafId,
                   let idx = items.firstIndex(where: { ($0.remoteItem?.id ?? $0.id) == selId }) {
                    selectedIndexPath = IndexPath(row: idx, section: 0)
                }
            } catch {
                ProgressHUD.failed("Unable to list OneDrive folders")
            }
        }
        
        // MARK: - Leaf detection cache/probe

        private func canonicalId(for item: PickerDriveItem) -> String {
            // For shortcuts, cache by the target id so leaf-ness follows the real folder
            return item.remoteItem?.id ?? item.id
        }

        private func cachedIsLeaf(_ item: PickerDriveItem) -> Bool? {
            leafCache[canonicalId(for: item)]
        }

        private func probeLeafAndUpdateCell(for item: PickerDriveItem, at indexPath: IndexPath) {
            // Avoid duplicate probes
            if leafCache[canonicalId(for: item)] != nil { return }

            Task { [weak self] in
                guard let self = self, let manager = self.manager else { return }
                do {
                    let targetCtx = DriveContext(driveId: ctx.driveId, itemId: item.id, name: item.name)
                    let (children, _) = try await manager.listChildren(token: token, ctx: targetCtx, next: nil)
                    let hasSubfolders = children.contains { $0.folder != nil || $0.remoteItem?.folder != nil }
                    let isLeaf = !hasSubfolders
                    let canon = self.canonicalId(for: item)
                    self.leafCache[canon] = isLeaf

                    await MainActor.run {
                        guard let cell = self.tableView.cellForRow(at: indexPath) else { return }

                        // If THIS row is the selected folder → ALWAYS show ✓ (leaf or non-leaf)
                        let rowId = item.remoteItem?.id ?? item.id
                        if rowId == self.selectedLeafId {
                            cell.accessoryType = .checkmark
                            cell.accessoryView = nil
                            return
                        }

                        // Not selected: set chevron tint by path-child membership (ancestor = blue chevron)
                        cell.accessoryType = .none
                        cell.accessoryView = nil
                        if !isLeaf {
                            let pathChildId = self.pathChildOverride[self.currentParentKey] ?? self.branchMap[self.currentParentKey]
                            let isPathChildHere = (rowId == pathChildId)

                            let iv = UIImageView(image: UIImage(systemName: "chevron.right"))
                            iv.tintColor = isPathChildHere ? .systemBlue : .label
                            cell.accessoryView = iv
                        }
                    }
                } catch {
                    // Leave as is on error
                }
            }
        }

        private func indexPathForItemId(_ id: String) -> IndexPath? {
            if let idx = items.firstIndex(where: { ($0.remoteItem?.id ?? $0.id) == id }) {
                return IndexPath(row: idx, section: 0)
            }
            return nil
        }

        // MARK: - Table
        override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            items.count + (nextPage != nil ? 1 : 0)
        }

        override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            if nextPage != nil && indexPath.row == items.count {
                let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
                cell.textLabel?.text = "Load more…"
                cell.accessoryType = .none
                cell.accessoryView = nil
                return cell
            }

            let item = items[indexPath.row]
            let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
            cell.textLabel?.text = item.name

            // Always clear reused accessories up front
            cell.accessoryType = .none
            cell.accessoryView = nil

            let rowId = item.remoteItem?.id ?? item.id

            // If THIS row is the selected folder (leaf or non-leaf) → ALWAYS checkmark
            if rowId == selectedLeafId {
                cell.accessoryType = .checkmark
                return cell
            }

            // Which child is considered the "path child" for this parent → blue chevron (ancestor)
            let pathChildId = pathChildOverride[currentParentKey] ?? branchMap[currentParentKey]
            let isPathChildHere = (rowId == pathChildId)

            // Helper to set a chevron with the right tint
            func setChevron(on c: UITableViewCell, blue: Bool) {
                let iv = UIImageView(image: UIImage(systemName: "chevron.right"))
                iv.tintColor = blue ? .systemBlue : .label
                c.accessoryView = iv
            }

            // If we already know it's a leaf/non-leaf, configure deterministically
            if let isLeaf = cachedIsLeaf(item) {
                if !isLeaf {
                    setChevron(on: cell, blue: isPathChildHere)
                }
                return cell
            }

            // Unknown: show a chevron optimistically (tinted correctly), then probe and fix
            setChevron(on: cell, blue: isPathChildHere)
            probeLeafAndUpdateCell(for: item, at: indexPath)
            return cell
        }

        override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
            tableView.deselectRow(at: indexPath, animated: true)

            // "Load more…"
            if nextPage != nil && indexPath.row == items.count {
                Task { await loadPage(reset: false) }
                return
            }

            guard let manager else { return }
            let item = items[indexPath.row]
            guard let next = manager.nextContext(from: ctx, tapped: item) else { return }

            let tappedId = item.remoteItem?.id ?? item.id
            let wasSelected = (tappedId == selectedLeafId)

            // Previous blue chevron (path child) at THIS level → we will flip it to black
            let prevPathChildId = pathChildOverride[currentParentKey] ?? branchMap[currentParentKey]
            let prevPathIndex = prevPathChildId.flatMap { indexPathForItemId($0) }

            // Selecting a sibling should flip blue → black on the old path child.
            // Make the tapped one the new path child (works for leaf & non-leaf).
            pathChildOverride[currentParentKey] = tappedId

            // Helper to reload both tapped & previous path rows for tint/✓ updates
            func reloadRows(_ current: IndexPath, _ previous: IndexPath?) {
                var rows = [current]
                if let p = previous, p != current { rows.append(p) }
                tableView.reloadRows(at: rows, with: .none)
            }

            // If we already know leaf-ness, decide instantly
            if let isLeaf = leafCache[tappedId] {
                if isLeaf {
                    // Leaf: toggle ✓ on/off
                    if wasSelected {
                        // Turn off selection; also clear override so prior branch (if any) becomes active again
                        selectedLeafId = nil
                        workingSelectedChildId = nil
                        pathChildOverride[currentParentKey] = nil
                    } else {
                        selectedLeafId = tappedId
                        workingSelectedChildId = tappedId
                    }
                    reloadRows(indexPath, prevPathIndex)
                    return
                }

                // Non-leaf: mark as the selected folder (✓) before navigation
                selectedLeafId = tappedId
                workingSelectedChildId = tappedId
                reloadRows(indexPath, prevPathIndex)

                let vc = FolderPickerViewController(
                    manager: manager,
                    accessToken: token,
                    start: next,
                    branchMap: branchMap,
                    onPicked: onPicked
                )
                self.navigationController?.pushViewController(vc, animated: true)
                return
            }

            // Unknown leaf-ness → probe, update cache, then act
            Task { [weak self] in
                guard let self = self, let manager = self.manager else { return }
                do {
                    let (children, _) = try await manager.listChildren(token: self.token, ctx: next, next: nil)
                    let hasSubfolders = children.contains { $0.folder != nil || $0.remoteItem?.folder != nil }
                    let isLeaf = !hasSubfolders
                    self.leafCache[tappedId] = isLeaf

                    await MainActor.run {
                        if isLeaf {
                            if wasSelected {
                                self.selectedLeafId = nil
                                self.workingSelectedChildId = nil
                                self.pathChildOverride[self.currentParentKey] = nil
                            } else {
                                self.selectedLeafId = tappedId
                                self.workingSelectedChildId = tappedId
                            }
                            reloadRows(indexPath, prevPathIndex)
                        } else {
                            self.selectedLeafId = tappedId
                            self.workingSelectedChildId = tappedId
                            reloadRows(indexPath, prevPathIndex)

                            let vc = FolderPickerViewController(
                                manager: manager,
                                accessToken: self.token,
                                start: next,
                                branchMap: self.branchMap,
                                onPicked: self.onPicked
                            )
                            self.navigationController?.pushViewController(vc, animated: true)
                        }
                    }
                } catch {
                    // On error: treat like leaf (stay) and toggle selection
                    await MainActor.run {
                        if wasSelected {
                            self.selectedLeafId = nil
                            self.workingSelectedChildId = nil
                            self.pathChildOverride[self.currentParentKey] = nil
                        } else {
                            self.selectedLeafId = tappedId
                            self.workingSelectedChildId = tappedId
                        }
                        reloadRows(indexPath, prevPathIndex)
                    }
                }
            }
        }
    }
}
