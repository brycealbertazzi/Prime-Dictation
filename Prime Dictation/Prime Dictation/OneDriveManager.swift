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
                    DispatchQueue.main.async { completion(.success) }
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

    // MARK: - Public: upload entry point (uses selected folder or default)
    func SendToOneDrive(url: URL, preferredFileName: String? = nil, progress: ((Double) -> Void)? = nil) {
        Task { [weak self] in
            guard let self = self else { return }
            guard let viewController = viewController else { return }

            await ProgressHUD.animate("Sending...", .triangleDotShift)
            await viewController.ShowSendingUI()
            defer { Task { @MainActor in viewController.HideSendingUI() } }

            do {
                let token = try await self.getAccessTokenSilently()
                let target = try await self.resolveSelectionOrDefault(token: token) // user choice or "/Prime Dictation"
                let fileName = preferredFileName ?? url.lastPathComponent
                _ = try await self.uploadRecording(accessToken: token,
                                                   fileURL: url,
                                                   fileName: fileName,
                                                   to: target,
                                                   progress: progress)
                await MainActor.run {
                    ProgressHUD.succeed("Recording was sent to OneDrive")
                }
            } catch {
                await MainActor.run {
                    ProgressHUD.dismiss()
                    viewController.displayAlert(title: "Recording send failed", message: "Your selected folder may have been deleted or you lost connection.", handler: {
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

        /// Map of { parentId (or RootKey) -> childId } along the saved/active destination path.
        private var branchMap: [String:String]

        /// Working selection at THIS level (what shows the ✓ on rows in this list)
        private var workingSelectedChildId: String?

        /// Track previously-checked row so we can reload it when selection changes
        private var selectedIndexPath: IndexPath?

        /// Leaf cache to avoid async in cellForRow + reduce flicker
        private var leafCache: [String: Bool] = [:] // key: canonical item id → true if NO subfolders

        /// Initial selected child for this level from branchMap (if any)
        private func initialSelectedChildId() -> String? {
            let parentKey = (ctx.itemId == "root") ? OneDriveManager.rootKey : ctx.itemId
            return branchMap[parentKey]
        }

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
                    // If a child row is selected → pick it; otherwise pick the current folder (ctx)
                    let chosen = workingSelectedChildId
                        .flatMap { OneDriveSelection(driveId: self.ctx.driveId, itemId: $0) }
                        ?? OneDriveSelection(driveId: ctx.driveId, itemId: ctx.itemId)
                    onPicked(chosen)
                    self.dismiss(animated: true)
                }
            )
            tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
            Task { await loadPage(reset: true) }
            ProgressHUD.dismiss()
        }

        private func setTitleFor(ctx: DriveContext) {
            if ctx.itemId == "root" { self.title = "OneDrive" }
            else { self.title = ctx.name ?? "OneDrive Folder" }
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
                if let selId = workingSelectedChildId,
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
                    self.leafCache[self.canonicalId(for: item)] = isLeaf

                    await MainActor.run {
                        // If the row is still visible and not the selected row, update accessory
                        if let currentCell = self.tableView.cellForRow(at: indexPath),
                           !self.itemMatchesSelected(item, selectedId: self.workingSelectedChildId) {
                            currentCell.accessoryType = isLeaf ? .none : .disclosureIndicator
                        }
                    }
                } catch {
                    // Leave as unknown; keep current accessory to avoid flicker
                }
            }
        }

        // Matches either the visible row id or the shortcut's target id
        private func itemMatchesSelected(_ item: PickerDriveItem, selectedId: String?) -> Bool {
            guard let selectedId else { return false }
            return (item.remoteItem?.id ?? item.id) == selectedId
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
                return cell
            }

            let item = items[indexPath.row]
            let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
            cell.textLabel?.text = item.name

            // If row is currently selected at THIS level → show ✓ and stop.
            if itemMatchesSelected(item, selectedId: workingSelectedChildId) {
                cell.accessoryType = .checkmark
                return cell
            }

            // Use cache if we know leaf-ness; otherwise show stable default (no chevron), then probe.
            if let isLeaf = cachedIsLeaf(item) {
                cell.accessoryType = isLeaf ? .none : .disclosureIndicator
            } else {
                cell.accessoryType = .none
                probeLeafAndUpdateCell(for: item, at: indexPath)
            }

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
            let wasSelected = (tappedId == workingSelectedChildId)

            // Move checkmark to tapped row immediately (old sibling loses it).
            let prev = selectedIndexPath ?? (workingSelectedChildId.flatMap { indexPathForItemId($0) })
            workingSelectedChildId = tappedId
            selectedIndexPath = indexPath

            var rows = [indexPath]
            if let p = prev, p != indexPath { rows.append(p) }
            tableView.reloadRows(at: rows, with: .none)

            // Decide navigation: if leaf → DO NOT navigate; if non-leaf → navigate.
            if let isLeaf = leafCache[tappedId] {
                if isLeaf {
                    // Toggle OFF if tapping the already-selected row
                    if wasSelected {
                        let prev = selectedIndexPath ?? indexPathForItemId(tappedId)
                        workingSelectedChildId = nil
                        selectedIndexPath = nil

                        var rows = [indexPath]
                        if let p = prev, p != indexPath { rows.append(p) }
                        tableView.reloadRows(at: rows, with: .none)
                    }
                    return
                }
                let vc = FolderPickerViewController(
                    manager: manager,
                    accessToken: token,
                    start: next,
                    branchMap: branchMap,
                    onPicked: onPicked
                )
                self.navigationController?.pushViewController(vc, animated: true)
            } else {
                // Unknown → probe, update cache, then navigate only if NON-leaf
                Task { [weak self] in
                    guard let self = self, let manager = self.manager else { return }
                    do {
                        let (children, _) = try await manager.listChildren(token: token, ctx: next, next: nil)
                        let hasSubfolders = children.contains { $0.folder != nil || $0.remoteItem?.folder != nil }
                        let isLeaf = !hasSubfolders
                        self.leafCache[tappedId] = isLeaf
                        if !isLeaf {
                            await MainActor.run {
                                let vc = FolderPickerViewController(
                                    manager: manager,
                                    accessToken: token,
                                    start: next,
                                    branchMap: self.branchMap,
                                    onPicked: self.onPicked
                                )
                                self.navigationController?.pushViewController(vc, animated: true)
                            }
                        }
                    } catch {
                        // On error: treat like leaf (stay)
                    }
                }
            }
        }
    }
}
