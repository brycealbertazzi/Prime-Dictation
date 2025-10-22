//
//  AppServices.swift
//  Prime Dictation
//
//  Created by Bryce Albertazzi on 9/26/25.
//  Copyright © 2025 Bryce Albertazzi. All rights reserved.
//
import Foundation

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
}
