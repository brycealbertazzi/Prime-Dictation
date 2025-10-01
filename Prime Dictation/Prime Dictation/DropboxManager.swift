//
//  DropboxManager.swift
//  Prime Dictation
//
//  Folder picker + persistent selection (Dropbox), mirroring OneDrive UX
//

import UIKit
import AVFoundation
import SwiftyDropbox
import ProgressHUD

final class DropboxManager {

    // MARK: - Types

    enum AuthResult {
        case success
        case cancel
        case error(Error?, String?)
        case none
    }

    struct DBSelection: Codable {
        /// Dropbox stable folder id like "id:xxxxxxxx"
        let folderId: String
        /// Last known lowercase path (optional; we always resolve by id when needed)
        let pathLower: String?
    }

    // Internal picker item model (folders only)
    fileprivate struct PickerFolder {
        let id: String         // "id:xxxx..."
        let name: String
        let pathLower: String  // "/foo/bar"
    }

    // Context == “where am I right now in the picker?”
    fileprivate struct PathContext {
        let pathLower: String  // "" for root, otherwise "/foo/bar"
    }

    // MARK: - Wiring

    weak var viewController: ViewController?
    weak var settingsViewController: SettingsViewController?
    private var recordingManager: RecordingManager?

    init() {
        startPersistenceObservers()
    }

    deinit {
        stopPersistenceObservers()
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
        DropboxClientsManager.authorizedClient != nil || DropboxClientsManager.authorizedTeamClient != nil
    }

    @MainActor
    func signOutAppOnly(completion: @escaping (Bool) -> Void) {
        // If nothing is linked, treat as success
        guard isSignedIn else { completion(true); return }
        DropboxClientsManager.unlinkClients()
        clearSavedSelection()
        completion(true)
    }

    // Start auth; result handled via handleRedirect
    private var authCompletion: ((AuthResult) -> Void)?
    func OpenAuthorizationFlow(completion: @escaping (AuthResult) -> Void) {
        // Short-circuit if already signed in
        if isSignedIn { completion(.success); return }
        guard let presenter = settingsViewController else { completion(.none); return }
        self.authCompletion = completion

        DropboxClientsManager.authorizeFromControllerV2(
            UIApplication.shared,
            controller: presenter,
            loadingStatusDelegate: nil,
            openURL: { UIApplication.shared.open($0) },
            scopeRequest: ScopeRequest(
                scopeType: .user,
                scopes: ["files.content.write", "files.content.read", "files.metadata.read", "sharing.read"],
                includeGrantedScopes: true
            )
        )
    }

    // Called from AppDelegate (or your OAuth router) on redirect
    @discardableResult
    func handleRedirect(url: URL) -> Bool {
        DropboxClientsManager.handleRedirectURL(url, includeBackgroundClient: false) { [weak self] result in
            guard let self else { return }
            ProgressHUD.dismiss()

            switch result {
            case .success:
                ProgressHUD.succeed("Signed into Dropbox")
                self.authCompletion?(.success)
            case .cancel:
                self.authCompletion?(.cancel)
            case .error(let e, let desc):
                self.authCompletion?(.error(e, desc))
            case .none:
                self.authCompletion?(.none)
            }
            self.authCompletion = nil
        }
        return true
    }

    // MARK: - Present folder picker (no async/await)

    @MainActor
    func PresentDropboxFolderPicker(onPicked: ((DBSelection) -> Void)? = nil) {
        guard let settingsVC = settingsViewController else {
            ProgressHUD.failed("Open Settings first")
            return
        }

        func presentNow(_ client: DropboxClient) {
            let start = PathContext(pathLower: "") // root
            buildSelectedMap(client: client) { [weak self] result in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    switch result {
                    case .failure:
                        ProgressHUD.failed("Unable to load Dropbox folders")
                    case .success(let map):
                        let vc = FolderPickerViewController(
                            manager: self,
                            client: client,
                            start: start,
                            branchMap: map,
                            onPicked: { [weak self] sel in
                                guard let self = self else { return }
                                self.saveSelection(sel)
                                onPicked?(sel)
                            }
                        )
                        let nav = UINavigationController(rootViewController: vc)
                        nav.modalPresentationStyle = .formSheet
                        self.settingsViewController?.present(nav, animated: true)
                    }
                }
            }
        }

