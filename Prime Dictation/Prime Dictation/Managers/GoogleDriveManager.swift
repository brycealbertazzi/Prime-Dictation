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

class GDFolderPickerViewController: UITableViewController {
    let manager: GoogleDriveManager
    let service: GTLRDriveService
    let parentFolderId: String
    let onPicked: (GDSelection) -> Void

    // Current-level semantics
    private var selectedId: String          // leaf id or currentFolderId (parent)
    private var items: [PickerFolder] = []
    private var rowHeight: CGFloat = 56.0

    // Optional header showing last saved selection (read-only)
    private lazy var headerView: UIView = buildLastSelectedHeader()

    init(manager: GoogleDriveManager,
         service: GTLRDriveService,
         parentFolderId: String,
         onPicked: @escaping (GDSelection) -> Void) {
        self.manager = manager
        self.service = service
        self.parentFolderId = parentFolderId
        self.onPicked = onPicked
        // Default: Done is valid immediately → parent "selected"
        self.selectedId = parentFolderId
        super.init(style: .insetGrouped)
        self.title = "Google Drive"  // refined in setTitleFromParentId()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Done (enabled initially)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Done",
            style: .done,
            target: self,
            action: #selector(doneButtonTapped)
        )
        navigationItem.rightBarButtonItem?.isEnabled = true

        // Sign Out (unchanged)
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            primaryAction: UIAction(title: "Sign Out") { [weak self] _ in
                guard let self = self else { return }
                ProgressHUD.animate("Signing out…")
                self.manager.SignOutAppOnly { success in
                    Task { @MainActor in
                        guard let settingsVC = self.manager.settingsViewController else { return }
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

        // No footer (per your note)
        tableView.tableFooterView = nil

        // Header: “Last selected: …” (optional, harmless if none)
        tableView.tableHeaderView = headerView

        // Row visuals
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "folderCell")
        tableView.rowHeight = rowHeight
        tableView.estimatedRowHeight = rowHeight

        setTitleFromParentId()
        fetchFolders()
        ProgressHUD.dismiss()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Keep header width in sync
        if let header = tableView.tableHeaderView, header === headerView {
            let targetWidth = tableView.bounds.width
            if abs(header.frame.width - targetWidth) > 0.5 {
                header.frame.size.width = targetWidth
                tableView.tableHeaderView = header
            }
        }
    }

    // MARK: - Header “Last selected”
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

        if let sel = manager.persistedSelection {
            if sel.folderId == GoogleDriveManager.googleDriveRootId {
                label.text = "Last selected: Root"
            } else {
                label.text = "Last selected: \(sel.name)"
            }
        } else {
            label.text = "Last selected: None"
        }
        return v
    }

    // MARK: - Title = current folder name
    private func setTitleFromParentId() {
        if parentFolderId == GoogleDriveManager.googleDriveRootId {
            self.title = "Google Drive"
            return
        }
        manager.httpGetFileName(fileId: parentFolderId) { [weak self] res in
            guard let self = self else { return }
            switch res {
            case .success(let name):
                self.title = name.isEmpty ? "Google Drive" : name
            case .failure:
                self.title = "Google Drive"
            }
        }
    }

    // MARK: - Done
    @objc private func doneButtonTapped() {
        let idToUse = selectedId // leaf or parent

        if idToUse == GoogleDriveManager.googleDriveRootId {
            let sel = GDSelection(folderId: idToUse, name: "Root", accountId: manager.currentAccountId)
            manager.updateSelectedFolder(sel)
            onPicked(sel)
            dismiss(animated: true)
            ProgressHUD.succeed("Root selected")
            return
        }

        // Try to show a friendly name
        if let match = items.first(where: { $0.id == idToUse }) {
            let sel = GDSelection(folderId: idToUse, name: match.name, accountId: manager.currentAccountId)
            manager.updateSelectedFolder(sel)
            onPicked(sel)
            dismiss(animated: true)
            ProgressHUD.succeed("\(match.name) selected")
            return
        }

        // Parent not in items → fetch its name
        manager.httpGetFileName(fileId: idToUse) { [weak self] result in
            guard let self = self else { return }
            let name: String
            switch result {
            case .success(let n): name = (idToUse == GoogleDriveManager.googleDriveRootId) ? "Root" : (n.isEmpty ? "(untitled)" : n)
            case .failure:        name = (idToUse == GoogleDriveManager.googleDriveRootId) ? "Root" : "(untitled)"
            }
            let sel = GDSelection(folderId: idToUse, name: name, accountId: self.manager.currentAccountId)
            self.manager.updateSelectedFolder(sel)
            self.onPicked(sel)
            self.dismiss(animated: true)
            ProgressHUD.succeed("\(name) selected")
        }
    }

