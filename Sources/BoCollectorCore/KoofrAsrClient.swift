import AVFoundation
import Foundation

public enum ASRTranscriptFormatter {
    private static let senseVoiceTagRegex = try! NSRegularExpression(pattern: #"<\|[^|>]+\|>"#)
    private static let multiSpaceRegex = try! NSRegularExpression(pattern: #"[ \t]+"#)
    private static let multiNewlineRegex = try! NSRegularExpression(pattern: #"\n{3,}"#)

    public static func cleanTranscript(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        var s = raw
        s = senseVoiceTagRegex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        s = multiSpaceRegex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        s = multiNewlineRegex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "\n\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func parseInstaboxMarkdown(_ mdText: String) -> String {
        let trimmed = mdText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let body: String
        if let range = mdText.range(of: "\n---\n") {
            body = String(mdText[range.upperBound...])
        } else {
            body = mdText
        }
        let cleaned = cleanTranscript(body)
        if cleaned.isEmpty || cleaned.contains("未检测到有效人声片段") {
            return ""
        }
        return cleaned
    }

    public static func applyTranscript(to article: ArticlePayload, transcript: String) -> ArticlePayload {
        var updated = article
        var metadata = updated.metadata
        let existingLayers = (metadata["extraction_layers"]?.arrayValue ?? []).compactMap(\.stringValue)
        var layers = existingLayers.filter { $0 != "koofr_asr_queued" }
        let oldContent = updated.content.trimmingCharacters(in: .whitespacesAndNewlines)

        let newContent: String
        if !transcript.isEmpty {
            if !layers.contains("instabox_koofr_asr") {
                layers.insert("instabox_koofr_asr", at: 0)
            }
            let speechSection = "## 视频口播全文\n\n\(transcript)"
            if !oldContent.contains("## 视频口播全文") {
                if !oldContent.isEmpty && !oldContent.hasPrefix("[抖音收藏](") {
                    newContent = "\(oldContent)\n\n\(speechSection)"
                } else {
                    newContent = speechSection
                }
            } else {
                newContent = oldContent
            }
            metadata["asr_status"] = .string("completed")
            metadata["has_full_content"] = .bool(true)
        } else {
            newContent = oldContent
            metadata["asr_status"] = .string("completed_empty")
            metadata["has_full_content"] = .bool(!layers.isEmpty || newContent.count >= 80)
        }

        metadata["extraction_layers"] = .array(layers.map(JSONValue.string))
        metadata["pipeline_raw"] = .object([
            "content": .string(newContent),
            "title": .string(updated.title),
        ])
        updated.content = newContent
        updated.metadata = metadata
        return updated
    }
}

public final class KoofrAsrClient: @unchecked Sendable {
    private static let safeStemRegex = try! NSRegularExpression(pattern: #"^[A-Za-z0-9_-]{1,80}$"#)
    private static let unsafeCharRegex = try! NSRegularExpression(pattern: #"[^A-Za-z0-9_-]"#)

    public let config: CollectorConfig
    public let logger: SafeLogger?
    private let http: HTTPTransport
    private let ownsHTTP: Bool
    private let runner: CommandRunner
    private var dirsEnsured = false

    public init(
        config: CollectorConfig,
        logger: SafeLogger? = nil,
        http: HTTPTransport? = nil,
        runner: CommandRunner = DefaultCommandRunner()
    ) {
        self.config = config
        self.logger = logger
        if let provided = http {
            self.http = provided
            self.ownsHTTP = false
        } else {
            self.http = URLSessionHTTPTransport(config: config)
            self.ownsHTTP = true
        }
        self.runner = runner
    }

    public func close() {
        if ownsHTTP {
            http.close()
        }
    }

    public static func findInstaboxBinary(preferred: String = "") -> String? {
        ExecutableLocator.find(
            preferred: preferred,
            binaryName: "instabox",
            extraCandidates: [
                "/usr/local/bin/instabox",
                "/opt/homebrew/bin/instabox",
                "~/.local/bin/instabox",
            ]
        )
    }

    private func sendWebDAV(
        method: String,
        urlString: String,
        headers: [String: String] = [:],
        uploadFile: URL? = nil,
        timeout: TimeInterval = 45.0
    ) throws -> HTTPResponseData {
        guard let url = URL(string: urlString) else {
            throw HTTPTransportError(message: "Invalid Koofr URL: \(urlString)")
        }
        let spec = HTTPRequestSpec(
            method: method,
            url: url,
            headers: headers,
            uploadFileURL: uploadFile,
            basicAuth: (config.koofrEmail, config.koofrAppPassword),
            timeout: timeout
        )
        return try http.send(spec)
    }

    public func ensureRemoteDirs() throws {
        if dirsEnsured || !config.hasKoofrWebdav {
            return
        }
        let sub = config.koofrSubdir
        let leafDirs = ["ASR/inbox/\(sub)", "ASR/output/\(sub)"]
        var missingLeaves: [String] = []

        for relDir in leafDirs {
            let cleanRel = relDir.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let resp = try sendWebDAV(
                method: "PROPFIND",
                urlString: "\(config.koofrWebdavURL)/\(cleanRel)",
                headers: ["Depth": "0"],
                timeout: 20.0
            )
            if resp.statusCode == 401 || resp.statusCode == 403 {
                throw NSError(domain: "KoofrWebDAV", code: resp.statusCode, userInfo: [NSLocalizedDescriptionKey: "Koofr WebDAV authentication failed (HTTP \(resp.statusCode))"])
            }
            if [200, 201, 204, 207].contains(resp.statusCode) {
                continue
            }
            if resp.statusCode == 404 || resp.statusCode == 405 {
                missingLeaves.append(cleanRel)
            } else {
                throw NSError(domain: "KoofrWebDAV", code: resp.statusCode, userInfo: [NSLocalizedDescriptionKey: "Koofr WebDAV directory check failed (HTTP \(resp.statusCode))"])
            }
        }

        if !missingLeaves.isEmpty {
            var createdPrefixes = Set<String>()
            for relDir in missingLeaves {
                var acc = ""
                for part in relDir.split(separator: "/").map(String.init) where !part.isEmpty {
                    acc += "/\(part)"
                    if createdPrefixes.contains(acc) { continue }
                    let resp = try sendWebDAV(
                        method: "MKCOL",
                        urlString: "\(config.koofrWebdavURL)\(acc)",
                        timeout: 20.0
                    )
                    if resp.statusCode == 401 || resp.statusCode == 403 {
                        throw NSError(domain: "KoofrWebDAV", code: resp.statusCode, userInfo: [NSLocalizedDescriptionKey: "Koofr WebDAV authentication failed (HTTP \(resp.statusCode))"])
                    }
                    if resp.statusCode >= 500 {
                        throw NSError(domain: "KoofrWebDAV", code: resp.statusCode, userInfo: [NSLocalizedDescriptionKey: "Koofr WebDAV MKCOL failed (HTTP \(resp.statusCode))"])
                    }
                    createdPrefixes.insert(acc)
                }
            }
        }

        dirsEnsured = true
    }

    public func uploadVideosToKoofr(_ videosMap: [String: URL]) throws -> [String: [String: JSONValue]] {
        guard !videosMap.isEmpty else { return [:] }
        guard config.asrEnabled else { return [:] }
        guard config.hasKoofrWebdav else {
            logger?.warn("Koofr WebDAV 凭据未配置，跳过无字幕视频上传")
            return [:]
        }

        try ensureRemoteDirs()
        let sub = config.koofrSubdir
        var uploaded: [String: [String: JSONValue]] = [:]
        let fm = FileManager.default

        for (idx, (origKey, mp4URL)) in videosMap.sorted(by: { $0.key < $1.key }).enumerated() {
            guard fm.fileExists(atPath: mp4URL.path),
                  let fileSize = ((try? fm.attributesOfItem(atPath: mp4URL.path)[.size]) as? NSNumber)?.int64Value,
                  fileSize > 0 else {
                continue
            }
            let sizeMB = Double(fileSize) / (1024.0 * 1024.0)
            if sizeMB > Double(config.maxVideoMB) {
                logger?.warn("[\(origKey)] 视频体积 \(String(format: "%.1f", sizeMB))MB 超过上限 \(config.maxVideoMB)MB，跳过上传 Koofr")
                continue
            }

            let stem = Self.sanitizeStem(origKey, fallbackIndex: idx)
            let ext = mp4URL.pathExtension.isEmpty ? "mp4" : mp4URL.pathExtension.lowercased()
            let inboxRel = "\(sub)/\(stem).\(ext)"
            let outMdRel = "\(sub)/\(stem).md"
            let targetURL = "\(config.koofrWebdavURL)/ASR/inbox/\(inboxRel)"

            var alreadyOnKoofr = false
            if let head = try? sendWebDAV(method: "HEAD", urlString: targetURL, timeout: 15.0),
               head.statusCode == 200,
               let clStr = head.header("content-length"),
               Int64(clStr.trimmingCharacters(in: .whitespaces)) == fileSize {
                alreadyOnKoofr = true
            }

            if !alreadyOnKoofr {
                do {
                    let resp = try sendWebDAV(
                        method: "PUT",
                        urlString: targetURL,
                        headers: ["Content-Type": "video/mp4"],
                        uploadFile: mp4URL,
                        timeout: 360.0
                    )
                    if ![200, 201, 204].contains(resp.statusCode) {
                        throw NSError(domain: "KoofrWebDAV", code: resp.statusCode, userInfo: [NSLocalizedDescriptionKey: "Koofr WebDAV upload failed for \(inboxRel): HTTP \(resp.statusCode)"])
                    }
                } catch let err as HTTPTransportError where err.isTimeout {
                    let head = try sendWebDAV(method: "HEAD", urlString: targetURL, timeout: 20.0)
                    let remoteLen = Int64((head.header("content-length") ?? "").trimmingCharacters(in: .whitespaces)) ?? -1
                    if !(head.statusCode == 200 && remoteLen == fileSize) {
                        throw err
                    }
                }
            }

            uploaded[origKey] = [
                "asr_status": .string("pending"),
                "asr_inbox_media": .string(inboxRel),
                "asr_remote_md": .string(outMdRel),
            ]
            let note = alreadyOnKoofr ? "已存在于 Koofr 网盘（免重传）" : "已直传视频至 Koofr 网盘"
            logger?.info("\(note): ASR/inbox/\(inboxRel) (\(String(format: "%.1f", sizeMB))MB)")
        }

        if !uploaded.isEmpty {
            let triggered = triggerInstaboxWorker()
            if triggered {
                logger?.info("已向 Instabox (\(config.instaboxAsrBox)) 发送异步转写指令；Mac 现在可随时合盖或关机")
            } else {
                logger?.warn("视频已安全存入 Koofr 网盘，但唤醒 Instabox 未成功（下次巡检将自动补触发）")
            }
        }
        return uploaded
    }

    /// Direct OpenAI-compatible ASR mode (extracts .m4a via native macOS AVFoundation without ffmpeg).
    public func transcribeVideoViaOpenAI(_ mp4URL: URL) -> String? {
        guard config.asrEnabled, config.hasOpenAIAsr else { return nil }
        let m4aURL = mp4URL.deletingPathExtension().appendingPathExtension("m4a")
        defer { try? FileManager.default.removeItem(at: m4aURL) }

        let audioFile: URL
        let mimeType: String
        if Self.extractAudioM4A(from: mp4URL, to: m4aURL) {
            audioFile = m4aURL
            mimeType = "audio/mp4"
        } else {
            audioFile = mp4URL
            mimeType = "video/mp4"
        }

        guard let fileData = try? Data(contentsOf: audioFile), !fileData.isEmpty,
              let endpoint = URL(string: "\(config.asrApiBase.trimmingTrailingSlashes())/audio/transcriptions") else {
            return nil
        }

        let boundary = "BoCollectorBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        appendField("model", config.asrModel)
        appendField("response_format", "json")
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioFile.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let spec = HTTPRequestSpec(
            method: "POST",
            url: endpoint,
            headers: [
                "Authorization": "Bearer \(config.asrApiKey)",
                "Content-Type": "multipart/form-data; boundary=\(boundary)",
            ],
            body: body,
            timeout: TimeInterval(max(30, config.asrTimeout))
        )
        guard let resp = try? http.send(spec), resp.statusCode < 400 else { return nil }
        if let json = try? resp.json(), let txt = json["text"]?.stringValue {
            let cleaned = ASRTranscriptFormatter.cleanTranscript(txt)
            return cleaned.isEmpty ? nil : cleaned
        }
        let fallback = ASRTranscriptFormatter.cleanTranscript(resp.text)
        return fallback.isEmpty ? nil : fallback
    }

    private static func extractAudioM4A(from inputURL: URL, to outputURL: URL) -> Bool {
        try? FileManager.default.removeItem(at: outputURL)
        let asset = AVURLAsset(url: inputURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            return false
        }
        session.outputURL = outputURL
        session.outputFileType = .m4a
        let sem = DispatchSemaphore(value: 0)
        let okBox = ResultBox<Bool>()
        Task {
            do {
                try await session.export(to: outputURL, as: .m4a)
                okBox.value = true
            } catch {
                okBox.value = false
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 90) == .timedOut {
            session.cancelExport()
            return false
        }
        guard okBox.value == true else { return false }
        let size = ((try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
        return size > 0
    }

    public func getInstaboxState(instaboxBin: String? = nil) -> (ok: Bool, state: String) {
        guard let bin = instaboxBin ?? Self.findInstaboxBinary(preferred: config.instaboxBin) else {
            return (false, "missing_cli")
        }
        do {
            let res = try runner.run(
                executable: bin,
                arguments: ["get", config.instaboxAsrBox, "--json"],
                currentDirectory: nil,
                environment: nil,
                timeout: 15
            )
            if res.exitCode == 0, !res.stdout.isEmpty,
               let json = try? JSONValue.parse(string: res.stdout) {
                let st = (json["state"]?.stringValue ?? "unknown").lowercased()
                return (true, st)
            }
            return (false, "code_\(res.exitCode)")
        } catch {
            return (false, "timeout_or_error")
        }
    }

    public func triggerInstaboxWorker() -> Bool {
        guard let bin = Self.findInstaboxBinary(preferred: config.instaboxBin) else {
            return false
        }
        let box = config.instaboxAsrBox
        let svc = config.instaboxAsrService

        var (ok, state) = getInstaboxState(instaboxBin: bin)
        guard ok else { return false }

        if state != "running" {
            let wakeAction: String
            if state == "paused" || state == "suspended" {
                wakeAction = "resume"
            } else if state == "stopped" {
                wakeAction = "start"
            } else {
                wakeAction = "wake"
            }
            _ = try? runner.run(executable: bin, arguments: [wakeAction, box], currentDirectory: nil, environment: nil, timeout: 60)
            (_, state) = getInstaboxState(instaboxBin: bin)
            guard state == "running" else { return false }
        }

        let remoteCmd = "set -e; test -f /data/workspace/koofr-asr/.env; test -x /data/workspace/koofr-asr/run_worker.sh; systemctl --user start --no-block \(svc)"
        guard let execRes = try? runner.run(
            executable: bin,
            arguments: ["exec", box, "--timeout", "25", "--", remoteCmd],
            currentDirectory: nil,
            environment: nil,
            timeout: 35
        ) else {
            return false
        }
        return execRes.exitCode == 0
    }

    public func fetchReadyTranscripts(pendingArticles: [ArticlePayload]) throws -> [String: (transcript: String, inboxRel: String)] {
        guard !pendingArticles.isEmpty, config.hasKoofrWebdav else { return [:] }
        var ready: [String: (String, String)] = [:]
        for art in pendingArticles {
            let artId = art.id
            let relMd = (art.metadata["asr_remote_md"]?.stringValue ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let relIn = (art.metadata["asr_inbox_media"]?.stringValue ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !artId.isEmpty, !relMd.isEmpty else { continue }

            let resp = try sendWebDAV(
                method: "GET",
                urlString: "\(config.koofrWebdavURL)/ASR/output/\(relMd)",
                timeout: 30.0
            )
            if resp.statusCode == 200 {
                ready[artId] = (ASRTranscriptFormatter.parseInstaboxMarkdown(resp.text), relIn)
            } else if resp.statusCode != 404 {
                throw NSError(domain: "KoofrWebDAV", code: resp.statusCode, userInfo: [NSLocalizedDescriptionKey: "Koofr WebDAV GET failed: HTTP \(resp.statusCode)"])
            }
        }
        return ready
    }

    public func deleteInboxMedia(_ inboxRel: String) {
        let cleanRel = inboxRel.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        guard !cleanRel.isEmpty, config.hasKoofrWebdav else { return }
        _ = try? sendWebDAV(
            method: "DELETE",
            urlString: "\(config.koofrWebdavURL)/ASR/inbox/\(cleanRel)",
            timeout: 20.0
        )
    }

    private static func sanitizeStem(_ raw: String, fallbackIndex: Int) -> String {
        let fullRange = NSRange(raw.startIndex..., in: raw)
        if safeStemRegex.firstMatch(in: raw, range: fullRange) != nil {
            return raw
        }
        let cleaned = unsafeCharRegex.stringByReplacingMatches(in: raw, range: fullRange, withTemplate: "_")
        return cleaned.isEmpty ? String(format: "item_%04d", fallbackIndex) : String(cleaned.prefix(80))
    }
}
