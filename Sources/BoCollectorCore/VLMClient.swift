import Foundation

public enum VLMClient {
    public static func extractImagesMarkdown(
        imagePaths: [URL],
        prompt: String,
        systemPrompt: String,
        config: CollectorConfig,
        http: HTTPTransport
    ) -> String? {
        guard config.hasVLM else { return nil }
        let fm = FileManager.default
        let validImages = imagePaths.filter { url in
            guard fm.fileExists(atPath: url.path),
                  let size = ((try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue else {
                return false
            }
            return size > 0
        }.prefix(10)

        guard !validImages.isEmpty else { return nil }

        var userContent: [JSONValue] = [
            .object(["type": .string("text"), "text": .string(prompt)])
        ]
        for imgURL in validImages {
            guard let rawData = try? Data(contentsOf: imgURL), !rawData.isEmpty else { continue }
            let mime = guessImageMimeType(for: imgURL)
            let b64 = rawData.base64EncodedString()
            userContent.append(
                .object([
                    "type": .string("image_url"),
                    "image_url": .object([
                        "url": .string("data:\(mime);base64,\(b64)")
                    ]),
                ])
            )
        }
        guard userContent.count > 1 else { return nil }

        let body: JSONValue = .object([
            "model": .string(config.vlmModel),
            "messages": .array([
                .object(["role": .string("system"), "content": .string(systemPrompt)]),
                .object(["role": .string("user"), "content": .array(userContent)]),
            ]),
            "temperature": .double(0.2),
            "max_tokens": .int(4096),
        ])

        guard let endpoint = URL(string: "\(config.vlmApiBase.trimmingTrailingSlashes())/chat/completions"),
              let bodyData = try? body.toData() else {
            return nil
        }

        let spec = HTTPRequestSpec(
            method: "POST",
            url: endpoint,
            headers: [
                "Authorization": "Bearer \(config.vlmApiKey)",
                "Content-Type": "application/json",
            ],
            body: bodyData,
            timeout: TimeInterval(max(15, config.vlmTimeout))
        )

        do {
            let resp = try http.send(spec)
            guard resp.statusCode < 400 else { return nil }
            let json = try resp.json()
            guard let firstChoice = json["choices"]?.arrayValue?.first,
                  let msg = firstChoice["message"] else {
                return nil
            }
            let rawText: String
            if let str = msg["content"]?.strictString {
                rawText = str
            } else if let arr = msg["content"]?.arrayValue {
                rawText = arr.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
            } else {
                rawText = ""
            }
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            if trimmed.contains("无实质文字信息") && trimmed.count < 25 {
                return nil
            }
            return trimmed
        } catch {
            return nil
        }
    }

    public static func testConnection(config: CollectorConfig, http: HTTPTransport) -> (ok: Bool, detail: String) {
        guard !config.vlmApiBase.isEmpty, !config.vlmApiKey.isEmpty, !config.vlmModel.isEmpty else {
            return (false, "请填写 VLM API Base、API Key 与模型名")
        }
        guard let endpoint = URL(string: "\(config.vlmApiBase.trimmingTrailingSlashes())/chat/completions") else {
            return (false, "VLM API Base URL 格式无效")
        }
        let body: JSONValue = .object([
            "model": .string(config.vlmModel),
            "messages": .array([
                .object(["role": .string("user"), "content": .string("Reply with OK only.")])
            ]),
            "max_tokens": .int(8),
            "temperature": .double(0.0),
        ])
        guard let data = try? body.toData() else {
            return (false, "序列化请求失败")
        }
        let spec = HTTPRequestSpec(
            method: "POST",
            url: endpoint,
            headers: [
                "Authorization": "Bearer \(config.vlmApiKey)",
                "Content-Type": "application/json",
            ],
            body: data,
            timeout: 25
        )
        do {
            let resp = try http.send(spec)
            if resp.statusCode >= 400 {
                return (false, "HTTP \(resp.statusCode): \(String(resp.text.prefix(120)))")
            }
            let json = try resp.json()
            let reply = json["choices"]?.arrayValue?.first?["message"]?["content"]?.stringValue ?? "ok"
            return (true, "连通正常 (\(config.vlmModel)) · 响应: \(reply.prefix(30))")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private static func guessImageMimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        default: return "image/jpeg"
        }
    }
}
