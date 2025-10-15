import UIKit
import AVFoundation
import SwiftyDropbox
import ProgressHUD

final class DropboxManager {

    // MARK: - Types

    enum AuthResult {
        case success
        case alreadyAuthenticated
        case cancel
        case error(Error?, String?)
        case none
    }

    struct DBSelection: Codable {
        /// Dropbox stable folder id like "id:xxxxxxxx", or synthetic root id below
        let folderId: String
        /// Last known lowercase path (optional; we always resolve by id when needed)
        let pathLower: String?
        let name: String?
        init(folderId: String, pathLower: String?, name: String?) {
            self.folderId = folderId
            self.pathLower = pathLower
            self.name = name
        }
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
        let name: String
    }

    // MARK: - Keys / Constants

    static let rootKey = "__root__"
    static let rootSelectionId = "__dbx_root__" // synthetic id representing user's root

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
    func SignOutAppOnly(completion: @escaping (Bool) -> Void) {
        // If nothing is linked, treat as success
        guard isSignedIn else { completion(true); return }
        DropboxClientsManager.unlinkClients()
        // Clear saved selection so the user reselects next time
        clearSavedSelection()
        completion(true)
    }
    
    @MainActor
    func SignOutAndRevoke(completion: @escaping (Bool) -> Void) {
        // If nothing is linked, we’re effectively signed out
        guard isSignedIn else { completion(true); return }

        // Revoke any active user/team tokens on Dropbox’s side
        let group = DispatchGroup()
        var success = true

        if let userClient = DropboxClientsManager.authorizedClient {
            group.enter()
            userClient.auth.tokenRevoke().response { _, err in
                if let err { print("Dropbox token revoke (user) failed: \(err)"); success = false }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            // Always unlink locally afterwards
            DropboxClientsManager.unlinkClients()
            self.clearSavedSelection()
            completion(success)
        }
    }

    // Start auth; result handled via handleRedirect
    private var authCompletion: ((AuthResult) -> Void)?
    func OpenAuthorizationFlow(completion: @escaping (AuthResult) -> Void) {
        // Short-circuit if already signed in
        if isSignedIn { completion(.alreadyAuthenticated); return }
        guard let presenter = settingsViewController else { completion(.none); return }
        self.authCompletion = completion

        let scope = ScopeRequest(
            scopeType: .user,
            scopes: ["files.content.write", "files.content.read", "files.metadata.read", "sharing.read"],
            includeGrantedScopes: false
        )
        DropboxClientsManager.authorizeFromControllerV2(
            UIApplication.shared,
            controller: presenter,
            loadingStatusDelegate: nil,
            openURL: { UIApplication.shared.open($0) },
            scopeRequest: scope,
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

    @MainActor
    func PresentDropboxFolderPicker(onPicked: ((DBSelection) -> Void)? = nil) {
        guard let _ = settingsViewController else {
            ProgressHUD.failed("Open Settings first")
            return
        }

        func presentNow(_ client: DropboxClient) {
            // 🔑 Always start with a clean view of the world for this session
            self.resetSubfolderCache()

            let start = PathContext(pathLower: "", name: "") // root
            buildSelectedMap(client: client) { [weak self] result in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    switch result {
                    case .failure:
                        ProgressHUD.failed("Unable to load Dropbox folders")
                    case .success(let map):
                        // Determine the initially selected id from persisted selection (if not root)
                        let initialSelectedId: String? = {
                            if let saved = self.loadSelection(),
                               saved.folderId != Self.rootSelectionId {
                                return saved.folderId
                            }
                            return nil
                        }()

                        let vc = FolderPickerViewController(
                            manager: self,
                            client: client,
                            start: start,
                            branchMap: map,
                            initialSelectedId: initialSelectedId,
                            onPicked: { sel in
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
            ProgressHUD.dismiss()
            OpenAuthorizationFlow { res in
                switch res {
                case .success, .alreadyAuthenticated:
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
                case .success, .alreadyAuthenticated:
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

    // MARK: - Default folder resolution (callbacks, no account awareness)

    /// Returns a validated selection:
    /// - If saved selection exists and is root → return it.
    /// - Else try saved by id, then by pathLower.
    /// - On any miss → FALL BACK TO ROOT. Never error just for having no/invalid selection.
    private func resolveSelectionOrDefault(client: DropboxClient,
                                           completion: @escaping (Result<DBSelection, Error>) -> Void) {
        // If a root selection is saved, use it immediately.
        if let saved = loadSelection(), saved.folderId == Self.rootSelectionId {
            completion(.success(saved))
            return
        }

        // No prior selection → use ROOT
        guard let saved = self.loadSelection() else {
            completion(.success(DBSelection(folderId: Self.rootSelectionId, pathLower: "/", name: "Root")))
            return
        }

        func finishAndPersist(from meta: (id: String, pathLower: String?, name: String?)) {
            let sel = DBSelection(folderId: meta.id, pathLower: meta.pathLower, name: meta.name)
            self.saveSelection(sel)
            completion(.success(sel))
        }

        // Try saved by id first (fast if valid)
        self.getFolderMetadata(client: client, idOrPath: saved.folderId) { idResult in
            switch idResult {
            case .success(let meta):
                finishAndPersist(from: meta)
            case .failure:
                // Try by last-known pathLower
                if let path = saved.pathLower {
                    self.getFolderMetadata(client: client, idOrPath: path) { pathRes in
                        switch pathRes {
                        case .success(let meta): finishAndPersist(from: meta)
                        case .failure:
                            // Fall back to root
                            completion(.success(DBSelection(folderId: Self.rootSelectionId, pathLower: "/", name: "Root")))
                        }
                    }
                } else {
                    // Fall back to root
                    completion(.success(DBSelection(folderId: Self.rootSelectionId, pathLower: "/", name: "Root")))
                }
            }
        }
    }

    // Optional legacy error path (no longer used by resolver)
    func DisplayNoFolderSelectedError() {
        viewController?.displayAlert(title: "Recording send failed", message: "Your selected folder may have been deleted or you lost connection.", handler: {
            ProgressHUD.failed("Failed to send recording to Dropbox")
        })
    }

    // MARK: - Picker: build map for ALL ancestor levels (no account awareness)

    /// Computes a mapping for *every* level along the saved selection’s path:
    ///   If selection is /clients/acme/2025, returns:
    ///     {
    ///       "__root__"      : id("/clients"),
    ///       "/clients"      : id("/clients/acme"),
    ///       "/clients/acme" : id("/clients/acme/2025")
    ///     }
    private func buildSelectedMap(client: DropboxClient,
                                  completion: @escaping (Result<[String:String], Error>) -> Void) {
        guard let saved = loadSelection() else { completion(.success([:])); return }
        if saved.folderId == Self.rootSelectionId { completion(.success([:])); return }

        // Helper: once we know the current valid pathLower, build the chain map
        func buildMap(from selPathLower: String) {
            guard !selPathLower.isEmpty, selPathLower != "/" else {
                completion(.success([:]))
                return
            }
            let components = selPathLower.split(separator: "/").map { String($0) }
            var mapping: [String:String] = [:]

            func joinPath(_ comps: ArraySlice<String>) -> String {
                if comps.isEmpty { return "" } // root
                return "/" + comps.joined(separator: "/")
            }

            func processLevel(_ idx: Int) {
                if idx >= components.count {
                    completion(.success(mapping))
                    return
                }
                let parentPath = joinPath(components.prefix(idx)[...])
                let childPath  = joinPath(components.prefix(idx + 1)[...])

                self.getFolderMetadata(client: client, idOrPath: childPath) { res in
                    switch res {
                    case .failure:
                        // return what we have so far; don't block picker
                        completion(.success(mapping))
                    case .success(let childMeta):
                        let parentKey = parentPath.isEmpty ? Self.rootKey : parentPath
                        mapping[parentKey] = childMeta.id
                        processLevel(idx + 1)
                    }
                }
            }

            processLevel(0)
        }

        // Try by id first; otherwise by saved pathLower; else empty
        self.getFolderMetadata(client: client, idOrPath: saved.folderId) { result in
            switch result {
            case .success(let meta):
                buildMap(from: meta.pathLower ?? "/")
            case .failure:
                if let path = saved.pathLower {
                    self.getFolderMetadata(client: client, idOrPath: path) { pathRes in
                        switch pathRes {
                        case .success(let meta): buildMap(from: meta.pathLower ?? "/")
                        case .failure: completion(.success([:]))
                        }
                    }
                } else {
                    completion(.success([:]))
                }
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
    
    private func resetSubfolderCache() {
        hasSubfoldersCache.removeAllObjects()
        // Clear in-flight coalescing too so we don't “reuse” stale probes
        subfolderProbeQueue.async { [weak self] in
            self?.inflightSubfolderChecks.removeAll()
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

        /// Map { parentKey → selectedChildId } (prebuilt for the saved selection path).
        private var branchMap: [String:String]

        /// Per-level parent key (root uses special key).
        private var parentKey: String { ctx.pathLower.isEmpty ? DropboxManager.rootKey : ctx.pathLower }

        /// The currently selected folder (global) → shows a ✓ (leaf or non-leaf).
        private var selectedId: String?

        /// At this level, override which child is considered the path child (blue chevron).
        private var pathChildOverride: [String:String] = [:]

        /// For Done semantics: which child is “picked” at this level (used to resolve if user taps Done here).
        private var workingSelectedChildId: String? {
            get { branchMap[parentKey] }
            set { branchMap[parentKey] = newValue }
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

        init(manager: DropboxManager,
             client: DropboxClient,
             start: PathContext,
             branchMap: [String:String],
             initialSelectedId: String?,
             onPicked: @escaping (DBSelection) -> Void) {
            self.manager = manager
            self.client = client
            self.ctx = start
            self.branchMap = branchMap
            self.onPicked = onPicked
            self.selectedId = initialSelectedId
            super.init(style: .insetGrouped)

            self.title = ctx.name.isEmpty ? "Dropbox" :
                ctx.name.replacingOccurrences(of: "/", with: "").trimmingCharacters(in: .whitespaces)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidLoad() {
            super.viewDidLoad()

            // Done: pick working selection at this level (or the current folder)
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
                    manager.SignOutAndRevoke { success in
                        Task { @MainActor in
                            guard let settingsVC = manager.settingsViewController else {
                                print("Unable to find settings view controller on Dropbox signout")
                                return
                            }
                            if success {
                                settingsVC.UpdateSelectedDestinationUserDefaults(destination: Destination.none)
                                settingsVC.UpdateSelectedDestinationUI(destination: Destination.none)
                                self.dismiss(animated: true)
                                ProgressHUD.succeed("Signed out of Dropbox")
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
            load(reset: true)
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

        // Confirm selection: if a child at this level is “picked”, use it; else use current folder
        @objc private func confirmSelectionAndDismiss() {
            guard let manager = self.manager else { return }

            let finish: (DBSelection) -> Void = { [weak self] sel in
                guard let self = self else { return }
                manager.saveSelection(sel)
                self.onPicked(sel)
                self.dismiss(animated: true)
                let folderDislayName = sel.name ?? "Dropbox"
                ProgressHUD.succeed("\(folderDislayName) selected")
            }

            if let selectedChild = workingSelectedChildId {
                manager.getFolderMetadata(client: client, idOrPath: selectedChild) { res in
                    switch res {
                    case .failure:
                        ProgressHUD.failed("Unable to pick this folder")
                    case .success(let meta):
                        let name = meta.name ?? meta.pathLower?.split(separator: "/").last.map(String.init) ?? "Dropbox"
                        finish(DBSelection(folderId: meta.id, pathLower: meta.pathLower, name: name))
                    }
                }
            } else {
                // current context (root-safe)
                if ctx.pathLower.isEmpty {
                    finish(DBSelection(folderId: DropboxManager.rootSelectionId, pathLower: "/", name: "Root"))
                } else {
                    manager.getFolderMetadata(client: client, idOrPath: ctx.pathLower) { res in
                        switch res {
                        case .failure:
                            ProgressHUD.failed("Unable to pick this folder")
                        case .success(let meta):
                            let name = meta.name ?? meta.pathLower?.split(separator: "/").last.map(String.init) ?? "Dropbox"
                            finish(DBSelection(folderId: meta.id, pathLower: meta.pathLower, name: name))
                        }
                    }
                }
            }
        }

        // Footer action
        @objc private func clearSelectionTapped() {
            // Clear selection at THIS level so the selected folder becomes the current folder (parent)
            selectedId = nil
            workingSelectedChildId = nil
            pathChildOverride[parentKey] = nil

            // Refresh all visible rows to remove ✓ and flip any blue chevrons back to black
            tableView.reloadData()
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
                        if reset { self.items = payload.items } else { self.items.append(contentsOf: payload.items) }
                        self.cursor = payload.cursor
                        self.tableView.reloadData()
                    }
                }
            }
        }

        // MARK: - Accessory helpers

        private func setChevron(on cell: UITableViewCell, blue: Bool) {
            let iv = UIImageView(image: UIImage(systemName: "chevron.right"))
            iv.tintColor = blue ? .systemBlue : .label
            cell.accessoryView = iv
            cell.accessoryType = .none
        }

        private func currentPathChildId() -> String? {
            pathChildOverride[parentKey] ?? branchMap[parentKey]
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
                cell.accessoryView = nil
                return cell
            }

            let item = items[indexPath.row]
            let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
            cell.textLabel?.text = item.name

            // Always clear accessories first (reuse-safe)
            cell.accessoryType = .none
            cell.accessoryView = nil

            // ✓ only for the globally selected folder (leaf or non-leaf)
            if let sel = selectedId, sel == item.id {
                cell.accessoryType = .checkmark
                return cell
            }

            // If we know leaf/non-leaf, color chevrons appropriately; else optimistic + probe
            if let has = manager?.cachedHasSubfolders(for: item.pathLower) {
                if has {
                    let isAncestorHere = (item.id == currentPathChildId())
                    setChevron(on: cell, blue: isAncestorHere)
                } // else leaf → none
            } else {
                // Optimistic: show chevron with current tint decision, then probe to correct
                let isAncestorHere = (item.id == currentPathChildId())
                setChevron(on: cell, blue: isAncestorHere)

                manager?.probeHasSubfoldersCached(client: client, pathLower: item.pathLower) { [weak self, weak tableView] has in
                    DispatchQueue.main.async {
                        guard let self = self,
                              let tv = tableView,
                              let currentCell = tv.cellForRow(at: indexPath) else { return }

                        // Don't override ✓ rows
                        if let sel = self.selectedId, sel == item.id { return }

                        currentCell.accessoryType = .none
                        currentCell.accessoryView = nil
                        if has {
                            let isAncestorNow = (item.id == self.currentPathChildId())
                            self.setChevron(on: currentCell, blue: isAncestorNow)
                        } // else leave none
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

            guard let manager = self.manager else { return }
            let item = items[indexPath.row]
            let tappedId = item.id
            let wasSelected = (tappedId == selectedId)

            // previous blue chevron at this level (to flip to black if we choose a sibling)
            let prevPathChildId = currentPathChildId()
            let prevPathIndex: IndexPath? = {
                if let pid = prevPathChildId, let idx = items.firstIndex(where: { $0.id == pid }) {
                    return IndexPath(row: idx, section: 0)
                }
                return nil
            }()

            func reload(_ a: IndexPath, _ b: IndexPath?) {
                var arr = [a]
                if let b, b != a { arr.append(b) }
                tableView.reloadRows(at: arr, with: .none)
            }

            let handleTap: (Bool) -> Void = { [weak self] hasSub in
                guard let self = self else { return }

                // Update path child override so chevron on old path flips blue→black
                self.pathChildOverride[self.parentKey] = tappedId

                if hasSub {
                    // Non-leaf: DO NOT mark as selected; just update working branch and navigate.
                    self.workingSelectedChildId = tappedId
                    reload(indexPath, prevPathIndex)

                    let next = PathContext(pathLower: item.pathLower, name: item.name)
                    let vc = FolderPickerViewController(
                        manager: manager,
                        client: self.client,
                        start: next,
                        branchMap: self.branchMap,
                        initialSelectedId: self.selectedId, // keep the true selection as we navigate
                        onPicked: self.onPicked
                    )
                    self.navigationController?.pushViewController(vc, animated: true)
                } else {
                    // Leaf: toggle ✓ on/off
                    if wasSelected {
                        // Deselect → parent becomes effective again; clear override so ancestor chevrons restore
                        self.selectedId = nil
                        self.workingSelectedChildId = nil
                        self.pathChildOverride[self.parentKey] = nil
                    } else {
                        self.selectedId = tappedId
                        self.workingSelectedChildId = tappedId
                    }
                    reload(indexPath, prevPathIndex)
                }
            }

            if let cached = manager.cachedHasSubfolders(for: item.pathLower) {
                handleTap(cached)
            } else {
                manager.probeHasSubfoldersCached(client: client, pathLower: item.pathLower) { has in
                    DispatchQueue.main.async { handleTap(has) }
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
                path: pathLower,                  // "" = app-root (App folder apps) or true root (Full Dropbox apps)
                recursive: false,
                includeMediaInfo: false,
                includeDeleted: false,
                includeHasExplicitSharedMembers: true,
                includeMountedFolders: true,      // include shared/mounted folders
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
                                       completion: @escaping (Result<(id: String, pathLower: String?, name: String?), Error>) -> Void) {
        client.files.getMetadata(path: idOrPath).response { (resp: Files.Metadata?, err: CallError<Files.GetMetadataError>?) in
            if let folder = resp as? Files.FolderMetadata {
                completion(.success((folder.id, folder.pathLower, folder.name)))
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

    /// Resolve current absolute path for a saved selection (by id), root-safe.
    private func resolveCurrentPath(client: DropboxClient,
                                    selection: DBSelection,
                                    completion: @escaping (Result<String, Error>) -> Void) {
        if selection.folderId == Self.rootSelectionId {
            completion(.success("/"))
            return
        }
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
