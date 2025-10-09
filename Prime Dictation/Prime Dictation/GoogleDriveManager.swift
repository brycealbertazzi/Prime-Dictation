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
        if let n = any as? NSNumber { return n.stringValue }
        if let sOpt = any as? String? { return sOpt ?? "" }
        return any.map { String(describing: $0) } ?? ""
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

        let query = GTLRDriveQuery_FilesList.query()
        query.q = "'\(parentFolderId)' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
        query.fields = "files(id,name,mimeType),nextPageToken"
        query.supportsAllDrives = true
        query.includeItemsFromAllDrives = true
        query.spaces = "drive"
//        query.pageSize = 200

        service.executeQuery(query) { [weak self] (_, result, error) in
            guard let self = self else { return }
            defer { ProgressHUD.dismiss() }

            if let error = error {
                ProgressHUD.failed("Failed to load folders: \(error.localizedDescription)")
                self.dismiss(animated: true)
                return
            }

            guard let fileList = result as? GTLRDrive_FileList else {
                self.folders = []
                self.tableView.reloadData()
                return
            }

            // ✅ Map over the DRIVE ITEMS, not self.folders
            let items: [GTLRDrive_File] = fileList.files ?? []

            self.folders = items.map { file in
                let id = self.s(file.identifier)
                let name = self.s(file.name)
                return PickerFolder(
                    id: id,
                    name: name.isEmpty ? "(untitled)" : name,
                    isChecked: id == self.checkedFolderId,
                    hasChildren: false,
                    isLeaf: true
                )
            }

            self.tableView.reloadData()
            self.checkFoldersForChildren(parentFolders: items)
        }
    }


    private func checkFoldersForChildren(parentFolders: [GTLRDrive_File]) {
        let parentIDs = parentFolders.map { s($0.identifier) }.filter { !$0.isEmpty }
        guard !parentIDs.isEmpty else { return }

        let parentSubqueries = parentIDs.map { "'\($0)' in parents" }
        let combinedQuery = parentSubqueries.joined(separator: " or ")

        let childrenQuery = GTLRDriveQuery_FilesList.query()
        childrenQuery.q = "(\(combinedQuery)) and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
        childrenQuery.fields = "files(id,parents),nextPageToken"
        childrenQuery.supportsAllDrives = true
        childrenQuery.includeItemsFromAllDrives = true
        childrenQuery.spaces = "drive"
//        childrenQuery.pageSize = 200

        service.executeQuery(childrenQuery) { [weak self] (_, result, error) in
            guard let self = self else { return }
            if let error = error {
                print("Children check error: \(error.localizedDescription)")
                return
            }

            guard let list = result as? GTLRDrive_FileList else { return }
            let children: [GTLRDrive_File] = list.files ?? []
            let parentIdsWithChildren = Set(children.flatMap { $0.parents ?? [] })

            var needsReload = false
            for i in 0..<self.folders.count {
                let id = self.folders[i].id
                if parentIdsWithChildren.contains(id) {
                    self.folders[i].hasChildren = true
                    self.folders[i].isLeaf = false
                    needsReload = true
                }
            }
            if needsReload { DispatchQueue.main.async { self.tableView.reloadData() } }
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
                onPicked(selection)                 // 🔔 notify your SelectFolderButton closure
                dismiss(animated: true)             // close the picker
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
                self?.resetGoogleDriveState()
                completion(true)
            }
        }
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
            settingsViewController?.present(nav, animated: true) {
                ProgressHUD.dismiss()   // hide "Opening file picker"
            }
        }

        // Ensure we’re signed in
        let go: () -> Void = { [weak self] in
            guard let self = self, let service = self.driveService else {
                print("Google Drive client unavailable"); return
            }
            // Preflight: refresh tokens so presenting the VC won’t cause a refresh
            GIDSignIn.sharedInstance.currentUser?.refreshTokensIfNeeded { _, err in
                Task { @MainActor in
                    if let err { print("Google auth refresh failed: \(err.localizedDescription)") }
                    presentPicker(service)
                }
            }
        }

        if isSignedIn, driveService != nil {
            go()
        } else {
            openAuthorizationFlow { res in
                if case .success = res { go() }
            }
        }
    }

    // MARK: - Upload

    func SendToGoogleDrive(url: URL) {
        guard let viewController else { return }
        guard let service = driveService else {
            viewController.displayAlert(title: "Google Drive not signed in", message: "Please sign in and select a folder in Settings.")
            return
        }

        // 👇 If no selection, default to root
        let destFolderId = persistedSelection?.folderId ?? GoogleDriveManager.googleDriveRootId

        viewController.ShowSendingUI()
        ProgressHUD.animate("Sending...", .triangleDotShift)

        checkFolderExists(folderId: destFolderId, service: service) { [weak self] exists in
            guard let self = self, let viewController = self.viewController else { return }

            guard exists else {
                ProgressHUD.failed("Destination folder not found")
                viewController.HideSendingUI()
                viewController.displayAlert(
                    title: "Folder Not Found",
                    message: "Please select a new destination in Settings."
                )
                self.persistedSelection = nil
                return
            }

            self.performUpload(fileURL: url, destinationFolderId: destFolderId, service: service) { result in
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