    // MARK: - Data loading
    private func fetchFolders() {
        ProgressHUD.animate("Loading Google Drive folders…")
        manager.httpListFolders(parentId: parentFolderId) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                ProgressHUD.failed("Failed to load folders: \(error.localizedDescription)")
                self.dismiss(animated: true)

            case .success(let rows):
                self.items = rows.map { (id, name) in
                    PickerFolder(id: id,
                                 name: name,
                                 isChecked: false,
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
                print("Children check error: \(e.localizedDescription)")
            case .success(let parentsWithKids):
                var reload = false
                for i in 0..<self.items.count {
                    let id = self.items[i].id
                    if parentsWithKids.contains(id) {
                        self.items[i].hasChildren = true
                        self.items[i].isLeaf = false
                        reload = true
                    }
                }
                if reload { self.tableView.reloadData() }
            }
        }
    }

    // MARK: - Table
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let reuse = "folderCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: reuse) ??
                   UITableViewCell(style: .default, reuseIdentifier: reuse)

        let folder = items[indexPath.row]

        // Left folder icon (SF Symbols)
        let symConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        cell.imageView?.preferredSymbolConfiguration = symConfig
        cell.imageView?.image = UIImage(systemName: "folder")
        cell.imageView?.tintColor = .label

        // Title
        cell.textLabel?.text = folder.name
        cell.textLabel?.font = .systemFont(ofSize: 16)

        // Clear accessories
        cell.accessoryType = .none
        cell.accessoryView = nil

        // ✓ only if a child leaf is selected (never for parent/current)
        if selectedId != parentFolderId, folder.id == selectedId {
            cell.accessoryType = .checkmark
            return cell
        }

        // Black chevron for non-leaf folders
        if !folder.isLeaf {
            let iv = UIImageView(image: UIImage(systemName: "chevron.right"))
            iv.tintColor = .label
            cell.accessoryView = iv
        }

        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        let tapped = items[indexPath.row]

        if tapped.isLeaf {
            let previousSelected = selectedId

            if selectedId == tapped.id {
                // 🔁 Your rule: toggling off sets selection to PARENT
                selectedId = parentFolderId
            } else {
                selectedId = tapped.id
            }

            var rows: [IndexPath] = [indexPath]
            if let prev = previousSelected as String?,
               prev != tapped.id,
               prev != parentFolderId,
               let prevIdx = items.firstIndex(where: { $0.id == prev }) {
                rows.append(IndexPath(row: prevIdx, section: 0))
               }
            tableView.reloadRows(at: rows, with: .none)
            return
        }

        // Non-leaf → navigate deeper (no ✓ here)
        let nextVC = GDFolderPickerViewController(
            manager: manager,
            service: service,
            parentFolderId: tapped.id,
            onPicked: onPicked
        )
        navigationController?.pushViewController(nextVC, animated: true)
    }
}


// Main Manager Class
final class GoogleDriveManager: NSObject {

    // MARK: - Types

    enum AuthResult {
        case success
        case alreadyAuthenticated
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

