import ProgressHUD
import FirebaseAuth

struct SignedURLResponse: Decodable {
    let url: URL
}

private struct SignedURLPayload: Decodable {
    let url: String
}

class TranscriptionManager {
    var viewController: ViewController!
    var recordingManager: RecordingManager!
    let SignedAudioUrlGCFunction = Bundle.main.object(forInfoDictionaryKey: "SIGNED_URL_GC_FUNCTION") as? String
    let SignedTxtURLGCFunction = Bundle.main.object(forInfoDictionaryKey: "SIGNED_TXT_URL_GC_FUNCTION") as? String
    let GCBucketURL = Bundle.main.object(forInfoDictionaryKey: "GC_BUCKET_URL") as? String
    
    var toggledTranscriptText: String? = nil
    
    init () {}
    
    func attach(viewController: ViewController, recordingMananger: RecordingManager) {
        self.viewController = viewController
        self.recordingManager = recordingMananger
    }
    
    enum TranscriptionError: LocalizedError {
        case error(String, underlying: Error? = nil)

        var errorDescription: String? {
            switch self {
            case .error(let msg, let underlying):
                if let underlying { return "\(msg) – \(underlying.localizedDescription)" }
                return msg
            }
        }
    }
    
    /// Call this to upload, wait (max 20m), and get the signed URL to the transcript.
    func transcribeAudioFile() async throws {
        // Clear cache before transcription
        await MainActor.run {
            self.toggledTranscriptText = nil
            self.recordingManager.toggledAudioTranscriptionObject.transcriptionText = nil
            self.recordingManager.savedAudioTranscriptionObjects[self.recordingManager.toggledRecordingsIndex] =
                self.recordingManager.toggledAudioTranscriptionObject
        }
        await MainActor.run { viewController?.DisableUI() }
        defer { Task { await MainActor.run { self.viewController?.EnableUI() } } }

        guard let txtSignerBase = SignedTxtURLGCFunction else {
            throw TranscriptionError.error("Transcription service not configured (text signer)")
        }
        guard SignedAudioUrlGCFunction != nil else {
            throw TranscriptionError.error("Transcription service not configured (audio signer)")
        }
        guard let signedPUT = try? await mintSignedURL() else {
            throw TranscriptionError.error("Unable to obtain an upload URL")
        }
        guard let recordingURL = recordingManager.toggledRecordingURL else {
            throw TranscriptionError.error("No recording found to transcribe")
        }

        do {
            try await uploadRecordingToCGBucket(to: signedPUT, from: recordingURL)
        } catch {
            throw TranscriptionError.error("Upload failed", underlying: error)
        }

        let transcriptFilename = "\(recordingManager.toggledAudioTranscriptionObject.fileName).\(recordingManager.transcriptionRecordingExtension)"

        let signedTxtURL: URL
        do {
            let uploadStart = Date()

            signedTxtURL = try await waitForTranscriptReady(
                txtSignerBase: txtSignerBase + "/sign",
                filename: transcriptFilename,
                hardCapSeconds: 20 * 60,
                backoffCapSeconds: 60,
                notBefore: uploadStart
            )
        } catch {
            throw TranscriptionError.error("Transcription didn’t complete", underlying: error)
        }

        let localPath = recordingManager.GetDirectory()
            .appendingPathComponent(recordingManager.toggledAudioTranscriptionObject.fileName)
            .appendingPathExtension(recordingManager.transcriptionRecordingExtension)

        do {
            toggledTranscriptText = try await downloadSignedFileAndReadText(
                from: signedTxtURL,
                to: localPath,
                overwrite: true
            )
            await MainActor.run {
                recordingManager.UpdateToggledTranscriptionText(newText: toggledTranscriptText ?? "")
                recordingManager.savedAudioTranscriptionObjects[recordingManager.toggledRecordingsIndex].hasTranscription = true
                recordingManager.toggledAudioTranscriptionObject = recordingManager.savedAudioTranscriptionObjects[recordingManager.toggledRecordingsIndex]
                viewController.HasTranscriptionUI()
            }
        } catch {
            throw TranscriptionError.error("Couldn’t download the transcript", underlying: error)
        }
    }

    
    @MainActor
    func readToggledTextFileAndSetInAudioTranscriptObject() async throws {
        if (recordingManager.toggledAudioTranscriptionObject.transcriptionText != nil) {
            return
        }
        let toggledTranscriptFilePath = recordingManager.GetDirectory().appendingPathComponent(recordingManager.toggledAudioTranscriptionObject.fileName).appendingPathExtension(recordingManager.transcriptionRecordingExtension)
        if (!FileManager.default.fileExists(atPath: toggledTranscriptFilePath.path)) { return }
        
        let toggledText = try String(contentsOf: toggledTranscriptFilePath)
        recordingManager.toggledAudioTranscriptionObject.transcriptionText = toggledText
        recordingManager.savedAudioTranscriptionObjects[recordingManager.toggledRecordingsIndex] = recordingManager.toggledAudioTranscriptionObject
    }

