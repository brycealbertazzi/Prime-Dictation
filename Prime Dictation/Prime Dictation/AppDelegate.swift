//
//  AppDelegate.swift
//  Prime Dictation
//
//  Created by Bryce Albertazzi on 7/28/19.
//  Copyright © 2019 Bryce Albertazzi. All rights reserved.
//

import UIKit
import SwiftyDropbox
import MSAL
import ProgressHUD
import GoogleSignIn
import FirebaseCore
import FirebaseAuth

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]?
    ) -> Bool {

        // Dropbox
        let dropboxAppKey = loadDropboxAppKey()
        DropboxClientsManager.setupWithAppKey(
            dropboxAppKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        // Firebase FIRST
        FirebaseApp.configure()
        Task { await AppServices.shared.rebindAuthToNewProjectOnce() }

        // Google Sign-In / Drive – use the MANUAL iOS client from Info.plist
        let GDClientID = loadGoogleDriveClientID()
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: GDClientID)

        StoreKitManager.shared.startObservingTransactions()
        return true
    }

    // MARK: - UISceneSession Lifecycle

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {

        let config = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )

        // Make sure you have a `SceneDelegate` class in your project
        config.delegateClass = SceneDelegate.self

        return config
    }

    func application(
        _ application: UIApplication,
        didDiscardSceneSessions sceneSessions: Set<UISceneSession>
    ) {
        // You can clean up any resources specific to discarded scenes here if needed.
    }

    // MARK: - URL Handling (Dropbox, Google, OneDrive)

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey : Any] = [:]
    ) -> Bool {

        let scheme = (url.scheme ?? "").lowercased()

        if scheme.hasPrefix("com.googleusercontent.apps") {
            return GIDSignIn.sharedInstance.handle(url)
        }

        if scheme.hasPrefix("msauth") {
            return AppServices.shared.oneDriveManager.handleRedirect(url: url, options: options)
        }

        if scheme.hasPrefix("db-") {
            // Forward to the same DropboxManager that started the flow
            return AppServices.shared.dropboxManager.handleRedirect(url: url)
        }

        // Unknown scheme
        return false
    }

    // MARK: - Private helpers

    private func loadDropboxAppKey() -> String {
        guard var key = Bundle.main.object(
            forInfoDictionaryKey: "DROPBOX_APP_KEY"
        ) as? String else {
            fatalError("Missing DROPBOX_APP_KEY in Info.plist")
        }
        key = key.trimmingCharacters(in: .whitespacesAndNewlines)

        if key.hasPrefix("$(") {
            fatalError("DROPBOX_APP_KEY was not resolved. Define it in Build Settings/.xcconfig for this target & configuration.")
        }

        return key
    }

    private func loadGoogleDriveClientID() -> String {
        guard var key = Bundle.main.object(
            forInfoDictionaryKey: "GIDClientID"
        ) as? String else {
            fatalError("Missing GIDClientID in Info.plist")
        }
        key = key.trimmingCharacters(in: .whitespacesAndNewlines)

        if key.hasPrefix("$(") {
            fatalError("GIDClientID was not resolved. Define it in Build Settings/.xcconfig for this target & configuration.")
        }

        return key
    }
}
