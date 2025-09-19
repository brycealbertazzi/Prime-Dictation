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

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        let dropboxAppKey = loadDropboxAppKey()
        DropboxClientsManager.setupWithAppKey(dropboxAppKey.trimmingCharacters(in: .whitespacesAndNewlines))
        
        return true
    }
    
    private func loadDropboxAppKey() -> String {
        guard var key = Bundle.main.object(forInfoDictionaryKey: "DROPBOX_APP_KEY") as? String else {
            fatalError("Missing DROPBOX_APP_KEY in Info.plist")
        }
        key = key.trimmingCharacters(in: .whitespacesAndNewlines)

        if key.hasPrefix("$(") {
            fatalError("DROPBOX_APP_KEY was not resolved. Define it in Build Settings/.xcconfig for this target & configuration.")
        }
        
        return key
    }
    
    func applicationDidFinishLaunching(_ application: UIApplication) {
        
    }
    
    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }
    
//    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
//        return MSALPublicClientApplication.handleMSALResponse(url, sourceApplication: options[UIApplication.OpenURLOptionsKey.sourceApplication] as? String)
//    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        let scheme = (url.scheme ?? "").lowercased()

        if scheme.hasPrefix("msauth") {
            let handled = MSALPublicClientApplication.handleMSALResponse(
                url,
                sourceApplication: options[UIApplication.OpenURLOptionsKey.sourceApplication] as? String
            )

            if handled {
                // We can't know success/failure yet — MSAL will call your acquireToken completion.
                DispatchQueue.main.async {
                    ProgressHUD.animate("Finalizing Microsoft sign-in…")
                }
            } else {
                DispatchQueue.main.async {
                    ProgressHUD.failed("Couldn’t handle Microsoft sign-in redirect")
                }
            }
            return handled
        }

        if scheme.hasPrefix("db-") {
            let handled = DropboxClientsManager.handleRedirectURL(
                url,
                includeBackgroundClient: false
            ) { authResult in
                switch authResult {
                case .success:
                    ProgressHUD.succeed("Logged into Dropbox")
                case .cancel:
                    print("User canceled Dropbox OAuth flow")
                    ProgressHUD.failed("Dropbox login canceled")
                case .error(let error, let description):
                    print("Dropbox error \(error): \(description ?? "")")
                    ProgressHUD.failed("Unable to log into Dropbox")
                case .none:
                    print("Dropbox: possibly wrong redirect URI")
                    ProgressHUD.failed("Unable to log into Dropbox")
                }
            }
            return handled
        }

        // Unknown scheme
        return false
    }

}

