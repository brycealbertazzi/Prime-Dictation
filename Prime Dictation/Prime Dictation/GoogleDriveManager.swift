//
//  GoogleDriveManager.swift
//  Prime Dictation
//
//  Created by Your Name on Date.
//  Copyright © 2025 Your Name. All rights reserved.
//

import Foundation
import UIKit
import GoogleSignIn
import GoogleAPIClientForREST_Drive
import ProgressHUD
import UniformTypeIdentifiers

// Mirroring the DropboxManager's internal types
struct GDSelection: Codable {
    let folderId: String
    let name: String
    let accountId: String?

    static var root: GDSelection {
        GDSelection(folderId: "root", name: "Google Drive", accountId: nil)
    }
}

fileprivate struct PickerFolder {
    let id: String
    let name: String
    var isChecked: Bool
    var hasChildren: Bool
    var isLeaf: Bool
}

// Custom view controller to handle the folder selection UI
class GDFolderPickerViewController: UITableViewController {
    let manager: GoogleDriveManager
    let service: GTLRDriveService
    let parentFolderId: String
    let onPicked: (GDSelection) -> Void
    fileprivate var folders: [PickerFolder] = []
    var checkedFolderId: String?
    fileprivate var foldersToExpand: [String: [PickerFolder]] = [:]

    init(manager: GoogleDriveManager, service: GTLRDriveService, parentFolderId: String, onPicked: @escaping (GDSelection) -> Void) {
        self.manager = manager
        self.service = service
        self.parentFolderId = parentFolderId
        self.onPicked = onPicked
        super.init(style: .plain)
        self.checkedFolderId = manager.persistedSelection?.folderId
        self.title = "Select Folder"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Use .value1 to allow a detail label in case we want to show extra info later
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "folderCell")
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(doneButtonTapped))
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            primaryAction: UIAction(title: "Sign Out") { [weak self] _ in
                guard let self = self else { return }
                ProgressHUD.animate("Signing out…")
                manager.SignOutAppOnly { success in
                    Task { @MainActor in
                        guard let settingsVC = self.manager.settingsViewController else {
                            print("Unable to find settings view controller on Google Drive signout")
                            return
                        }
                        if success {
                            settingsVC.UpdateSelectedDestinationUserDefaults(destination: Destination.none)
                            settingsVC.UpdateSelectedDestinationUI(destination: Destination.none)
                            self.dismiss(animated: true)
                            ProgressHUD.succeed("Signed out of Google Drive")
                        } else {
                            ProgressHUD.failed("Sign out failed")
                        }
                    }
                }
            }
        )
        fetchFolders()
    }
    
    @inline(__always)
    private func s(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue } // Correct way to handle NSNumber
        return "" // Default case for any other unhandled type
    }


    @objc private func doneButtonTapped() {
        // If a folder is checked, return that
        if let id = checkedFolderId,
           let f = folders.first(where: { $0.id == id }) {
            let selection = GDSelection(
                folderId: id,
                name: f.name,
                accountId: manager.currentAccountId
            )
            manager.updateSelectedFolder(selection)
            onPicked(selection)
            dismiss(animated: true)
            return
        }

        // Otherwise default to ROOT (My Drive)
        let rootSelection = GDSelection(
            folderId: GoogleDriveManager.googleDriveRootId,
            name: "Google Drive (root)",
            accountId: manager.currentAccountId
        )
        manager.updateSelectedFolder(rootSelection)
        onPicked(rootSelection)
        dismiss(animated: true)
    }

    @objc private func cancelButtonTapped() {
        dismiss(animated: true)
    }

    private func fetchFolders() {
        ProgressHUD.animate("Loading Google Drive folders…")
        manager.httpListFolders(parentId: parentFolderId) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                ProgressHUD.failed("Failed to load folders: \(error.localizedDescription)")
                self.dismiss(animated: true)
            case .success(let rows):
                self.folders = rows.map { (id, name) in
                    PickerFolder(id: id,
                                 name: name,
                                 isChecked: id == self.checkedFolderId,
                                 hasChildren: false,
                                 isLeaf: true)
                }
                self.tableView.reloadData()
                self.checkFoldersForChildren(parentFolderIds: rows.map { $0.id })
            }
            ProgressHUD.dismiss()
        }
    }

    private func checkFoldersForChildren(parentFolderIds: [String]) {
        guard !parentFolderIds.isEmpty else { return }
        manager.httpParentsHavingChildFolders(parentIDs: parentFolderIds) { [weak self] res in
            guard let self = self else { return }
            switch res {
            case .failure(let e):
                print("Children check error (HTTP): \(e.localizedDescription)")
            case .success(let parentsWithKids):
                var reload = false
                for i in 0..<self.folders.count {
                    let id = self.folders[i].id
                    if parentsWithKids.contains(id) {
                        self.folders[i].hasChildren = true
                        self.folders[i].isLeaf = false
                        reload = true
                    }
                }
                if reload { self.tableView.reloadData() }
            }
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        folders.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let reuse = "folderCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: reuse) ??
                   UITableViewCell(style: .default, reuseIdentifier: reuse)

        let folder = folders[indexPath.row]
        cell.textLabel?.text = folder.name
        cell.accessoryType = folder.id == checkedFolderId
            ? .checkmark
            : (folder.isLeaf ? .none : .disclosureIndicator)

        return cell
    }


    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let selectedFolder = folders[indexPath.row]

        if selectedFolder.isLeaf {
            if selectedFolder.id == checkedFolderId {
                // Uncheck
                checkedFolderId = nil
                manager.updateSelectedFolder(nil)
                tableView.reloadData()
            } else {
                // Select and notify caller immediately
                checkedFolderId = selectedFolder.id
                let selection = GDSelection(
                    folderId: selectedFolder.id,
                    name: selectedFolder.name,
                    accountId: manager.currentAccountId
                )
                manager.updateSelectedFolder(selection)
                tableView.reloadData()
            }
        } else {
            // Navigate deeper
            let newVC = GDFolderPickerViewController(
                manager: manager,
                service: service,
                parentFolderId: selectedFolder.id,
                onPicked: onPicked
            )
            navigationController?.pushViewController(newVC, animated: true)
        }
    }
}

