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
    static let MAX_ALLOWED_CONCURRENT_TRANSCRIPTIONS: Int = 3
    
    init () {}
    
    func attach(viewController: ViewController, recordingMananger: RecordingManager) {
        self.viewController = viewController
        self.recordingManager = recordingMananger
    }
    
    enum TranscriptionError: LocalizedError {
        case error(String, underlying: Error? = nil)
        case uploadForbidden403   // ✅ special case

        var errorDescription: String? {
            switch self {
            case .error(let msg, let underlying):
                if let underlying { return "\(msg) – \(underlying.localizedDescription)" }
                return msg
            case .uploadForbidden403:
                return "Upload rejected with 403 (forbidden)."
            }
        }
    }

    
    /// Call this to upload, wait (max 20m), and get the signed URL to the transcript.
    func transcribeAudioFile(processedObjectInQueue: AudioTranscriptionObject) async throws {
        print("🟢 transcribeAudioFile: entered")

        // 1) Clear cached text & mark state
        await MainActor.run {
            print("🟢 transcribeAudioFile: clearing cached text")
            self.toggledTranscriptText = nil
            if (processedObjectInQueue.uuid == self.recordingManager.toggledAudioTranscriptionObject.uuid) {
                self.recordingManager.toggledAudioTranscriptionObject.transcriptionText = nil
                self.recordingManager.savedAudioTranscriptionObjects[self.recordingManager.toggledRecordingsIndex] =
                    self.recordingManager.toggledAudioTranscriptionObject
            }
        }

        // 2) Basic config guards
        guard let txtSignerBase = SignedTxtURLGCFunction else {
            print("❌ transcribeAudioFile: missing SignedTxtURLGCFunction")
            throw TranscriptionError.error("Transcription service not configured (text signer)")
        }
        guard SignedAudioUrlGCFunction != nil else {
            print("❌ transcribeAudioFile: missing SignedAudioUrlGCFunction")
            throw TranscriptionError.error("Transcription service not configured (audio signer)")
        }

        let transcriptFilename = "\(processedObjectInQueue.fileName)." +
                                 "\(recordingManager.transcriptionRecordingExtension)"

        // 3) Ensure we have a valid recording URL; reconstruct if needed
        let recordingURL: URL
        if let existing = recordingManager.getURLForAudioTranscriptionObject(at: processedObjectInQueue.uuid) {
            recordingURL = existing
        } else {
            let candidate = recordingManager.GetDirectory()
                .appendingPathComponent(processedObjectInQueue.fileName)
                .appendingPathExtension(recordingManager.audioRecordingExtension)

            if FileManager.default.fileExists(atPath: candidate.path) {
                print("ℹ️ transcribeAudioFile: reconstructed toggledRecordingURL from disk")
                recordingManager.toggledRecordingURL = candidate
                recordingURL = candidate
            } else {
                print("❌ transcribeAudioFile: no recording found on disk")
                throw TranscriptionError.error("No recording found to transcribe")
            }
        }

        // 5) Mint signed PUT for audio
        print("🟢 transcribeAudioFile: about to mintSignedURL()")
        guard let signedPUT = try? await mintSignedURL(processedObjectInQueue: processedObjectInQueue) else {
            print("❌ transcribeAudioFile: mintSignedURL returned nil or threw")
            throw TranscriptionError.error("Unable to obtain an upload URL")
        }

        // 6) Upload audio, then wait for transcript
        var signedTxtURL: URL

        do {
            let uploadStart = Date()
            try await uploadRecordingToCGBucket(to: signedPUT, from: recordingURL)
            print("✅ transcribeAudioFile: uploadRecordingToCGBucket finished")

            // Normal path: upload just succeeded, so give backend up to 20 min
            signedTxtURL = try await waitForTranscriptReady(
                txtSignerBase: txtSignerBase + "/sign",
                filename: transcriptFilename,
                hardCapSeconds: 20 * 60,
                pollInterval: 2,
                notBefore: uploadStart
            )
        } catch TranscriptionError.uploadForbidden403 {
            print("⚠️ transcribeAudioFile: upload 403 – assuming audio already uploaded, probing for existing transcript")

            // Weird case (e.g. phone died earlier and audio already in bucket):
            // short probe for an existing transcript so we don't hang forever.
            signedTxtURL = try await waitForTranscriptReady(
                txtSignerBase: txtSignerBase + "/sign",
                filename: transcriptFilename,
                hardCapSeconds: 60,     // 1 minute max in this special case
                pollInterval: 2,
                notBefore: nil
            )
        } catch {
            print("❌ transcribeAudioFile: upload failed: \(error)")
            throw TranscriptionError.error("Upload failed", underlying: error)
        }

        // 7) Download transcript and update local state/UI
        let localPath = recordingManager.GetDirectory()
            .appendingPathComponent(processedObjectInQueue.fileName)
            .appendingPathExtension(recordingManager.transcriptionRecordingExtension)

        do {
            
            let transcribedText: String? = try await downloadSignedFileAndReadText(
                from: signedTxtURL,
                to: localPath,
                overwrite: true
            )
            
            await MainActor.run {
                PersistFileToDisk(
                    newText: transcribedText ?? "",
                    editing: false,
                    recordingURL: recordingURL,
                    objectUUID: processedObjectInQueue.uuid
                )
            }
            
            UpdateTranscribingObjectInQueue(processedUUID: processedObjectInQueue.uuid, transcriptionText: transcribedText)
            
        } catch {
            throw TranscriptionError.error("Couldn’t download the transcript", underlying: error)
        }
    }
    
    func UpdateTranscribingObjectInQueue(processedUUID: UUID, transcriptionText: String?) {
        var popIndex: Int? = nil
        for (index, object) in recordingManager.transcribingAudioTranscriptionObjects.enumerated() where object.uuid == processedUUID {
            recordingManager.transcribingAudioTranscriptionObjects[index].hasTranscription = true
            recordingManager.transcribingAudioTranscriptionObjects[index].isTranscribing = false
            recordingManager.transcribingAudioTranscriptionObjects[index].transcriptionText = transcriptionText
            popIndex = index
        }
        
        var processedObjectInQueueWhenFinished = false
        for (index, object) in recordingManager.savedAudioTranscriptionObjects.enumerated() where object.uuid == processedUUID {
            recordingManager.savedAudioTranscriptionObjects[index].hasTranscription = true
            recordingManager.savedAudioTranscriptionObjects[index].isTranscribing = false
            recordingManager.savedAudioTranscriptionObjects[index].transcriptionText = transcriptionText
            
            if (processedUUID == recordingManager.toggledAudioTranscriptionObject.uuid) {
                recordingManager.toggledAudioTranscriptionObject.hasTranscription = true
                recordingManager.toggledAudioTranscriptionObject.isTranscribing = false
                recordingManager.toggledAudioTranscriptionObject.transcriptionText = transcriptionText
            }
            processedObjectInQueueWhenFinished = true
        }
        
        if !processedObjectInQueueWhenFinished {
            viewController.displayAlert(
                title: "Transcription not saved",
                message: "Your pending transcription and its recording moved outside the recording queue therefore were deleted. Please make sure to send your recordings to a destination before they fall outside the queue."
            )
        }
        
        recordingManager.saveAudioTranscriptionObjectsToUserDefaults()
        
        if let popIndex {
            recordingManager.transcribingAudioTranscriptionObjects.remove(at: popIndex)
        }
        
    }
    
    @MainActor
    func readToggledTextFileAndSetInAudioTranscriptObject() async throws {
        if (recordingManager.toggledAudioTranscriptionObject.transcriptionText != nil) {
            return
        }
        let toggledTranscriptFilePath = recordingManager.GetDirectory().appendingPathComponent(recordingManager.toggledAudioTranscriptionObject.fileName).appendingPathExtension(recordingManager.transcriptionRecordingExtension)
        if (!FileManager.default.fileExists(atPath: toggledTranscriptFilePath.path)) { return }
        
        let toggledText = try String(contentsOf: toggledTranscriptFilePath, encoding: .utf8)
        toggledTranscriptText = toggledText
        recordingManager.toggledAudioTranscriptionObject.transcriptionText = toggledText
        recordingManager.toggledAudioTranscriptionObject.hasTranscription = true
        recordingManager.savedAudioTranscriptionObjects[recordingManager.toggledRecordingsIndex] = recordingManager.toggledAudioTranscriptionObject
    }
    
    func PersistFileToDisk(newText: String, editing: Bool = false, recordingURL: URL?, objectUUID: UUID) {
        var finalText: String
        if (editing) {
            finalText = newText
        } else {
            finalText = normalizeTranscript(newText)
        }
        
        print("PersistFileToDisk finalText: \(finalText)")

        if let fileURL = recordingURL?.deletingPathExtension().appendingPathExtension(recordingManager.transcriptionRecordingExtension) {
            do {
                try finalText.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                print("⚠️ Failed to write updated transcript to disk")
            }
        } else {
            print("⚠️ No transcript file URL on toggledAudioTranscriptionObject")
        }
        
        if (recordingManager.toggledAudioTranscriptionObject.uuid == objectUUID) {
            Task {
                try await readToggledTextFileAndSetInAudioTranscriptObject()
            }
        }
    }
    
    func normalizeTranscript(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1) Collapse newlines -> spaces
        text = text
            .replacingOccurrences(of: #"\s*(?:\r\n|\r|\n|\u2028|\u2029)+\s*"#,
                                  with: " ",
                                  options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 2) Spoken punctuation -> symbols (with "literal" escape)
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
        var out: [String] = []

        func lower(_ s: String) -> String { s.lowercased() }
        func peek(_ i: Int) -> String? { (i < tokens.count) ? tokens[i] : nil }
        func attach(_ symbol: String) {
            if let last = out.last {
                if !last.hasSuffix(symbol) { out[out.count - 1] = last + symbol }
            } else { out.append(symbol) }
        }
        func dropLiteralAndKeep(_ word: String) { if !out.isEmpty { out.removeLast() }; out.append(word) }

        var i = 0
        while i < tokens.count {
            let cur = tokens[i]
            let curL = lower(cur)
            let prevWord = out.last ?? ""
            let prevIsLiteral = lower(prevWord) == "literal"
            let next = peek(i + 1)
            let nextL = lower(next ?? "")

            if curL == "question", nextL == "mark" {
                if prevIsLiteral { dropLiteralAndKeep(cur); i += 1; if let n = next { out.append(n) } }
                else { attach("?"); i += 1 }
                i += 1; continue
            }
            if curL == "exclamation", (nextL == "mark" || nextL == "point") {
                if prevIsLiteral { dropLiteralAndKeep(cur); i += 1; if let n = next { out.append(n) } }
                else { attach("!"); i += 1 }
                i += 1; continue
            }
            if ["period","comma","colon","semicolon"].contains(curL) {
                if prevIsLiteral { dropLiteralAndKeep(cur) }
                else { attach(["period":".","comma":",","colon":":","semicolon":" ;"][curL] ?? "") }
                i += 1; continue
            }
            out.append(cur)
            i += 1
        }

        // 3) Tidy spacing around punctuation
        var normalized = out.joined(separator: " ")
        normalized = normalized.replacingOccurrences(of: #"\s+([\.,!?\;:])"#,
                                                     with: "$1",
                                                     options: .regularExpression)
        normalized = normalized.replacingOccurrences(of: #"([\.,!?\;:])([^\s"'\)\]\}])"#,
                                                     with: "$1 $2",
                                                     options: .regularExpression)
        normalized = normalized.replacingOccurrences(of: #"\s{2,}"#,
                                                     with: " ",
                                                     options: .regularExpression)
                               .trimmingCharacters(in: .whitespacesAndNewlines)

        // 4) Capitalize the start of sentences (after ., !, ?)
        normalized = sentenceCase(normalized)

        return normalized.isEmpty ? "[Empty transcript]" : normalized
    }

    /// Capitalizes the first alphabetic character of the string and any
    /// alphabetic character that follows `.`, `!`, or `?` (skipping spaces/quotes/brackets).
    private func sentenceCase(_ s: String) -> String {
        var result = ""
        var capitalizeNext = true
        for ch in s {
            if capitalizeNext, ch.isLetter {
                result.append(String(ch).uppercased())
                capitalizeNext = false
            } else {
                result.append(ch)
            }
            if ".!?".contains(ch) { capitalizeNext = true }
            // If you keep newlines anywhere, uncomment:
            // if ch == "\n" { capitalizeNext = true }
        }
        return result
    }

    // MARK: - Polling with exponential backoff (cap: 2 minutes; hard cap: 20 minutes)

    private func waitForTranscriptReady(
        txtSignerBase: String,
        filename: String,
        hardCapSeconds: TimeInterval,
        pollInterval: TimeInterval,
        notBefore: Date? = nil
    ) async throws -> URL {
        let deadline = Date().addingTimeInterval(hardCapSeconds)
        var attempt = 0

        while Date() < deadline && !Task.isCancelled {
            attempt += 1
            do {
                let signedTxtURL = try await fetchSignedTxtURL(base: txtSignerBase, filename: filename)
                print("📝 [waitForTranscriptReady] attempt \(attempt) – got signed URL")

                if await objectIsFreshAndExists(at: signedTxtURL, notBefore: notBefore) {
                    print("✅ [waitForTranscriptReady] transcript is ready")
                    return signedTxtURL
                } else {
                    print("⌛ [waitForTranscriptReady] transcript not ready yet")
                }
            } catch {
                print("⚠️ [waitForTranscriptReady] /sign error on attempt \(attempt): \(error.localizedDescription)")
            }

            let delay = pollInterval
            let jitter = Double.random(in: 0...0.3)
            let sleepSeconds = delay + jitter
            print("⏱️ [waitForTranscriptReady] sleeping \(sleepSeconds)s")
            try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
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
        let token = try await AppServices.shared.getFreshIDToken()

        // Use base service URL; pass name via query (your handler reads req.query)
        var comps = URLComponents(string: base)!
        comps.queryItems = [
            .init(name: "name", value: filename),
            .init(name: "ts", value: String(Date().timeIntervalSince1970))
        ]

        var req = URLRequest(url: comps.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

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
        // Just log size for sanity
        let fileSizeBytes: Int64 = {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let n = attrs[.size] as? NSNumber {
                return n.int64Value
            }
            return 0
        }()
        print("⏱ uploadRecordingToCGBucket: size=\(fileSizeBytes)B")

        // Dedicated session with more generous timeouts
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60      // 60s of “no progress” before -1001
        config.timeoutIntervalForResource = 120    // Hard cap per request
        config.waitsForConnectivity = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true

        let session = URLSession(configuration: config)

        var req = URLRequest(
            url: signedURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 60 // keep in sync with timeoutIntervalForRequest
        )
        req.httpMethod = "PUT"
        req.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")

        let maxAttempts = 2
        var lastError: Error?

        for attempt in 1...maxAttempts {
            print("📤 Upload attempt \(attempt) starting at \(Date())")

            do {
                let (_, resp) = try await session.upload(for: req, fromFile: fileURL)

                guard let http = resp as? HTTPURLResponse else {
                    throw TranscriptionError.error("Upload failed – no HTTP response")
                }

                print("📥 Upload attempt \(attempt) got status \(http.statusCode) at \(Date())")

                if http.statusCode == 403 {
                    throw TranscriptionError.uploadForbidden403
                }

                guard (200...299).contains(http.statusCode) else {
                    throw TranscriptionError.error("Upload failed – server returned \(http.statusCode)")
                }

                print("✅ Upload OK on attempt \(attempt)")
                return
            } catch {
                lastError = error

                if let tErr = error as? TranscriptionError,
                   case .uploadForbidden403 = tErr {
                    throw tErr
                }

                let nsErr = error as NSError
                print("❌ Upload attempt \(attempt) error: domain=\(nsErr.domain) " +
                      "code=\(nsErr.code) desc=\(nsErr.localizedDescription) at \(Date())")

                let isTransientNetworkError =
                    nsErr.domain == NSURLErrorDomain &&
                    (nsErr.code == NSURLErrorNetworkConnectionLost ||
                     nsErr.code == NSURLErrorTimedOut ||
                     nsErr.code == NSURLErrorCannotFindHost ||
                     nsErr.code == NSURLErrorCannotConnectToHost)

                if isTransientNetworkError && attempt < maxAttempts {
                    print("⚠️ Transient upload error on attempt \(attempt) – will retry")
                    continue
                }

                throw TranscriptionError.error(
                    "Upload to transcription server failed",
                    underlying: error
                )
            }
        }

        throw TranscriptionError.error(
            "Upload to transcription server failed after retries",
            underlying: lastError
        )
    }


    func mintSignedURL(processedObjectInQueue: AudioTranscriptionObject) async throws -> URL? {
        print("🟣 mintSignedURL: starting at \(Date())")

        let token: String
        do {
            print("🟣 mintSignedURL: about to getFreshIDToken at \(Date())")
            token = try await AppServices.shared.getFreshIDToken()
            print("🟣 mintSignedURL: got token at \(Date())")
        } catch {
            print("❌ mintSignedURL: getFreshIDToken error: \(error)")
            return nil
        }

        // 2) Target base URL of the Cloud Run service for signedPut
        guard let signedPutBase = SignedAudioUrlGCFunction,
              let url = URL(string: signedPutBase) else {
            print("❌ mintSignedURL: bad SignedAudioUrlGCFunction")
            return nil
        }

        // 3) JSON body expected by your Node handler (req.body)
        let bucketPath = "\(processedObjectInQueue.fileName).\(recordingManager.audioRecordingExtension)"
        let body: [String: Any] = [
            "bucketPath": bucketPath,
            "contentType": "audio/mp4"
        ]

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            print("signedPut non-2xx")
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