        if let client = DropboxClientsManager.authorizedClient {
            presentNow(client)
        } else {
            OpenAuthorizationFlow { [weak self] res in
                guard self != nil else { return }
                switch res {
                case .success:
                    if let client = DropboxClientsManager.authorizedClient { presentNow(client) }
                    else { ProgressHUD.failed("Dropbox client unavailable") }
                case .cancel: ProgressHUD.failed("Canceled Dropbox Login")
                case .error, .none: ProgressHUD.failed("Unable to log into Dropbox")
                }
            }
        }
    }

    // MARK: - Upload (no async/await)

    func SendToDropbox(url: URL) {
        guard let viewController, let recordingManager else { return }

        func doUpload(_ client: DropboxClient, folderPath: String) {
            ProgressHUD.animate("Sending...", .triangleDotShift)
            viewController.ShowSendingUI()

            let recordingName = recordingManager.toggledRecordingName + "." + recordingManager.destinationRecordingExtension
            let normalized = folderPath.isEmpty ? "/" : folderPath
            let finalPath = (normalized == "/") ? "/\(recordingName)" : "\(normalized)/\(recordingName)"

            client.files.upload(path: finalPath, input: url)
                .response { response, _ in
                    DispatchQueue.main.async {
                        if response != nil {
                            ProgressHUD.succeed("Recording was sent to Dropbox")
                        } else {
                            ProgressHUD.dismiss()
                            viewController.displayAlert(
                                title: "Recording send failed",
                                message: "Check your internet connection and try again.",
                                handler: {
                                    ProgressHUD.failed("Failed to send recording to Dropbox")
                                }
                            )
                        }
                        viewController.HideSendingUI()
                    }
                }
        }

        guard let client = DropboxClientsManager.authorizedClient else {
            OpenAuthorizationFlow { [weak self] result in
                switch result {
                case .success:
                    self?.settingsViewController?.UpdateSelectedDestinationUserDefaults(destination: .dropbox)
                    self?.settingsViewController?.UpdateSelectedDestinationUI(destination: .dropbox)
                case .cancel:
                    ProgressHUD.failed("Canceled Dropbox Login")
                case .error(_, _), .none:
                    ProgressHUD.failed("Unable to log into Dropbox")
                }
            }
            return
        }

        // Resolve destination and upload
        resolveSelectionOrDefault(client: client) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                ProgressHUD.failed("Dropbox upload unavailable")
            case .success(let sel):
                self.resolveCurrentPath(client: client, selection: sel) { pathResult in
                    switch pathResult {
                    case .failure:
                        ProgressHUD.failed("Dropbox upload unavailable")
                    case .success(let folderPath):
                        doUpload(client, folderPath: folderPath)
                    }
                }
            }
        }
    }

    // MARK: - Selection persistence (durable)

    private let selectionDefaultsKey = "DropboxFolderSelection"

    private func saveSelection(_ sel: DBSelection) {
        let data = try! JSONEncoder().encode(sel)
        let defaults = UserDefaults.standard
        defaults.set(data, forKey: selectionDefaultsKey)
        defaults.synchronize()
        // Atomic backup file as second channel
        try? data.write(to: selectionBackupURL, options: [.atomic])
    }

    private func loadSelection() -> DBSelection? {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: selectionDefaultsKey),
           let sel = try? JSONDecoder().decode(DBSelection.self, from: data) {
            return sel
        }
        if let data = try? Data(contentsOf: selectionBackupURL),
           let sel = try? JSONDecoder().decode(DBSelection.self, from: data) {
            defaults.set(data, forKey: selectionDefaultsKey)
            return sel
        }
        return nil
    }

    private func clearSavedSelection() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: selectionDefaultsKey)
        defaults.synchronize()
        try? FileManager.default.removeItem(at: selectionBackupURL)
    }

    private var selectionBackupURL: URL {
        let fm = FileManager.default
        let dir = try! fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("DropboxFolderSelection.json")
    }

    @objc private func flushDefaultsNow() {
        UserDefaults.standard.synchronize()
    }

    private func startPersistenceObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(flushDefaultsNow), name: UIApplication.willTerminateNotification, object: nil)
        nc.addObserver(self, selector: #selector(flushDefaultsNow), name: UIApplication.didEnterBackgroundNotification, object: nil)
        if #available(iOS 13.0, *) {
            nc.addObserver(self, selector: #selector(flushDefaultsNow), name: UIScene.didEnterBackgroundNotification, object: nil)
        }
    }

    private func stopPersistenceObservers() {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Default folder resolution (callbacks)

    /// Returns saved selection if present; otherwise ensure/create "/Prime Dictation" and return its id.
    private func resolveSelectionOrDefault(client: DropboxClient,
                                           completion: @escaping (Result<DBSelection, Error>) -> Void) {
        if let sel = loadSelection() {
            completion(.success(sel))
            return
        }

        let defaultPath = "/Prime Dictation"
        folderExists(client: client, pathLower: defaultPath.lowercased()) { [weak self] exists in
            guard let self else { return }
            if exists {
                self.getFolderMetadata(client: client, idOrPath: defaultPath) { metaResult in
                    switch metaResult {
                    case .failure(let e):
                        completion(.failure(e))
                    case .success(let meta):
                        let selection = DBSelection(folderId: meta.id, pathLower: meta.pathLower)
                        self.saveSelection(selection)
                        completion(.success(selection))
                    }
                }
            } else {
                self.createFolder(client: client, path: defaultPath) { createResult in
                    switch createResult {
                    case .failure(let e):
                        completion(.failure(e))
                    case .success:
                        self.getFolderMetadata(client: client, idOrPath: defaultPath) { metaResult in
                            switch metaResult {
                            case .failure(let e):
                                completion(.failure(e))
                            case .success(let meta):
                                let selection = DBSelection(folderId: meta.id, pathLower: meta.pathLower)
                                self.saveSelection(selection)
                                completion(.success(selection))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Picker: build map “only selected at THIS level” (callback)

    private static let rootKey = "__root__"

    /// Only computes a single mapping for THIS level:
    ///  - if selected folder is immediate child of root → { rootKey : selectedId }
    ///  - if deeper → { parentPathLower : selectedId }
    private func buildSelectedMap(client: DropboxClient,
                                  completion: @escaping (Result<[String:String], Error>) -> Void) {
        guard let saved = loadSelection() else {
            completion(.success([:]))
            return
        }

        getFolderMetadata(client: client, idOrPath: saved.folderId) { result in
            switch result {
            case .failure(let e):
                completion(.failure(e))
            case .success(let meta):
                guard let selPath = meta.pathLower else {
                    completion(.success([:]))
                    return
                }
                let parentPathLower: String = {
                    if selPath.isEmpty || selPath == "/" { return "" }
                    var comps = selPath.split(separator: "/").map(String.init)
                    _ = comps.popLast()
                    return comps.isEmpty ? "" : "/" + comps.joined(separator: "/")
                }()
                if parentPathLower.isEmpty {
                    completion(.success([Self.rootKey : meta.id]))
                } else {
                    completion(.success([parentPathLower : meta.id]))
                }
            }
        }
    }

    // MARK: - Picker UI (callback-based)
    @MainActor
    private final class FolderPickerViewController: UITableViewController {
        private weak var manager: DropboxManager?
        private let client: DropboxClient
        private var ctx: PathContext
        private var items: [PickerFolder] = []
        private var cursor: String?
        private let onPicked: (DBSelection) -> Void

        /// Map { parentKey → selectedChildId } for ONLY the current level (see buildSelectedMap)
        private var branchMap: [String:String]

        /// For checkmark at this level: if root → rootKey, else current pathLower
        private var selectedChildIdAtThisLevel: String? {
            let parentKey = ctx.pathLower.isEmpty ? DropboxManager.rootKey : ctx.pathLower
            return branchMap[parentKey]
        }

        init(manager: DropboxManager,
             client: DropboxClient,
             start: PathContext,
             branchMap: [String:String],
             onPicked: @escaping (DBSelection) -> Void) {
            self.manager = manager
            self.client = client
            self.ctx = start
            self.onPicked = onPicked
            self.branchMap = branchMap
            super.init(style: .insetGrouped)
            self.title = ctx.pathLower.isEmpty ? "Dropbox" : ctx.pathLower.capitalized.replacingOccurrences(of: "/", with: "")
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidLoad() {
            super.viewDidLoad()
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                primaryAction: UIAction { [weak self] _ in
                    guard let self = self, let manager = self.manager else { return }
                    // Pick the current context folder (root "" or current path)
                    let idOrPath = self.ctx.pathLower.isEmpty ? "" : self.ctx.pathLower
                    manager.getFolderMetadata(client: self.client, idOrPath: idOrPath) { [weak self] res in
                        guard let self = self else { return }
                        switch res {
                        case .failure:
                            ProgressHUD.failed("Unable to pick this folder")
                        case .success(let meta):
                            let sel = DBSelection(folderId: meta.id, pathLower: meta.pathLower)
                            self.onPicked(sel)
                            self.dismiss(animated: true)
                        }
                    }
                }
            )

            tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
            load(reset: true)
            ProgressHUD.dismiss()
        }

        private func load(reset: Bool) {
            guard let manager else { return }
            if reset {
                items.removeAll()
                cursor = nil
                tableView.reloadData()
            }
            manager.listFolders(client: client, pathLower: ctx.pathLower, cursor: cursor) { [weak self] result in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    switch result {
                    case .failure:
                        ProgressHUD.failed("Unable to list Dropbox folders")
                    case .success(let payload):
                        if reset {
                            self.items = payload.items
                        } else {
                            self.items.append(contentsOf: payload.items)
                        }
                        self.cursor = payload.cursor
                        self.tableView.reloadData()
                    }
                }
            }
        }

        // MARK: - Table datasource
        override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            items.count + ((cursor != nil) ? 1 : 0) // "Load more…" row
        }

        override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            if cursor != nil && indexPath.row == items.count {
                let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
                cell.textLabel?.text = "Load more…"
                cell.accessoryType = .none
                return cell
            }

            let item = items[indexPath.row]
            let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
            cell.textLabel?.text = item.name

            // Checkmark only if this row is the selected child at THIS level
            if let selectedId = selectedChildIdAtThisLevel, item.id == selectedId {
                cell.accessoryType = .checkmark
                return cell
            } else {
                cell.accessoryType = .disclosureIndicator
            }

            // Async probe: does this folder have any *subfolders*? If not → hide chevron
            guard let manager = self.manager else { return cell }
            manager.folderHasSubfolders(client: client, pathLower: item.pathLower) { [weak tableView] has in
                DispatchQueue.main.async {
                    guard let tv = tableView,
                          let currentCell = tv.cellForRow(at: indexPath) else { return }
                    if let selectedId = self.selectedChildIdAtThisLevel, item.id == selectedId {
                        // don't override ✓ row
                        return
                    }
                    currentCell.accessoryType = has ? .disclosureIndicator : .none
                }
            }

            return cell
        }

        // MARK: - Table delegate

        override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
            tableView.deselectRow(at: indexPath, animated: true)

            if cursor != nil && indexPath.row == items.count {
                load(reset: false)
                return
            }

            let item = items[indexPath.row]
            guard let manager = self.manager else { return }

            // If no subfolders → select immediately and dismiss; else navigate deeper
            manager.folderHasSubfolders(client: client, pathLower: item.pathLower) { [weak self] has in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    if !has {
                        let sel = DBSelection(folderId: item.id, pathLower: item.pathLower)
                        self.onPicked(sel)
                        self.dismiss(animated: true)
                    } else {
                        let next = PathContext(pathLower: item.pathLower)
                        let vc = FolderPickerViewController(
                            manager: manager,
                            client: self.client,
                            start: next,
                            branchMap: self.branchMap, // reflect saved selection only
                            onPicked: self.onPicked
                        )
                        self.navigationController?.pushViewController(vc, animated: true)
                    }
                }
            }
        }
    }

    // MARK: - Dropbox API helpers (callback wrappers)

    /// List folders at a given path. Returns folder items and a continue cursor (if more).
    private func listFolders(
        client: DropboxClient,
        pathLower: String,
        cursor: String?,
        completion: @escaping (Result<(items: [PickerFolder], cursor: String?), Error>) -> Void
    ) {
        if let cursor {
            client.files.listFolderContinue(cursor: cursor).response { (resp: Files.ListFolderResult?, err: CallError<Files.ListFolderContinueError>?) in
                if let resp = resp {
                    let folders = resp.entries.compactMap { entry -> PickerFolder? in
                        if let meta = entry as? Files.FolderMetadata {
                            return PickerFolder(id: meta.id, name: meta.name, pathLower: meta.pathLower ?? "")
                        }
                        return nil
                    }
                    completion(.success((folders, resp.hasMore ? resp.cursor : nil)))
                } else {
                    completion(.failure(err ?? NSError(domain: "Dropbox", code: -1)))
                }
            }
        } else {
            client.files.listFolder(
                path: pathLower,                  // "" means app-root for App-folder apps, or real root for Full Dropbox apps
                recursive: false,
                includeMediaInfo: false,
                includeDeleted: false,
                includeHasExplicitSharedMembers: true,
                includeMountedFolders: true,      // 👈 include shared/mounted folders
                includeNonDownloadableFiles: false
            ).response { (resp: Files.ListFolderResult?, err: CallError<Files.ListFolderError>?) in
                if let resp = resp {
                    let folders = resp.entries.compactMap { entry -> PickerFolder? in
                        if let meta = entry as? Files.FolderMetadata {
                            return PickerFolder(id: meta.id, name: meta.name, pathLower: meta.pathLower ?? "")
                        }
                        return nil
                    }
                    completion(.success((folders, resp.hasMore ? resp.cursor : nil)))
                } else {
                    completion(.failure(err ?? NSError(domain: "Dropbox", code: -1)))
                }
            }
        }
    }

    /// True iff this folder contains at least one subfolder.
    private func folderHasSubfolders(client: DropboxClient,
                                     pathLower: String,
                                     completion: @escaping (Bool) -> Void) {
        listFolders(client: client, pathLower: pathLower, cursor: nil) { result in
            switch result {
            case .failure:
                completion(true) // safe default: show chevron if uncertain
            case .success(let payload):
                completion(!payload.items.isEmpty)
            }
        }
    }

    /// Get *folder* metadata (id + current pathLower) for a given id or path.
    private func getFolderMetadata(client: DropboxClient,
                                   idOrPath: String,
                                   completion: @escaping (Result<(id: String, pathLower: String?), Error>) -> Void) {
        client.files.getMetadata(path: idOrPath).response { (resp: Files.Metadata?, err: CallError<Files.GetMetadataError>?) in
            if let folder = resp as? Files.FolderMetadata {
                completion(.success((folder.id, folder.pathLower)))
            } else if let _ = resp {
                completion(.failure(NSError(domain: "Dropbox", code: -2, userInfo: [NSLocalizedDescriptionKey: "Not a folder"])))
            } else if let err = err {
                completion(.failure(err))
            } else {
                completion(.failure(NSError(domain: "Dropbox", code: -3)))
            }
        }
    }

    /// Create a folder (idempotent). Returns true if created, false if it already existed.
    private func createFolder(client: DropboxClient,
                              path: String,
                              completion: @escaping (Result<Bool, Error>) -> Void)
    {
        client.files.createFolderV2(path: path, autorename: false)
            .response { resp, err in
                if resp != nil {
                    completion(.success(true))
                    return
                }
                // On error, check whether the folder actually exists already.
                client.files.getMetadata(path: path)
                    .response { meta, metaErr in
                        if let _ = meta as? Files.FolderMetadata {
                            completion(.success(false)) // already exists
                        } else {
                            // Propagate whichever error we have
                          
                        }
                    }
            }
    }



    private func folderExists(client: DropboxClient,
                              pathLower: String,
                              completion: @escaping (Bool) -> Void) {
        getFolderMetadata(client: client, idOrPath: pathLower) { result in
            switch result {
            case .success:
                completion(true)
            case .failure:
                completion(false)
            }
        }
    }

    /// Resolve current absolute path for a saved selection (by id).
    private func resolveCurrentPath(client: DropboxClient,
                                    selection: DBSelection,
                                    completion: @escaping (Result<String, Error>) -> Void) {
        getFolderMetadata(client: client, idOrPath: selection.folderId) { result in
            switch result {
            case .failure(let e):
                completion(.failure(e))
            case .success(let meta):
                completion(.success(meta.pathLower ?? "/"))
            }
        }
    }
}
