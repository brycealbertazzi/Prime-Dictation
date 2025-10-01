//
//  DropboxManager.swift
//  Prime Dictation
//
//  Folder picker + persistent selection (Dropbox), mirroring OneDrive UX
//  - Per-level selection with single checkmark
//  - Tap checked item: navigate if non-leaf, unselect (promote parent) if leaf
//  - Caching + background probing to minimize chevron flicker
//  - If no child is selected at a level → parent context is considered selected
//  - ✅ "Done" button confirms current selection and closes; tapping a leaf only checks it
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
        guard let _ = settingsViewController else {
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
    static let rootKey = "__root__"
    static let rootSelectionId = "__dbx_root__" // synthetic id representing the user’s root

    /// Only computes a single mapping for THIS level:
    ///  - if selected folder is immediate child of root → { rootKey : selectedId }
    ///  - if deeper → { parentPathLower : selectedId }
    private func buildSelectedMap(client: DropboxClient,
                                  completion: @escaping (Result<[String:String], Error>) -> Void) {
        // No prior selection → nothing to pre-check
        guard let saved = loadSelection() else {
            completion(.success([:]))
            return
        }

        // Root selection → also nothing to pre-check (no child selected at root)
        if saved.folderId == Self.rootSelectionId {
            completion(.success([:]))
            return
        }

        // Resolve saved selection to get its current pathLower
        getFolderMetadata(client: client, idOrPath: saved.folderId) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let e):
                completion(.failure(e))

            case .success(let meta):
                guard let selPathLower = meta.pathLower, !selPathLower.isEmpty, selPathLower != "/" else {
                    // Selection is effectively root or we can’t resolve a proper path
                    completion(.success([:]))
                    return
                }

                // Walk each component and build { parentKey → childId } at that level.
                let components = selPathLower.split(separator: "/").map { String($0) }
                var mapping: [String:String] = [:]

                // Helper to join components as lowercase path with leading slash or empty for root
                func joinPath(_ comps: ArraySlice<String>) -> String {
                    if comps.isEmpty { return "" }        // root
                    return "/" + comps.joined(separator: "/")
                }

                // Recursively fetch metadata for each child path to get the child id and fill the map
                func processLevel(_ idx: Int) {
                    // idx goes from 0..<(components.count)
                    // at idx = 0: parent = "", child = "/\(components[0])"
                    if idx >= components.count {
                        completion(.success(mapping))
                        return
                    }

                    let parentPath = joinPath(components.prefix(idx)[...])
                    let childPath = joinPath(components.prefix(idx + 1)[...])

                    self.getFolderMetadata(client: client, idOrPath: childPath) { res in
                        switch res {
                        case .failure(let e):
                            // If one level fails, return what we have so far (or fail hard)
                            completion(.failure(e))
                        case .success(let childMeta):
                            let parentKey = parentPath.isEmpty ? Self.rootKey : parentPath
                            mapping[parentKey] = childMeta.id
                            processLevel(idx + 1)
                        }
                    }
                }

                processLevel(0)
            }
        }
    }


    // MARK: - Caches to minimize chevron flicker

    private let hasSubfoldersCache = NSCache<NSString, NSNumber>()
    private var inflightSubfolderChecks = Set<String>()
    private let subfolderProbeQueue = DispatchQueue(label: "dbx.subprobe", qos: .utility)

    private func cachedHasSubfolders(for pathLower: String) -> Bool? {
        if let n = hasSubfoldersCache.object(forKey: pathLower as NSString) { return n.boolValue }
        return nil
    }

    private func setCachedHasSubfolders(_ value: Bool, for pathLower: String) {
        hasSubfoldersCache.setObject(NSNumber(value: value), forKey: pathLower as NSString)
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

        /// parentKey for this level (root → rootKey)
        private var parentKey: String { ctx.pathLower.isEmpty ? DropboxManager.rootKey : ctx.pathLower }

        /// For checkmark at this level: get/set selected child id within this parent level
        private var selectedChildIdAtThisLevel: String? {
            get { branchMap[parentKey] }
            set { branchMap[parentKey] = newValue }
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

            // ✅ "Done" confirms current selection (checked child at this level if present; otherwise the current context)
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: "Done",
                style: .done,
                target: self,
                action: #selector(confirmSelectionAndDismiss)
            )

            tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
            load(reset: true)
            ProgressHUD.dismiss()
        }
        
        // Confirm the effective selection and dismiss:
        // - If a child is checked at this level → that folder
        // - Else → the current context folder
        @objc private func confirmSelectionAndDismiss() {
            guard let manager = self.manager else { return }

            if let selectedId = selectedChildIdAtThisLevel {
                // Resolve by id as before
                manager.getFolderMetadata(client: client, idOrPath: selectedId) { [weak self] res in
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
            } else {
                // No child checked → confirming the current context
                if ctx.pathLower.isEmpty {
                    // ✅ root: don’t call getMetadata(""); just persist a synthetic “root” selection
                    let sel = DBSelection(folderId: DropboxManager.rootSelectionId, pathLower: "/")
                    onPicked(sel)
                    self.dismiss(animated: true)
                } else {
                    // Non-root context: resolve normally
                    let idOrPath = ctx.pathLower
                    manager.getFolderMetadata(client: client, idOrPath: idOrPath) { [weak self] res in
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
            }
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
            }

            // Use cached knowledge to set chevron with minimal flicker
            if let manager, let cached = manager.cachedHasSubfolders(for: item.pathLower) {
                cell.accessoryType = cached ? .disclosureIndicator : .none
            } else {
                // Optimistic: assume navigable until probe says otherwise
                cell.accessoryType = .disclosureIndicator
                // Background probe (deduped) to refine
                manager?.probeHasSubfoldersCached(client: client, pathLower: item.pathLower) { [weak tableView] has in
                    DispatchQueue.main.async {
                        guard let tv = tableView,
                              let currentCell = tv.cellForRow(at: indexPath) else { return }
                        // Don't override ✓ row
                        if let selectedId = self.selectedChildIdAtThisLevel, item.id == selectedId { return }
                        currentCell.accessoryType = has ? .disclosureIndicator : .none
                    }
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

            let applyCheckmarkChange: (_ newSelectedId: String?) -> Void = { [weak self] newId in
                guard let self = self else { return }
                let previous = self.selectedChildIdAtThisLevel
                self.selectedChildIdAtThisLevel = newId

                // Update just the affected rows to avoid flashing
                var indexPathsToReload: [IndexPath] = [indexPath]
                if let prevId = previous, prevId != item.id, let prevRow = self.items.firstIndex(where: { $0.id == prevId }) {
                    indexPathsToReload.append(IndexPath(row: prevRow, section: 0))
                }
                self.tableView.reloadRows(at: indexPathsToReload, with: .none)
            }

            // Decide based on hasSubfolders (cached if possible)
            let proceed: (Bool) -> Void = { [weak self] has in
                guard let self = self else { return }
                if let selectedId = self.selectedChildIdAtThisLevel, selectedId == item.id {
                    // Tapped a folder that already has a ✓
                    if has {
                        // Navigate inside (keep checkmark at this level)
                        let next = PathContext(pathLower: item.pathLower)
                        let vc = FolderPickerViewController(
                            manager: manager,
                            client: self.client,
                            start: next,
                            branchMap: self.branchMap, // carry map forward
                            onPicked: self.onPicked
                        )
                        self.navigationController?.pushViewController(vc, animated: true)
                    } else {
                        // Leaf + already selected → unselect (parent becomes effective selection)
                        // (No dismissal or persistence here; Done will confirm later)
                        applyCheckmarkChange(nil)
                    }
                } else {
                    // Tapped a *different* folder at this level → move the ✓ here
                    applyCheckmarkChange(item.id)
                    if has {
                        // Navigate deeper immediately (no confirmation yet)
                        let next = PathContext(pathLower: item.pathLower)
                        let vc = FolderPickerViewController(
                            manager: manager,
                            client: self.client,
                            start: next,
                            branchMap: self.branchMap,
                            onPicked: self.onPicked
                        )
                        self.navigationController?.pushViewController(vc, animated: true)
                    } else {
                        // ✅ Leaf → just check it; DO NOT confirm or dismiss.
                        // Confirmation happens only when the user taps "Done".
                    }
                }
            }

            if let cached = manager.cachedHasSubfolders(for: item.pathLower) {
                proceed(cached)
            } else {
                manager.probeHasSubfoldersCached(client: client, pathLower: item.pathLower) { has in
                    DispatchQueue.main.async { proceed(has) }
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

    /// Cached probe: True iff this folder contains at least one subfolder.
    fileprivate func probeHasSubfoldersCached(client: DropboxClient,
                                              pathLower: String,
                                              completion: @escaping (Bool) -> Void) {
        if let cached = cachedHasSubfolders(for: pathLower) { completion(cached); return }
        if inflightSubfolderChecks.contains(pathLower) { // coalesce callers
            // Poll cache shortly on a background queue
            subfolderProbeQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                if let cached = self.cachedHasSubfolders(for: pathLower) {
                    DispatchQueue.main.async { completion(cached) }
                } else {
                    // If still not available, do a one-off call now
                    self.folderHasSubfolders(client: client, pathLower: pathLower) { has in
                        self.setCachedHasSubfolders(has, for: pathLower)
                        DispatchQueue.main.async { completion(has) }
                    }
                }
            }
            return
        }
        inflightSubfolderChecks.insert(pathLower)
        folderHasSubfolders(client: client, pathLower: pathLower) { [weak self] has in
            guard let self = self else { return }
            self.setCachedHasSubfolders(has, for: pathLower)
            self.inflightSubfolderChecks.remove(pathLower)
            completion(has)
        }
    }

    /// Uncached helper used by the cached probe above.
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
    fileprivate func getFolderMetadata(client: DropboxClient,
                                       idOrPath: String,
                                       completion: @escaping (Result<(id: String, pathLower: String?), Error>) -> Void) {
        client.files.getMetadata(path: idOrPath).response { (resp: Files.Metadata?, err: CallError<Files.GetMetadataError>?) in
            if let folder = resp as? Files.FolderMetadata {
                completion(.success((folder.id, folder.pathLower)))
            } else if let _ = resp {
                completion(.failure(NSError(domain: "Dropbox", code: -2, userInfo: [NSLocalizedDescriptionKey: "Not a folder"])))}
            else if let err = err {
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
            .response { resp, _ in
                if resp != nil {
                    completion(.success(true))
                    return
                }
                // On error, check whether the folder actually exists already.
                client.files.getMetadata(path: path)
                    .response { meta, _ in
                        if let _ = meta as? Files.FolderMetadata {
                            completion(.success(false)) // already exists
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
        if selection.folderId == Self.rootSelectionId {
            completion(.success("/"))
            return
        }
        getFolderMetadata(client: client, idOrPath: selection.folderId) { result in
            switch result {
            case .failure(let e): completion(.failure(e))
            case .success(let meta): completion(.success(meta.pathLower ?? "/"))
            }
        }
    }
}