            for (k, v) in req.allHTTPHeaderFields ?? [:] {
                req.setValue(String(describing: v), forHTTPHeaderField: k)
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
                completion(.alreadyAuthenticated)
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

    func httpGetParents(fileId: String, completion: @escaping (Result<[String], Error>) -> Void) {
        if fileId == GoogleDriveManager.googleDriveRootId {
            return completion(.success([]))
        }
        withFreshAccessToken { res in
            switch res {
            case .failure(let e): completion(.failure(e))
            case .success(let token):
                var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(fileId)")!
                comps.queryItems = [
                    URLQueryItem(name: "fields", value: "parents"),
                    URLQueryItem(name: "supportsAllDrives", value: "true")
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
                                                        userInfo: [NSLocalizedDescriptionKey: "Parents fetch failed (\(code))"])))
                        }
                    }
                    struct ParentsDTO: Decodable { let parents: [String]? }
                    do {
                        let dto = try JSONDecoder().decode(ParentsDTO.self, from: data)
                        DispatchQueue.main.async { completion(.success(dto.parents ?? [])) }
                    } catch {
                        DispatchQueue.main.async { completion(.failure(error)) }
                    }
                }.resume()
            }
        }
    }
    
    // Fetch a file/folder name by id (root handled specially)
    func httpGetFileName(fileId: String, completion: @escaping (Result<String, Error>) -> Void) {
        if fileId == GoogleDriveManager.googleDriveRootId {
            return completion(.success("Google Drive (root)"))
        }
        withFreshAccessToken { res in
            switch res {
            case .failure(let e): completion(.failure(e))
            case .success(let token):
                var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(fileId)")!
                comps.queryItems = [
                    URLQueryItem(name: "fields", value: "name"),
                    URLQueryItem(name: "supportsAllDrives", value: "true")
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
                                                        userInfo: [NSLocalizedDescriptionKey: "Name fetch failed (\(code))"])))
                        }
                    }
                    struct NameDTO: Decodable { let name: String? }
                    do {
                        let dto = try JSONDecoder().decode(NameDTO.self, from: data)
                        DispatchQueue.main.async { completion(.success(dto.name ?? "(untitled)")) }
                    } catch {
                        DispatchQueue.main.async { completion(.failure(error)) }
                    }
                }.resume()
            }
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
    func SendToGoogleDrive(hasTranscription: Bool) {
        guard let viewController = self.viewController else { return }
        guard let recordingManager = self.recordingManager else {
            viewController.displayAlert(title: "No recording to send", message: "Please record first.")
            return
        }
        guard driveService != nil else {
            viewController.displayAlert(title: "Google Drive not signed in", message: "Please sign in and select a folder in Settings.")
            return
        }

        let destFolderId = persistedSelection?.folderId ?? GoogleDriveManager.googleDriveRootId

        // Build local file URLs & names
        let baseName   = recordingManager.toggledAudioTranscriptionObject.fileName
        let dir        = recordingManager.GetDirectory()
        let audioURL   = dir.appendingPathComponent(baseName).appendingPathExtension(recordingManager.audioRecordingExtension)
        let transcriptURL = dir.appendingPathComponent(baseName).appendingPathExtension(recordingManager.transcriptionRecordingExtension)

        let audioFileName = "\(baseName).\(recordingManager.audioRecordingExtension)"
        let txtFileName   = "\(baseName).\(recordingManager.transcriptionRecordingExtension)"

        // Simple MIME helpers
        func mimeType(for url: URL, fallback: String) -> String {
            if let ut = UTType(filenameExtension: url.pathExtension),
               let preferred = ut.preferredMIMEType {
                return preferred
            }
            return fallback
        }
        let audioMime = mimeType(for: audioURL, fallback: "application/octet-stream")
        let txtMime   = "text/plain"

        viewController.DisableUI()
        ProgressHUD.animate("Sending...", .triangleDotShift)

        // 0) Ensure destination folder still exists
        httpCheckFolderExists(folderId: destFolderId) { [weak self] exists in
            guard let self = self, let viewController = self.viewController else { return }

            guard exists else {
                ProgressHUD.failed("Destination folder not found")
                viewController.EnableUI()
                viewController.displayAlert(title: "Folder Not Found", message: "Please select a new destination in Settings.")
                self.persistedSelection = nil
                return
            }

            // 1) Upload audio first
            self.httpResumableUpload(fileURL: audioURL,
                                     destFolderId: destFolderId,
                                     mimeType: audioMime,
                                     fileName: audioFileName) { result in
                switch result {
                case .failure(let error):
                    DispatchQueue.main.async {
                        ProgressHUD.failed("Upload failed: \(error.localizedDescription)")
                        viewController.EnableUI()
                    }

                case .success:
                    // 2) Optionally upload transcript
                    let shouldSendTranscript =
                        recordingManager.toggledAudioTranscriptionObject.hasTranscription &&
                        hasTranscription &&
                        FileManager.default.fileExists(atPath: transcriptURL.path)

                    guard shouldSendTranscript else {
                        DispatchQueue.main.async {
                            ProgressHUD.succeed("Recording sent to Google Drive")
                            viewController.EnableUI()
                        }
                        return
                    }

                    self.httpResumableUpload(fileURL: transcriptURL,
                                             destFolderId: destFolderId,
                                             mimeType: txtMime,
                                             fileName: txtFileName) { result2 in
                        DispatchQueue.main.async {
                            switch result2 {
                            case .success:
                                ProgressHUD.succeed("Recording & transcript sent to Google Drive")
                            case .failure(let e):
                                // Audio is already uploaded; inform transcript failure lightly
                                ProgressHUD.dismiss()
                                viewController.displayAlert(
                                    title: "Transcript upload failed",
                                    message: e.localizedDescription,
                                    handler: { ProgressHUD.failed("Transcript failed") }
                                )
                            }
                            viewController.EnableUI()
                        }
                    }
                }
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

        let recordingName = recordingManager.toggledAudioTranscriptionObject.fileName + "." + recordingManager.audioRecordingExtension

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