    // MARK: - Polling with exponential backoff (cap: 2 minutes; hard cap: 20 minutes)

    private func waitForTranscriptReady(
        txtSignerBase: String,
        filename: String,
        hardCapSeconds: TimeInterval,
        backoffCapSeconds: TimeInterval,
        notBefore: Date? = nil                 // 👈 new
    ) async throws -> URL {
        let deadline = Date().addingTimeInterval(hardCapSeconds)
        var attempt = 0

        while Date() < deadline && !Task.isCancelled {
            attempt += 1
            do {
                let signedTxtURL = try await fetchSignedTxtURL(base: txtSignerBase, filename: filename)
                if await objectIsFreshAndExists(at: signedTxtURL, notBefore: notBefore) {   // 👈 freshness check
                    return signedTxtURL
                }
            } catch { /* /sign may 404 until ready; ignore and retry */ }

            let base: TimeInterval = 0.5, factor: Double = 1.1
            let delay = min(base * pow(factor, Double(attempt)), backoffCapSeconds)
            let jitter = Double.random(in: 0...0.3)
            try? await Task.sleep(nanoseconds: UInt64((delay + jitter) * 1_000_000_000))
        }

        if Task.isCancelled {
            throw NSError(domain: "TranscriptWait", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cancelled while waiting for \(filename)"])
        }
        throw NSError(domain: "TranscriptWait", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(filename)"])
    }

    // MARK: - /sign call
    private func fetchSignedTxtURL(base: String, filename: String) async throws -> URL {
        var comps = URLComponents(string: base)!
        comps.queryItems = [
            URLQueryItem(name: "name", value: filename),
            URLQueryItem(name: "ts", value: String(Date().timeIntervalSince1970)) // harmless on your /sign endpoint
        ]
        var req = URLRequest(url: comps.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.httpMethod = "GET"

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "SignCall", code: code, userInfo: [NSLocalizedDescriptionKey: "Non-2xx from /sign"])
        }
        let payload = try JSONDecoder().decode(SignedURLPayload.self, from: data)
        guard let signed = URL(string: payload.url) else { throw URLError(.badURL) }
        return signed
    }


    // MARK: - Existence probe (HEAD, fallback 1-byte Range GET)
    /// Returns true only if the object exists **and** its Last-Modified >= notBefore (if provided).
    private func objectIsFreshAndExists(at signedURL: URL, notBefore: Date?) async -> Bool {
        // RFC 1123 date parser for Last-Modified
        func parseHTTPDate(_ s: String) -> Date? {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = TimeZone(secondsFromGMT: 0)
            fmt.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
            return fmt.date(from: s)
        }

        // HEAD first
        do {
            var r = URLRequest(url: signedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            r.httpMethod = "HEAD"
            r.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            r.setValue("no-cache", forHTTPHeaderField: "Pragma")
            let (_, resp) = try await URLSession.shared.data(for: r)
            if let http = resp as? HTTPURLResponse {
                if http.statusCode == 404 { return false }
                if (200...299).contains(http.statusCode) {
                    if let nb = notBefore,
                       let lm = http.value(forHTTPHeaderField: "Last-Modified"),
                       let lmDate = parseHTTPDate(lm),
                       lmDate < nb {
                        // Object exists but it's from a previous run → keep polling
                        return false
                    }
                    return true
                }
            }
        } catch { /* fall through */ }

        // Fallback tiny GET (also no-cache)
        do {
            var r = URLRequest(url: signedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            r.httpMethod = "GET"
            r.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            r.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            r.setValue("no-cache", forHTTPHeaderField: "Pragma")
            let (_, resp) = try await URLSession.shared.data(for: r)
            if let http = resp as? HTTPURLResponse {
                if http.statusCode == 404 { return false }
                if http.statusCode == 304 { return false }
                if http.statusCode == 206 || http.statusCode == 200 {
                    if let nb = notBefore,
                       let lm = http.value(forHTTPHeaderField: "Last-Modified"),
                       let lmDate = parseHTTPDate(lm),
                       lmDate < nb {
                        return false
                    }
                    return true
                }
            }
        } catch { }

        return false
    }
    
    // MARK: - Download txt file with signed url and decode text
    // If `overwrite` is true, writes exactly to destinationURL (atomic replace if it exists).
    // Does NOT delete or modify any sibling " (n)" files.
    func downloadSignedFileAndReadText(
        from signedURL: URL,
        to destinationURL: URL,
        overwrite: Bool = false
    ) async throws -> String {
        let (tempURLFromSession, resp) = try await URLSession.shared.download(from: signedURL)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let dir = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Stage inside same directory (enables atomic replace on same volume)
        let stagingURL = dir.appendingPathComponent(".download-\(UUID().uuidString).part")
        try? FileManager.default.removeItem(at: stagingURL)
        try FileManager.default.moveItem(at: tempURLFromSession, to: stagingURL)

        var finalURL = destinationURL

        if overwrite {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                // Atomic replace existing file, preserving siblings
                let replacedURL = try FileManager.default.replaceItemAt(
                    destinationURL,
                    withItemAt: stagingURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
                finalURL = replacedURL ?? destinationURL
            } else {
                // No existing file with that exact name—move into place (siblings untouched)
                try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
                finalURL = destinationURL
            }
        } else {
            // Preserve "(n)" numbering behavior without altering siblings
            var numberedURL = destinationURL
            var i = 1
            let base = destinationURL.deletingPathExtension().lastPathComponent
            let ext  = destinationURL.pathExtension
            while FileManager.default.fileExists(atPath: numberedURL.path) {
                let numbered = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
                numberedURL = dir.appendingPathComponent(numbered)
                i += 1
            }
            try FileManager.default.moveItem(at: stagingURL, to: numberedURL)
            finalURL = numberedURL
        }

        // Decode text (charset-aware, then fallbacks)
        let data = try Data(contentsOf: finalURL)
        let text: String = {
            if let ct = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
               let charset = ct
                    .split(separator: ";")
                    .map({ $0.trimmingCharacters(in: .whitespaces) })
                    .first(where: { $0.hasPrefix("charset=") })?
                    .replacingOccurrences(of: "charset=", with: ""),
               let enc = [
                   "utf-8": String.Encoding.utf8,
                   "utf8": .utf8,
                   "iso-8859-1": .isoLatin1,
                   "latin1": .isoLatin1
               ][charset],
               let s = String(data: data, encoding: enc) {
                return s
            }
            if let s = String(data: data, encoding: .utf8) { return s }
            if let s = String(data: data, encoding: .isoLatin1) { return s }
            return String(decoding: data, as: UTF8.self)
        }()

        return text
    }

    // Charset-aware decoding helper (optional but handy)
    private func decodeText(_ data: Data, response: HTTPURLResponse? = nil) -> String {
        if let ct = response?.value(forHTTPHeaderField: "Content-Type"),
           let cs = parseCharset(from: ct),
           let enc = String.Encoding(charset: cs),
           let s = String(data: data, encoding: enc) {
            return s
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    private func parseCharset(from contentType: String) -> String? {
        // e.g. "text/plain; charset=utf-8"
        contentType
            .lowercased()
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { $0.hasPrefix("charset=") })?
            .replacingOccurrences(of: "charset=", with: "")
    }
    
    func uploadRecordingToCGBucket(to signedURL: URL, from fileURL: URL) async throws {
        let data = try Data(contentsOf: fileURL)

        var req = URLRequest(url: signedURL)
        req.httpMethod = "PUT"
        req.setValue("audio/mp4", forHTTPHeaderField: "Content-Type") // must match signing
        req.httpBody = data

        do {
            let (respData, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                print("❌ Not a HTTPURLResponse"); return
            }

            if http.statusCode != 200 {
                let bodyText = String(data: respData, encoding: .utf8) ?? "<non-utf8 \(respData.count) bytes>"
                print(bodyText)
                return
            }
            print("✅ Upload OK (\(data.count) bytes)")
        } catch {
            print("❌ URLSession error:", error)
        }
    }

    func mintSignedURL() async throws -> URL?  {
        var bearer: String = ""
        do {
            bearer = try await AppServices.shared.getFreshIDToken()
        } catch {
            print("Unable to fetch FirebaseAuth token")
            return nil
        }
        let bucketPath = "\(recordingManager.toggledAudioTranscriptionObject.fileName).\(recordingManager.audioRecordingExtension)"
        let contentType = "audio/mp4"
        var comps = URLComponents(string: "\(SignedAudioUrlGCFunction!)/signed-put")!
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
}

private extension String.Encoding {
    init?(charset: String) {
        switch charset.lowercased() {
        case "utf-8", "utf8": self = .utf8
        case "iso-8859-1", "latin1", "iso_8859-1": self = .isoLatin1
        case "utf-16", "utf16": self = .utf16
        default: return nil
        }
    }
}

