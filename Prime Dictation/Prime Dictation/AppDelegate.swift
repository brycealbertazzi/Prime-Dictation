//
//  AppDelegate.swift
//  Prime Dictation
//
//  Created by Bryce Albertazzi on 7/28/19.
//  Copyright © 2019 Bryce Albertazzi. All rights reserved.
//

import UIKit
import ProgressHUD
import MSAL
import MSGraphClientSDK



@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    // https://albertazzi.sharepoint.com/sites/OfficeManager2/Dictation
    public static let kRedirectUri = "msauth.com.BryceAlbertazzi.Prime-Dictation://auth"
    public static let kClientID = "934509c9-d7d5-40a7-b5c6-19707ac3af8c"
    public static let kGraphEndpoint = "https://graph.microsoft.com/v1.0/sites/63b3c104-5f76-4d8b-baa8-4bd8bf8cc846,01b526a8-671d-49a9-b83b-bd1a592f60ac/drives/b!BMGzY3Zfi026qEvYv4zIRqgmtQEdZ6lJuDu9GlkvYKyi18sP5mm9RadO1FSfu2vm/root:/"
    public static let kAuthority = "https://login.microsoftonline.com/common"
    public static let directoryID = "feba6b01-0c47-4af9-b51f-cc3d264beaa9"
    public static let objectID = "d33bde92-9941-4abb-8af8-9f5a3f6d96cc"
    

    public static var publicClient: MSALPublicClientApplication?
    public static let kScopes: [String] = ["User.Read", "Files.ReadWrite.AppFolder", "Files.ReadWrite.All"/*, "Sites.ReadWrite.All"*/] // request permission to read the profile of the signed-in user
    
    public static var httpClient: MSHTTPClient?
    
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        // Set up the MS client App
        do {
            // Create the MSAL client
            try AppDelegate.publicClient = MSALPublicClientApplication(clientId: AppDelegate.kClientID)
        } catch {
            print("Error creating MSAL public client: \(error)")
            AppDelegate.publicClient = nil
        }
        
        return true
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

    // <HandleMsalResponseSnippet>
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {

        guard let sourceApplication = options[UIApplication.OpenURLOptionsKey.sourceApplication] as? String else {
            return false
        }

        return MSALPublicClientApplication.handleMSALResponse(url, sourceApplication: sourceApplication)
    }
    // </HandleMsalResponseSnippet>

}