// Main Manager Class
final class GoogleDriveManager: NSObject {

    // MARK: - Types

    enum AuthResult {
        case success
        case cancel
        case error(Error?, String?)
        case none
    }

    // MARK: - Keys / Constants

    private static let googleDriveSelectionKey = "googleDriveSelection"
    fileprivate static let googleDriveRootId = "root"

    // MARK: - Wiring

    weak var viewController: ViewController?
    weak var settingsViewController: SettingsViewController?
    private var recordingManager: RecordingManager?

    // Drive API Service
    private var driveService: GTLRDriveService?

    // User's Google Account ID
    var currentAccountId: String?

    // Auth Completion
    private var authCompletion: ((AuthResult) -> Void)?

    // MARK: - Persisted Data

    var persistedSelection: GDSelection? {
        didSet { saveSelection() }
    }

    override init() {
        super.init()
        loadSelection()
        GIDSignIn.sharedInstance.restorePreviousSignIn { [weak self] user, _ in
            guard let self = self else { return }
            self.ensureServiceFromCurrentUser()
        }
        
    }
    
    // MARK: - Preflight auth & Drive

    /// Refreshes Google tokens and performs a tiny Drive "ping" WITHOUT using GTLR,
    /// so we avoid any 3rd-party refresh parameter plumbing.
    /// Calls completion(true) only if both steps succeed.
    private func preflightAuthAndDrive(_ completion: @escaping (Bool) -> Void) {
        // 0) Must have a signed-in user
        guard GIDSignIn.sharedInstance.currentUser != nil else {
            completion(false); return
        }

        // 1) Refresh tokens OUTSIDE any UI lifecycle
        GIDSignIn.sharedInstance.currentUser?.refreshTokensIfNeeded { [weak self] _, refreshErr in
            guard let self = self else { return }
            if let refreshErr {
                print("Preflight refresh failed: \(refreshErr.localizedDescription)")
                DispatchQueue.main.async { completion(false) }
                return
            }

            // 2) Raw HTTP ping to Drive root (no GTLR, no GTMSessionFetcher)
            guard let token = GIDSignIn.sharedInstance.currentUser?.accessToken.tokenString,
                  let url = URL(string: "https://www.googleapis.com/drive/v3/files/root?fields=id") else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            // Be extra safe: ensure string-only headers
            // (URLSession ignores non-strings anyway, but belt & suspenders.)
            for (k, v) in req.allHTTPHeaderFields ?? [:] {
                if !(v is String) { req.setValue(String(describing: v), forHTTPHeaderField: k) }
            }

            URLSession.shared.dataTask(with: req) { _, resp, err in
                if let err {
                    print("Preflight HTTP ping failed: \(err.localizedDescription)")
                    DispatchQueue.main.async { completion(false) }
                    return
                }
                if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    // 3) Now it’s safe to let GTLR use the same refreshed token.
                    // Also ensure any lingering GTLR params are clean & string-only.
                    self.driveService?.additionalHTTPHeaders = [:]
                    self.driveService?.additionalURLQueryParameters = [:]
                    DispatchQueue.main.async { completion(true) }
                } else {
                    DispatchQueue.main.async { completion(false) }
                }
            }.resume()
        }
    }


    func attach(settingsViewController: SettingsViewController) {
        self.settingsViewController = settingsViewController
    }

    func attach(viewController: ViewController, recordingManager: RecordingManager) {
        self.viewController = viewController
        self.recordingManager = recordingManager
    }


    // MARK: - Auth
    // ✅ Your minimal, user-friendly scopes (no download permission):
    // - drive.file: create/manage only files your app creates/opens
    // - drive.metadata.readonly: list folders & file metadata without downloading content
    private let driveScopes = [
        "https://www.googleapis.com/auth/drive.file",
        "https://www.googleapis.com/auth/drive.metadata.readonly"
    ]

    private func ensureServiceFromCurrentUser() {
        guard let user = GIDSignIn.sharedInstance.currentUser else { return }
        if driveService == nil { driveService = GTLRDriveService() }
        driveService?.authorizer = user.fetcherAuthorizer
        currentAccountId = user.userID
    }

    private func hasAllDriveScopes(_ user: GIDGoogleUser?) -> Bool {
        guard let granted = user?.grantedScopes else { return false }
        let grantedSet = Set(granted)
        return Set(driveScopes).isSubset(of: grantedSet)
    }

    var isSignedIn: Bool {
        // If we already have a valid authorizer, we're good.
        if driveService?.authorizer?.canAuthorize == true,
           hasAllDriveScopes(GIDSignIn.sharedInstance.currentUser) {
            return true
        }

        // Otherwise, rebuild from the cached user (after a relaunch, etc.)
        ensureServiceFromCurrentUser()

        // Check again
        if driveService?.authorizer?.canAuthorize == true,
           hasAllDriveScopes(GIDSignIn.sharedInstance.currentUser) {
            return true
        }

        return false
    }

    @MainActor
    private func resetGoogleDriveState() {
        // Nuke any state that might contaminate a new session
        driveService?.additionalHTTPHeaders = [:]
        driveService?.additionalURLQueryParameters = [:]
        driveService = nil
        currentAccountId = nil
        persistedSelection = nil
    }

    @MainActor
    func SignOutAppOnly(completion: @escaping (Bool) -> Void) {
        GIDSignIn.sharedInstance.signOut()
        resetGoogleDriveState()
        completion(true)
    }

    @MainActor
    func SignOutAndRevoke(completion: @escaping (Bool) -> Void) {
        GIDSignIn.sharedInstance.disconnect { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.resetGoogleDriveState()
                completion(true)
            }
        }
    }
    
    /// Force any token-refresh parameter bags to be [String:String].
    /// Some third-party AuthSession layers stash numbers here → causes NSNumber→NSString crash.
    fileprivate func sanitizeAuthorizerParameters() {
        guard let authObj = driveService?.authorizer as? NSObject else { return }

        // Keys we've seen in the wild on various auth stacks
        let candidateKeys = [
            "additionalTokenRefreshParameters",
            "additionalParameters",
            "tokenRefreshParameters" // belt-and-suspenders
        ]

        for key in candidateKeys {
            let selGet = NSSelectorFromString(key)
            guard authObj.responds(to: selGet) else { continue }

            // Read current params (may be [AnyHashable: Any])
            let paramsAny = authObj.value(forKey: key) as Any?
            guard let dict = paramsAny as? [AnyHashable: Any] else { continue }

            // Debug: log any non-String values
            for (k, v) in dict {
                if !(v is String) {
                    print("⚠️ Non-string refresh param for \(key): \(k) = \(type(of: v)) -> \(v)")
                }
            }

            // Coerce to [String:String]
            var coerced = [String: String]()
            for (k, v) in dict {
                let ks = String(describing: k)
                if let s = v as? String { coerced[ks] = s }
                else { coerced[ks] = String(describing: v) } // NSNumber → its stringValue
            }

            // Write back
            authObj.setValue(coerced, forKey: key)
        }

        // Also ensure GTLR service bags are clean (string-only)
        driveService?.additionalHTTPHeaders = [:]
        driveService?.additionalURLQueryParameters = [:]
    }


    func openAuthorizationFlow(completion: @escaping (AuthResult) -> Void) {
        // Try to reuse existing session
        ensureServiceFromCurrentUser()

        if let user = GIDSignIn.sharedInstance.currentUser {
            if hasAllDriveScopes(user) {
                // Already signed in with needed scopes
                completion(.success)
                return
            } else if let presenter = settingsViewController {
                // Signed in but missing scopes → incremental auth prompts consent
                user.addScopes(driveScopes, presenting: presenter) { [weak self] result, error in
                    guard let self = self else { return }
                    if let error {
                        completion(.error(error, "Failed to grant Google Drive access."))
                        return
                    }
                    if let result, self.hasAllDriveScopes(result.user) {
                        self.setupDriveService(with: result)
                        ProgressHUD.succeed("Signed into Google Drive")
                        completion(.success)
                    } else {
                        completion(.cancel)
                    }
                }
                return
            }
        }

        // Fall back to interactive sign-in (first time or no cached user)
        guard let presenter = settingsViewController else { completion(.none); return }
        GIDSignIn.sharedInstance.signIn(withPresenting: presenter) { [weak self] signInResult, error in
            guard let self = self else { return }
            if let error = error {
                if (error as NSError).code == GIDSignInError.Code.canceled.rawValue { completion(.cancel) }
                else { completion(.error(error, "Google Sign-In failed: \(error.localizedDescription)")) }
                return
            }
            guard let signInResult = signInResult else { completion(.cancel); return }

            if self.hasAllDriveScopes(signInResult.user) {
                self.setupDriveService(with: signInResult)
                ProgressHUD.succeed("Signed into Google Drive")
                completion(.success)
            } else {
                // Request the Drive scopes incrementally to force the consent screen
                signInResult.user.addScopes(self.driveScopes, presenting: presenter) { [weak self] result, error in
                    guard let self = self else { return }
                    if let error {
                        completion(.error(error, "Failed to grant Google Drive access."))
                        return
                    }
                    if let result, self.hasAllDriveScopes(result.user) {
                        self.setupDriveService(with: result)
                        ProgressHUD.succeed("Signed into Google Drive")
                        completion(.success)
                    } else {
                        completion(.cancel)
                    }
                }
            }
        }
    }

    private func setupDriveService(with result: GIDSignInResult) {
        let driveService = GTLRDriveService()
        driveService.authorizer = result.user.fetcherAuthorizer
        self.driveService = driveService
        self.currentAccountId = result.user.userID
        
        sanitizeAuthorizerParameters()
    }
    
    // MARK: - RAW HTTP helpers for listing folders (bypass GTLR in picker)

    struct DriveFileDTO: Decodable { let id: String?; let name: String?; let parents: [String]? }
    struct DriveListDTO: Decodable { let files: [DriveFileDTO]? }
    struct DriveUploadResultDTO: Decodable { let id: String? }

    func withFreshAccessToken(_ done: @escaping (Result<String, Error>) -> Void) {
        guard let user = GIDSignIn.sharedInstance.currentUser else {
            return done(.failure(NSError(domain: "PrimeDictation", code: -1,
                                         userInfo: [NSLocalizedDescriptionKey: "Not signed in"])))
        }
        user.refreshTokensIfNeeded { _, err in
            if let err { return done(.failure(err)) }
            guard let token = GIDSignIn.sharedInstance.currentUser?.accessToken.tokenString else
            {
                return done(.failure(NSError(domain: "PrimeDictation", code: -2,
                                             userInfo: [NSLocalizedDescriptionKey: "Missing access token"])))
            }
            done(.success(token))
        }
    }

    func httpCheckFolderExists(folderId: String, completion: @escaping (Bool) -> Void) {
        if folderId == GoogleDriveManager.googleDriveRootId {
            return completion(true)
        }
        withFreshAccessToken { res in
            guard case .success(let token) = res else {
                return DispatchQueue.main.async { completion(false) }
            }
            var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(folderId)")!
            comps.queryItems = [
                URLQueryItem(name: "fields", value: "id"),
                URLQueryItem(name: "supportsAllDrives", value: "true")
            ]
            var req = URLRequest(url: comps.url!)
            req.httpMethod = "GET"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            URLSession.shared.dataTask(with: req) { _, resp, _ in
                let ok = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
                DispatchQueue.main.async { completion(ok) }
            }.resume()
        }
    }

    /// List subfolders of a parent via raw HTTP (no GTLR).
    func httpListFolders(parentId: String, completion: @escaping (Result<[(id: String, name: String)], Error>) -> Void) {
        withFreshAccessToken { res in
            switch res {
            case .failure(let e): completion(.failure(e))
            case .success(let token):
                var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
                comps.queryItems = [
                    URLQueryItem(name: "q", value: "'\(parentId)' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false"),
                    URLQueryItem(name: "fields", value: "files(id,name)"),
                    URLQueryItem(name: "supportsAllDrives", value: "true"),
                    URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
                    URLQueryItem(name: "spaces", value: "drive"),
                    URLQueryItem(name: "pageSize", value: "200")
                ]
                var req = URLRequest(url: comps.url!)
                req.httpMethod = "GET"
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

                URLSession.shared.dataTask(with: req) { data, resp, err in
                    if let err { return DispatchQueue.main.async { completion(.failure(err)) } }
                    guard let data,
                          let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                        return DispatchQueue.main.async {
                            completion(.failure(NSError(domain: "PrimeDictation", code: code,
                                                        userInfo: [NSLocalizedDescriptionKey: "Drive list failed (\(code))"])))
                        }
                    }
                    do {
                        let dto = try JSONDecoder().decode(DriveListDTO.self, from: data)
                        let rows: [(id: String, name: String)] = (dto.files ?? []).map { f in
                            let id = f.id ?? ""
                            let name = (f.name?.isEmpty == false) ? (f.name ?? "") : "(untitled)"
                            return (id: id, name: name)
                        }
                        DispatchQueue.main.async { completion(.success(rows)) }
                    } catch {
                        DispatchQueue.main.async { completion(.failure(error)) }
                    }
                }.resume()
            }
        }
    }

    /// For a set of parent IDs, returns which of them have at least one subfolder.
    func httpParentsHavingChildFolders(parentIDs: [String], completion: @escaping (Result<Set<String>, Error>) -> Void) {
        guard !parentIDs.isEmpty else { return completion(.success([])) }
        withFreshAccessToken { res in
            switch res {
            case .failure(let e): completion(.failure(e))
            case .success(let token):
                let ors = parentIDs.map { "'\($0)' in parents" }.joined(separator: " or ")
                var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
                comps.queryItems = [
                    URLQueryItem(name: "q", value: "(\(ors)) and mimeType = 'application/vnd.google-apps.folder' and trashed = false"),
                    URLQueryItem(name: "fields", value: "files(parents)"),
                    URLQueryItem(name: "supportsAllDrives", value: "true"),
                    URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
                    URLQueryItem(name: "spaces", value: "drive"),
                    URLQueryItem(name: "pageSize", value: "1000")
                ]
                var req = URLRequest(url: comps.url!)
                req.httpMethod = "GET"
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

                URLSession.shared.dataTask(with: req) { data, resp, err in
                    if let err { return DispatchQueue.main.async { completion(.failure(err)) } }
                    guard let data,
                          let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                        return DispatchQueue.main.async {
                            completion(.failure(NSError(domain: "PrimeDictation", code: code,
                                                        userInfo: [NSLocalizedDescriptionKey: "Drive children probe failed (\(code))"])))
                        }
                    }
                    do {
                        let dto = try JSONDecoder().decode(DriveListDTO.self, from: data)
                        let parents = Set((dto.files ?? []).flatMap { $0.parents ?? [] })
                        DispatchQueue.main.async { completion(.success(parents)) }
                    } catch {
                        DispatchQueue.main.async { completion(.failure(error)) }
                    }
                }.resume()
            }
        }
    }

    // Resumable upload (safe for larger audio files)
    func httpResumableUpload(fileURL: URL,
                             destFolderId: String?,
                             mimeType: String,
                             fileName: String,
                             completion: @escaping (Result<String, Error>) -> Void) {
        withFreshAccessToken { res in
            guard case .success(let token) = res else {
                if case .failure(let e) = res { completion(.failure(e)) }
                return
            }

            // 1) Start session
            var start = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable")!)
            start.httpMethod = "POST"
            start.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            start.setValue(mimeType, forHTTPHeaderField: "X-Upload-Content-Type")

            var meta: [String: Any] = ["name": fileName]
            if let dest = destFolderId, dest != GoogleDriveManager.googleDriveRootId {
                meta["parents"] = [dest]
            }
            let metaData = try! JSONSerialization.data(withJSONObject: meta, options: [])
            start.httpBody = metaData

            URLSession.shared.dataTask(with: start) { _, resp, err in
                if let err { return DispatchQueue.main.async { completion(.failure(err)) } }
                guard let http = resp as? HTTPURLResponse,
                      (200..<400).contains(http.statusCode) else {
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                    return DispatchQueue.main.async {
                        completion(.failure(NSError(domain: "PrimeDictation", code: code,
                                                    userInfo: [NSLocalizedDescriptionKey: "Failed to start upload session (\(code))"])))
                    }
                }

                // Case-insensitive Location header
                let locationHeader = http.allHeaderFields.first {
                    (String(describing: $0.key)).caseInsensitiveCompare("Location") == .orderedSame
                }?.value as? String

                guard let location = locationHeader, let uploadURL = URL(string: location) else {
                    return DispatchQueue.main.async {
                        completion(.failure(NSError(domain: "PrimeDictation", code: -3,
                                                    userInfo: [NSLocalizedDescriptionKey: "Missing upload URL"])))
                    }
                }

                // 2) Upload content
                var put = URLRequest(url: uploadURL)
                put.httpMethod = "PUT"
                put.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                put.setValue(mimeType, forHTTPHeaderField: "Content-Type")

                let task = URLSession.shared.uploadTask(with: put, fromFile: fileURL) { data, resp2, err2 in
                    if let err2 { return DispatchQueue.main.async { completion(.failure(err2)) } }
                    guard let http2 = resp2 as? HTTPURLResponse, (200..<300).contains(http2.statusCode) else {
                        let code = (resp2 as? HTTPURLResponse)?.statusCode ?? -1
                        return DispatchQueue.main.async {
                            completion(.failure(NSError(domain: "PrimeDictation", code: code,
                                                        userInfo: [NSLocalizedDescriptionKey: "Upload failed (\(code))"])))
                        }
                    }
                    if let data, let dto = try? JSONDecoder().decode(DriveUploadResultDTO.self, from: data),
                       let id = dto.id {
                        DispatchQueue.main.async { completion(.success(id)) }
                    } else {
                        DispatchQueue.main.async { completion(.success("")) } // success, no body
                    }
                }
                task.resume()
            }.resume()
        }
    }



    // MARK: - Present folder picker

    @MainActor
    func presentGoogleDriveFolderPicker(onPicked: ((GDSelection) -> Void)? = nil) {

        func presentPicker(_ service: GTLRDriveService) {
            let vc = GDFolderPickerViewController(
                manager: self,
                service: service,
                parentFolderId: GoogleDriveManager.googleDriveRootId,
                onPicked: { [weak self] selection in
                    self?.updateSelectedFolder(selection)
                    onPicked?(selection)
                }
            )
            let nav = UINavigationController(rootViewController: vc)
            nav.modalPresentationStyle = .formSheet
            settingsViewController?.present(nav, animated: true) { ProgressHUD.dismiss() }
        }

        let proceed: () -> Void = { [weak self] in
            guard let self = self, let service = self.driveService else {
                self?.sanitizeAuthorizerParameters()
                ProgressHUD.failed("Google Drive client unavailable"); return
            }
            // 👇 Critical: preflight outside the picker UI
            self.preflightAuthAndDrive { ok in
                if ok { presentPicker(service) }
                else { ProgressHUD.failed("Google Drive auth failed. Please try again.") }
            }
        }

        if isSignedIn, driveService != nil {
            proceed()
        } else {
            openAuthorizationFlow { res in
                if case .success = res { proceed() }
            }
        }
    }

    // MARK: - Upload
    func SendToGoogleDrive(url: URL) {
        guard let viewController else { return }
        guard driveService != nil else {
            viewController.displayAlert(title: "Google Drive not signed in", message: "Please sign in and select a folder in Settings.")
            return
        }

        let destFolderId = persistedSelection?.folderId ?? GoogleDriveManager.googleDriveRootId

        viewController.ShowSendingUI()
        ProgressHUD.animate("Sending...", .triangleDotShift)

        httpCheckFolderExists(folderId: destFolderId) { [weak self] exists in
            guard let self = self, let viewController = self.viewController else { return }

            guard exists else {
                ProgressHUD.failed("Destination folder not found")
                viewController.HideSendingUI()
                viewController.displayAlert(title: "Folder Not Found", message: "Please select a new destination in Settings.")
                self.persistedSelection = nil
                return
            }

            guard let recordingManager = self.recordingManager else {
                ProgressHUD.failed("No recording to send")
                viewController.HideSendingUI()
                return
            }
            let fileName = recordingManager.toggledRecordingName + "." + recordingManager.destinationRecordingExtension
            let mimeType: String = {
                if let ext = url.pathExtension.isEmpty ? nil : url.pathExtension,
                   let ut = UTType(filenameExtension: ext),
                   let preferred = ut.preferredMIMEType { return preferred }
                return "application/octet-stream"
            }()

            self.httpResumableUpload(fileURL: url,
                                     destFolderId: destFolderId,
                                     mimeType: mimeType,
                                     fileName: fileName) { result in
                switch result {
                case .success: ProgressHUD.succeed("Sent to Google Drive!")
                case .failure(let error): ProgressHUD.failed("Upload failed: \(error.localizedDescription)")
                }
                viewController.HideSendingUI()
            }
        }
    }



    private func checkFolderExists(folderId: String, service: GTLRDriveService, completion: @escaping (Bool) -> Void) {
        if folderId == GoogleDriveManager.googleDriveRootId {
            DispatchQueue.main.async { completion(true) } // Root always exists
            return
        }

        let query = GTLRDriveQuery_FilesGet.query(withFileId: folderId)
        query.fields = "id"
        service.executeQuery(query) { (_, file, error) in
            DispatchQueue.main.async {
                completion(file != nil && error == nil)
            }
        }
    }

    private func performUpload(
        fileURL: URL,
        destinationFolderId: String,
        service: GTLRDriveService,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let recordingManager else {
            completion(.failure(NSError(domain: "PrimeDictation", code: -1,
                                        userInfo: [NSLocalizedDescriptionKey: "Missing recording manager"])))
            return
        }

        let recordingName = recordingManager.toggledRecordingName + "." + recordingManager.destinationRecordingExtension

        let mimeType: String
        if let ext = fileURL.pathExtension.isEmpty ? nil : fileURL.pathExtension,
           let utType = UTType(filenameExtension: ext),
           let preferred = utType.preferredMIMEType {
            mimeType = preferred
        } else { mimeType = "application/octet-stream" }

        let file = GTLRDrive_File()
        file.name = recordingName
        if destinationFolderId != GoogleDriveManager.googleDriveRootId {
            file.parents = [destinationFolderId]       // normal folder
        } else {
            file.parents = nil                         // root upload
        }

        let uploadParameters = GTLRUploadParameters(fileURL: fileURL, mimeType: mimeType)
        let query = GTLRDriveQuery_FilesCreate.query(withObject: file, uploadParameters: uploadParameters)

        service.executeQuery(query) { _, _, error in
            DispatchQueue.main.async { error == nil ? completion(.success(())) : completion(.failure(error!)) }
        }
    }


    // MARK: - Persistence

    func loadSelection() {
        guard let data = UserDefaults.standard.data(forKey: GoogleDriveManager.googleDriveSelectionKey) else { return }
        persistedSelection = try? JSONDecoder().decode(GDSelection.self, from: data)
    }

    func saveSelection() {
        if let selection = persistedSelection {
            if let encoded = try? JSONEncoder().encode(selection) {
                UserDefaults.standard.set(encoded, forKey: GoogleDriveManager.googleDriveSelectionKey)
            }
        } else {
            UserDefaults.standard.removeObject(forKey: GoogleDriveManager.googleDriveSelectionKey)
        }
    }

    func updateSelectedFolder(_ selection: GDSelection?) {
        // Only update if the selected folder is in the current account
        if let selection = selection, selection.accountId == currentAccountId {
            persistedSelection = selection
        } else if selection == nil {
            persistedSelection = nil
        }
    }

    // MARK: - Display Helpers

    func getSelectionDisplayString() -> String {
        if let sel = persistedSelection {
            return sel.folderId == GoogleDriveManager.googleDriveRootId ? "Google Drive (root)" : sel.name
        } else {
            return "Google Drive (root)"
        }
    }
    
}
