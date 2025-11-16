//
//  AppServices.swift
//  Prime Dictation
//
//  Created by Bryce Albertazzi on 9/26/25.
//  Copyright © 2025 Bryce Albertazzi. All rights reserved.
//
import Foundation
import FirebaseAuth
import FirebaseCore

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

extension AppServices {
    /// Run once after migrating projects (e.g., after switching to prime-dictation-474316)
    @MainActor
    func rebindAuthToNewProjectOnce() async {
        // Gate with a flag if you like so it only runs after migration
        if let u = Auth.auth().currentUser {
            do { try await u.delete() } catch { try? Auth.auth().signOut() }
        }
        do {
            try await Auth.auth().signInAnonymously()
        } catch {
            print("❌ rebind signInAnonymously failed")
        }
    }

    func ensureSignedIn() async throws -> User {
        if let u = Auth.auth().currentUser {
            return u
        }
        do {
            let res = try await Auth.auth().signInAnonymously()
            return res.user
        } catch {
            print("❌ signInAnonymously error")
            throw error
        }
    }

    func getFreshIDToken() async throws -> String {
        let user = try await ensureSignedIn()
        do {
            let token = try await user.getIDTokenResult(forcingRefresh: true).token
            return token
        } catch {
            print("❌ getIDTokenResult error")
            throw error
        }
    }

    /// Local JWT decode (for debug only)
    private func decodeAudIss(fromJWT jwt: String) -> (aud: String, iss: String)? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2,
              let data = Data(base64Encoded:
                String(parts[1])
                  .replacingOccurrences(of: "-", with: "+")
                  .replacingOccurrences(of: "_", with: "/")
                  .padding(toLength: ((String(parts[1]).count+3)/4)*4, withPad: "=", startingAt: 0)
              ),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let aud = obj["aud"] as? String,
              let iss = obj["iss"] as? String
        else { return nil }
        return (aud, iss)
    }
}
