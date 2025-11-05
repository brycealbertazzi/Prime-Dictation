//
//  AppServices.swift
//  Prime Dictation
//
//  Created by Bryce Albertazzi on 9/26/25.
//  Copyright © 2025 Bryce Albertazzi. All rights reserved.
//
import Foundation
import FirebaseAuth

final class AppServices {
    static let shared = AppServices()

    // Keep one instance of each manager for the whole app
    let destinationManager = DestinationManager()
    let dropboxManager = DropboxManager()
    let oneDriveManager = OneDriveManager()
    let googleDriveManager = GoogleDriveManager()
    let emailManager = EmailManager()
    
    let recordingManager = RecordingManager()
    let transcriptionManager = TranscriptionManager()
    

    private init() {}
    
    func ensureSignedIn() async throws -> User {
        if let u = Auth.auth().currentUser {
            return u
        }
        let result = try await Auth.auth().signInAnonymously()
        return result.user
    }

    func getFreshIDToken() async throws -> String {
        let user = try await ensureSignedIn()
        let token = try await user.getIDTokenResult(forcingRefresh: true).token
        return token
    }
}
