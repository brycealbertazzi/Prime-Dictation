import ProgressHUD
import FirebaseAuth

struct SignedURLResponse: Decodable {
    let url: URL
}

class TranscriptionManager {
    var viewController: ViewController!
    var recordingManager: RecordingManager!
    let SignedUrlGCFunction = Bundle.main.object(forInfoDictionaryKey: "SIGNED_URL_GC_FUNCTION") as? String
    let GCBucketURL = Bundle.main.object(forInfoDictionaryKey: "GC_BUCKET_URL") as? String
    
    init () {}
    
    func attach(viewController: ViewController, recordingMananger: RecordingManager) {
        self.viewController = viewController
        self.recordingManager = recordingMananger
    }
    
    func transcribeAudioFile() async -> String? {
        guard let signerBase = SignedUrlGCFunction, !signerBase.isEmpty else {
            print("SignedUrlGCFunction not set")
            return nil
        }
        guard let signedURL = try? await mintSignedURL() else {
            print("Unable to obtain signed URL")
            return nil
        }

        return ""
    }
    
    func mintSignedURL() async throws -> URL?  {
        var bearer: String = ""
        do {
            bearer = try await getFreshIDToken()
        } catch {
            print("Unable to fetch FirebaseAuth token")
            return nil
        }
        let bucketPath = "m4a-files/\(recordingManager.toggledRecordingName).\(recordingManager.audioRecordingExtension)"
        let contentType = "audio/mp4"
        var comps = URLComponents(string: "\(SignedUrlGCFunction!)/signed-put")!
        comps.queryItems = [
            .init(name: "bucketPath", value: bucketPath),
            .init(name: "contentType", value: contentType)
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") // must match API_BEARER on server

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }
        return try JSONDecoder().decode(SignedURLResponse.self, from: data).url
    }
    
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

