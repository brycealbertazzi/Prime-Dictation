

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
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "folderCell")
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(doneButtonTapped))
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Cancel", style: .plain, target: self, action: #selector(cancelButtonTapped))
        fetchFolders()
    }
    
    @objc private func doneButtonTapped() {
        dismiss(animated: true)
    }

    @objc private func cancelButtonTapped() {
        dismiss(animated: true)
    }

    private func fetchFolders() {
        ProgressHUD.animate("Loading Google Drive folders...")
        let query = GTLRDriveQuery_FilesList.query()
        query.q = "'\(parentFolderId)' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
        query.fields = "files(id, name)"
        
        service.executeQuery(query) { [weak self] (ticket, result, error) in
            guard let self = self else { return }
            ProgressHUD.dismiss()

            if let error = error {
                ProgressHUD.failed("Failed to load folders: \(error.localizedDescription)")
                self.dismiss(animated: true)
                return
            }

            guard let files = (result as? GTLRDrive_FileList)?.files as? [GTLRDrive_File] else {
                return
            }

            self.folders = files.map { file in
                return PickerFolder(id: file.identifier ?? "", name: file.name ?? "", isChecked: file.identifier == self.checkedFolderId, hasChildren: false, isLeaf: false)
            }
            self.tableView.reloadData()
            self.checkIfHasChildren(for: self.folders)
        }
    }

    private func checkIfHasChildren(for folders: [PickerFolder]) {
        for (index, folder) in folders.enumerated() {
            let query = GTLRDriveQuery_FilesList.query()
            query.q = "'\(folder.id)' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
            query.pageSize = 1
            query.fields = "files(id)"

            service.executeQuery(query) { [weak self] (ticket, result, error) in
                guard let self = self else { return }
                
                // First, check for potential errors.
                if let error = error {
                    // Handle the error appropriately, e.g., log it or show an alert.
                    print("Error checking for children: \(error.localizedDescription)")
                    return
                }
                
                // Optional-bind the result to ensure it's a GTLRDrive_FileList
                if let fileList = result as? GTLRDrive_FileList {
                    // Now, use a standard 'if' statement to check the boolean condition.
                    let hasChildren = fileList.files?.isEmpty == false
                    self.folders[index].hasChildren = hasChildren
                    self.folders[index].isLeaf = !hasChildren
                    
                    // The reload should happen on the main thread for UI updates.
                    DispatchQueue.main.async {
                        self.tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .automatic)
                    }
                }
            }
        }
    }

    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return folders.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "folderCell", for: indexPath)
        let folder = folders[indexPath.row]
        cell.textLabel?.text = folder.name
        cell.accessoryType = folder.id == checkedFolderId ? .checkmark : .none
        cell.detailTextLabel?.text = nil // Clear any previous detail text
        if folder.isLeaf == false {
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let selectedFolder = folders[indexPath.row]
        
        if selectedFolder.isLeaf {
            if selectedFolder.id == checkedFolderId {
                // Leaf folder is already checked, uncheck it
                checkedFolderId = nil
                manager.updateSelectedFolder(nil)
            } else {
                // Check leaf folder
                checkedFolderId = selectedFolder.id
                manager.updateSelectedFolder(GDSelection(folderId: selectedFolder.id, name: selectedFolder.name, accountId: manager.currentAccountId))
            }
            tableView.reloadData()
        } else {
            // Non-leaf folder, navigate deeper
            let newVC = GDFolderPickerViewController(manager: manager, service: service, parentFolderId: selectedFolder.id, onPicked: onPicked)
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
    private static let googleDriveRootId = "root"

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
        didSet {
            saveSelection()
        }
    }

    override init() {
        super.init()
        loadSelection()
    }

    func attach(settingsViewController: SettingsViewController) {
        self.settingsViewController = settingsViewController
    }

    func attach(viewController: ViewController, recordingManager: RecordingManager) {
        self.viewController = viewController
        self.recordingManager = recordingManager
    }

    // MARK: - Auth

    var isSignedIn: Bool {
        return driveService?.authorizer?.canAuthorize ?? false
    }

    @MainActor
    func signOutAppOnly(completion: @escaping (Bool) -> Void) {
        guard isSignedIn else { completion(true); return }
        GIDSignIn.sharedInstance.signOut()
        driveService = nil
        currentAccountId = nil
        // Clear saved selection
        persistedSelection = nil
        completion(true)
    }

    func openAuthorizationFlow(completion: @escaping (AuthResult) -> Void) {
        print("opening auth flow")
        // Short-circuit if already signed in and has Drive scope
        if isSignedIn {
            if let user = GIDSignIn.sharedInstance.currentUser,
               user.grantedScopes?.contains("https://www.googleapis.com/auth/drive") == true {
                print("is signed in with drive scope")
                completion(.success)
                return
            }
        }
        
        guard let presenter = settingsViewController else {
            completion(.none)
            print("No presenter")
            return
        }
        
        self.authCompletion = completion
        
        let driveScope = "https://www.googleapis.com/auth/drive"
        
        GIDSignIn.sharedInstance.signIn(withPresenting: presenter) { [weak self] signInResult, error in
            print("GIDSignIn")
            guard let self = self else { return }
            ProgressHUD.dismiss()
            
            if let error = error {
                print("GID sign in Error")
                // Now, check the error code directly on the GIDSignInError object
                if (error as NSError).code == GIDSignInError.Code.canceled.rawValue {
                    self.authCompletion?(.cancel)
                } else {
                    self.authCompletion?(.error(error, "Google Sign-In failed: \(error.localizedDescription)"))
                }
                self.authCompletion = nil
                return
            }
            print("Getting sign in result")
            guard let signInResult = signInResult else {
                self.authCompletion?(.cancel)
                self.authCompletion = nil
                return
            }
            print("sign in result \(signInResult)")
            
            if signInResult.user.grantedScopes?.contains(driveScope) == true {
                self.setupDriveService(with: signInResult)
                print("Signed in to GD")
                ProgressHUD.succeed("Signed into Google Drive")
                self.authCompletion?(.success)
                self.authCompletion = nil
            } else {
                print("Adding scopes")
                signInResult.user.addScopes([driveScope], presenting: presenter) { result, error in
                    if let error = error {
                        print("Unable to grant drive access")
                        self.authCompletion?(.error(error, "Failed to grant Drive access."))
                    } else if let result = result, result.user.grantedScopes?.contains(driveScope) == true {
                        self.setupDriveService(with: result)
                        print("Signed in to GD with added scopes")
                        ProgressHUD.succeed("Signed into Google Drive")
                        self.authCompletion?(.success)
                    } else {
                        self.authCompletion?(.cancel)
                    }
                    self.authCompletion = nil
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
        guard let settingsVC = settingsViewController else {
            ProgressHUD.failed("Open Settings first")
            return
        }

        func presentPicker(_ service: GTLRDriveService) {
            let vc = GDFolderPickerViewController(
                manager: self,
                service: service,
                parentFolderId: GoogleDriveManager.googleDriveRootId,
                onPicked: { [weak self] selection in
                    guard let self = self else { return }
                    self.updateSelectedFolder(selection)
                    onPicked?(selection)
                }
            )
            let nav = UINavigationController(rootViewController: vc)
            nav.modalPresentationStyle = .formSheet
            settingsVC.present(nav, animated: true)
        }

        if isSignedIn, let service = driveService {
            presentPicker(service)
        } else {
            openAuthorizationFlow { [weak self] res in
                guard let self = self else { return }
                switch res {
                case .success:
                    if let service = self.driveService {
                        presentPicker(service)
                    } else {
                        ProgressHUD.failed("Google Drive client unavailable")
                    }
                case .cancel:
                    ProgressHUD.failed("Canceled Google Login")
                case .error(_, _):
                    ProgressHUD.failed("Unable to log into Google Drive")
                case .none:
                    break
                }
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
        
        guard let destination = persistedSelection else {
            viewController.displayAlert(title: "No Google Drive folder selected", message: "Please select a folder in Settings.")
            return
        }
        
        ProgressHUD.animate("Sending...", .triangleDotShift)
        viewController.ShowSendingUI()

        // Check if destination folder still exists
        checkFolderExists(folderId: destination.folderId, service: service) { [weak self] exists in
            guard let self = self else { return }
            if exists {
                self.performUpload(fileURL: url, destinationFolderId: destination.folderId, service: service)
            } else {
                ProgressHUD.failed("Destination folder not found")
                viewController.ShowSendingUI()
                viewController.displayAlert(title: "Folder Not Found", message: "The selected Google Drive folder was not found. Please select a new destination in Settings.")
                self.persistedSelection = nil
            }
        }
    }
    
    private func checkFolderExists(folderId: String, service: GTLRDriveService, completion: @escaping (Bool) -> Void) {
        if folderId == GoogleDriveManager.googleDriveRootId {
            completion(true) // Root folder always exists
            return
        }
        
        let query = GTLRDriveQuery_FilesGet.query(withFileId: folderId)
        query.fields = "id"
        service.executeQuery(query) { (ticket, file, error) in
            completion(file != nil && error == nil)
        }
    }

    private func performUpload(fileURL: URL, destinationFolderId: String, service: GTLRDriveService) {
        guard let viewController, let recordingManager else { return }

        let recordingName = recordingManager.toggledRecordingName + "." + recordingManager.destinationRecordingExtension

        // Determine the MIME type dynamically from the file's extension
        let mimeType: String
        if let fileExtension = fileURL.pathExtension.isEmpty ? nil : fileURL.pathExtension,
           let utType = UTType(filenameExtension: fileExtension),
           let preferredMIMEType = utType.preferredMIMEType {
            mimeType = preferredMIMEType
        } else {
            // Fallback for an unknown or missing file type
            mimeType = "application/octet-stream"
        }

        let file = GTLRDrive_File()
        file.name = recordingName
        file.parents = [destinationFolderId]

        let uploadParameters = GTLRUploadParameters(fileURL: fileURL, mimeType: mimeType)
        let query = GTLRDriveQuery_FilesCreate.query(withObject: file, uploadParameters: uploadParameters)

        service.executeQuery(query) { (ticket, result, error) in
            DispatchQueue.main.async { // Ensure UI updates happen on the main thread
                if let error = error {
                    ProgressHUD.failed("Upload failed: \(error.localizedDescription)")
                } else {
                    ProgressHUD.succeed("Sent to Google Drive!")
                    // You might want to update the last updated date on the file
                }
                viewController.ShowSendingUI()
            }
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
        return persistedSelection?.name ?? "No Google Drive Folder Selected"
    }
}
