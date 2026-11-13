import Foundation

public enum FeedEndDetector {
    public static func detectFeedEnded(platform: String, payloads: [JSONValue]) -> Bool {
        func walk(_ node: JSONValue) -> Bool {
            switch node {
            case .object(let dict):
                if platform == "douyin", dict["aweme_list"]?.arrayValue != nil {
                    if let hasMore = dict["has_more"] {
                        let ended = (hasMore.intValue == 0) || (hasMore.boolValue == false)
                        let statusCode = dict["status_code"]?.intValue ?? 0
                        if ended && statusCode == 0 {
                            return true
                        }
                    }
                }
                if platform == "x_bookmarks",
                   dict["type"]?.stringValue == "TimelineTerminateTimeline",
                   dict["direction"]?.stringValue == "Bottom" {
                    return true
                }
                for val in dict.values {
                    if walk(val) { return true }
                }
                return false
            case .array(let arr):
                return arr.contains(where: walk)
            default:
                return false
            }
        }
        return payloads.contains(where: walk)
    }
}

// MARK: - Shared X GraphQL & Media Helpers

public enum XGraphQLHelpers {
    public static let infographicHints: [String] = [
        "cheat sheet", "cheatsheet", "infographic", "roadmap", "architecture", "diagram",
        "架构", "速查", "全览", "清单", "脑图", "一图", "总结图",
    ]

    private static let trailingTcoRegex = try! NSRegularExpression(pattern: #"\s*https://t\.co/[A-Za-z0-9]+\s*$"#)
    private static let urlStripRegex = try! NSRegularExpression(pattern: #"https?://\S+"#)
    private static let threadMarkerRegex = try! NSRegularExpression(pattern: #"(🧵|\bthread\b|\b1/\d+|\(1/\d+)"#, options: [.caseInsensitive])

    public static func unwrapTweetResult(_ node: JSONValue?) -> [String: JSONValue]? {
        guard let obj = node?.objectValue else { return nil }
        let typename = obj["__typename"]?.stringValue ?? ""
        if typename == "TweetWithVisibilityResults", let inner = obj["tweet"]?.objectValue {
            return inner
        }
        if typename == "TweetTombstone" || typename == "TweetUnavailable" {
            return nil
        }
        if obj["rest_id"] != nil && obj["legacy"]?.objectValue != nil {
            return obj
        }
        return nil
    }

    public struct XUserSummary {
        public var id: String
        public var name: String
        public var handle: String
        public var avatarURL: String
    }

    public static func extractUserInfo(_ tweetObj: [String: JSONValue]) -> XUserSummary {
        let userRes = tweetObj["core"]?["user_results"]?["result"]?.objectValue ?? [:]
        let uCore = userRes["core"]?.objectValue ?? [:]
        let uLegacy = userRes["legacy"]?.objectValue ?? [:]
        let handle = (uCore["screen_name"]?.stringValue ?? uLegacy["screen_name"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (uCore["name"]?.stringValue ?? uLegacy["name"]?.stringValue ?? handle).trimmingCharacters(in: .whitespacesAndNewlines)
        let uid = (userRes["rest_id"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawAvatar = (userRes["avatar"]?["image_url"]?.stringValue ?? uLegacy["profile_image_url_https"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_normal.", with: "_400x400.")
        return XUserSummary(id: uid, name: name, handle: handle, avatarURL: rawAvatar)
    }

    public static func expandURLs(_ text: String, urlEntities: [JSONValue]) -> String {
        guard !text.isEmpty else { return "" }
        var out = text
        for ent in urlEntities {
            guard let dict = ent.objectValue,
                  let shortU = dict["url"]?.stringValue, !shortU.isEmpty else {
                continue
            }
            let expanded = dict["expanded_url"]?.stringValue ?? dict["expandedUrl"]?.stringValue ?? shortU
            if !expanded.isEmpty {
                out = out.replacingOccurrences(of: shortU, with: expanded)
            }
        }
        out = trailingTcoRegex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func extractXArticle(_ tweetObj: [String: JSONValue]) -> (title: String, body: String, hasFullBlocks: Bool)? {
        guard let artRes = tweetObj["article"]?["article_results"]?["result"]?.objectValue, !artRes.isEmpty else {
            return nil
        }
        let title = (artRes["title"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = (artRes["preview_text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var blocks: [String] = []
        if let rawBlocks = artRes["content_state"]?["blocks"]?.arrayValue {
            for blk in rawBlocks {
                if let t = blk["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    blocks.append(t)
                }
            }
        }
        let body = blocks.isEmpty ? preview : blocks.joined(separator: "\n\n")
        if title.isEmpty && body.isEmpty { return nil }
        return (title, body, !blocks.isEmpty)
    }

    public static func extractTweetText(_ tweetObj: [String: JSONValue]) -> String {
        let legacy = tweetObj["legacy"]?.objectValue ?? [:]
        if let noteRes = tweetObj["note_tweet"]?["note_tweet_results"]?["result"]?.objectValue,
           let noteText = noteRes["text"]?.stringValue, !noteText.isEmpty {
            let noteURLs = noteRes["entity_set"]?["urls"]?.arrayValue ?? []
            let legURLs = legacy["entities"]?["urls"]?.arrayValue ?? []
            return expandURLs(noteText, urlEntities: noteURLs + legURLs)
        }
        let rawText = legacy["full_text"]?.stringValue ?? legacy["text"]?.stringValue ?? ""
        let legURLs = legacy["entities"]?["urls"]?.arrayValue ?? []
        return expandURLs(rawText, urlEntities: legURLs)
    }

    public static func hasThreadMarker(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return threadMarkerRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public static func buildTweetTitle(authorLabel: String, articleTitle: String?, text: String, tid: String) -> String {
        if let at = articleTitle, !at.isEmpty {
            return "x-\(authorLabel)-\(at)"
        }
        let firstLine = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
        let cleanFirst = urlStripRegex.stringByReplacingMatches(
            in: firstLine,
            range: NSRange(firstLine.startIndex..., in: firstLine),
            withTemplate: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet: String
        if cleanFirst.count > 28 {
            snippet = String(cleanFirst.prefix(28)) + "..."
        } else if !cleanFirst.isEmpty {
            snippet = cleanFirst
        } else {
            snippet = "推文 \(tid.suffix(6))"
        }
        return "x-\(authorLabel)-\(snippet)"
    }

    public static func parseTwitterDate(_ raw: String?) -> String? {
        guard let str = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty else {
            return nil
        }
        let twitterFmt = DateFormatter()
        twitterFmt.locale = Locale(identifier: "en_US_POSIX")
        twitterFmt.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        if let dt = twitterFmt.date(from: str) {
            return DateFormatting.isoTimestamp(dt)
        }
        twitterFmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        if let dt = twitterFmt.date(from: str) {
            return DateFormatting.isoTimestamp(dt)
        }
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let dt = isoFrac.date(from: str) {
            return DateFormatting.isoTimestamp(dt)
        }
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]
        if let dt = isoBasic.date(from: str) {
            return DateFormatting.isoTimestamp(dt)
        }
        return nil
    }

    public static func shouldRunInfographicVLM(text: String, photoURLs: [String], config: CollectorConfig, featureEnabled: Bool) -> Bool {
        guard config.hasVLM, featureEnabled, !photoURLs.isEmpty else { return false }
        if text.count < 180 { return true }
        let lower = text.lowercased()
        return infographicHints.contains(where: { lower.contains($0) })
    }

    public static func extractPhotosVLM(
        tweetId: String,
        photoURLs: [String],
        tweetText: String,
        author: String,
        config: CollectorConfig,
        http: HTTPTransport
    ) -> String? {
        let tmpDir = config.cacheDir.appendingPathComponent("media/x_\(tweetId)_\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var localPaths: [URL] = []
        for (idx, purl) in photoURLs.prefix(4).enumerated() {
            let dlURLStr = (!purl.contains("?") && purl.contains("twimg.com")) ? "\(purl)?name=large" : purl
            guard let dlURL = URL(string: dlURLStr) else { continue }
            let target = tmpDir.appendingPathComponent("img_\(idx).jpg")
            if let resp = try? http.send(HTTPRequestSpec(method: "GET", url: dlURL, timeout: 25.0)),
               resp.statusCode == 200, !resp.data.isEmpty {
                try? resp.data.write(to: target)
                localPaths.append(target)
            }
        }
        guard !localPaths.isEmpty else { return nil }

        let sysPrompt = "你是严谨的技术与商业信息图提取助手。请提取推文配图（信息图/速查表/截图/架构图）中的文字、命令、参数、对比表格与核心观点，整理为结构化 Markdown。"
        let userPrompt = "推文作者：\(author.isEmpty ? "未知" : author)\n推文正文：\(tweetText.isEmpty ? "（无）" : tweetText)\n\n请提取配图中的完整结构化信息（若图片仅为无关装饰配图且无实质文字，请仅回复“无实质文字信息”）："
        return VLMClient.extractImagesMarkdown(
            imagePaths: localPaths,
            prompt: userPrompt,
            systemPrompt: sysPrompt,
            config: config,
            http: http
        )
    }
}

// MARK: - X Bookmarks Parser

public enum XBookmarksParser {
    public static func parse(
        payloads: [JSONValue],
        domItems: [[String: JSONValue]]?,
        knownIds: [String],
        maxItems: Int,
        config: CollectorConfig,
        stopOnKnown: Bool = true,
        sourceName: String = "X 书签",
        http: HTTPTransport
    ) -> (articles: [ArticlePayload], seenIds: [String]) {
        let knownSet = Set(knownIds.filter { !$0.isEmpty })
        var rawTweets: [[String: JSONValue]] = []
        var seen = Set<String>()

        for payload in payloads {
            for node in iterGraphQLTweets(payload) {
                let tid = (node["rest_id"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !tid.isEmpty && !seen.contains(tid) {
                    seen.insert(tid)
                    rawTweets.append(node)
                }
            }
        }

        var orderedIds: [String] = []
        var articles: [ArticlePayload] = []
        let nowISO = DateFormatting.isoTimestamp()

        for tweetObj in rawTweets {
            let tid = (tweetObj["rest_id"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            orderedIds.append(tid)
            if knownSet.contains(tid) || knownSet.contains("x_\(tid)") {
                if stopOnKnown { break }
                continue
            }

            let legacy = tweetObj["legacy"]?.objectValue ?? [:]
            let user = XGraphQLHelpers.extractUserInfo(tweetObj)
            let handle = user.handle.isEmpty ? "i" : user.handle
            let authorDisplay: String
            if !user.name.isEmpty && !user.handle.isEmpty {
                authorDisplay = "\(user.name) (@\(handle))"
            } else {
                authorDisplay = user.name.isEmpty ? handle : user.name
            }
            let url = "https://x.com/\(handle)/status/\(tid)"
            let mainText = XGraphQLHelpers.extractTweetText(tweetObj)
            let xArt = XGraphQLHelpers.extractXArticle(tweetObj)

            let mediaList = legacy["extended_entities"]?["media"]?.arrayValue
                ?? legacy["entities"]?["media"]?.arrayValue
                ?? []
            var photoURLs: [String] = []
            var hasVideo = false
            for m in mediaList {
                guard let mDict = m.objectValue else { continue }
                let mType = mDict["type"]?.stringValue ?? ""
                if mType == "photo", let u = mDict["media_url_https"]?.stringValue, !u.isEmpty {
                    photoURLs.append(u)
                } else if mType == "video" || mType == "animated_gif" {
                    hasVideo = true
                }
            }

            var quotedMD = ""
            if let quotedTweet = XGraphQLHelpers.unwrapTweetResult(tweetObj["quoted_status_result"]?["result"]) {
                let qu = XGraphQLHelpers.extractUserInfo(quotedTweet)
                let qt = XGraphQLHelpers.extractTweetText(quotedTweet)
                if !qt.isEmpty {
                    let qAuthor = !qu.handle.isEmpty ? "@\(qu.handle)" : (qu.name.isEmpty ? "引用推文" : qu.name)
                    let qLines = qt.components(separatedBy: .newlines).map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n")
                    quotedMD = "> **引用 \(qAuthor)**：\n\(qLines)"
                }
            }

            let inReplyUser = legacy["in_reply_to_user_id_str"]?.stringValue ?? ""
            let isSelfReply = !inReplyUser.isEmpty && !user.id.isEmpty && inReplyUser == user.id
            let hasSelfThread = legacy["self_thread"] != nil && legacy["self_thread"] != .null
            let likelyThread = isSelfReply || hasSelfThread || XGraphQLHelpers.hasThreadMarker(mainText)
            let isIncompleteArticle = xArt != nil && !(xArt?.hasFullBlocks ?? true)

            var sections: [String] = []
            if let art = xArt, !art.title.isEmpty {
                sections.append("# \(art.title)")
            }
            if let art = xArt, !art.body.isEmpty {
                sections.append(art.body)
            }
            if !mainText.isEmpty && (xArt == nil || !(xArt?.body.contains(mainText) ?? false)) {
                sections.append(mainText)
            }
            if !quotedMD.isEmpty {
                sections.append(quotedMD)
            }

            var vlmMD: String? = nil
            if XGraphQLHelpers.shouldRunInfographicVLM(
                text: mainText,
                photoURLs: photoURLs,
                config: config,
                featureEnabled: config.xExtractInfographics
            ) {
                vlmMD = XGraphQLHelpers.extractPhotosVLM(
                    tweetId: tid,
                    photoURLs: photoURLs,
                    tweetText: mainText,
                    author: authorDisplay,
                    config: config,
                    http: http
                )
                if let extracted = vlmMD {
                    sections.append("## 配图结构化内容\n\n\(extracted)")
                }
            }

            if !photoURLs.isEmpty {
                let gallery = photoURLs.enumerated().map { "![配图 \($0.offset + 1)](\($0.element))" }.joined(separator: "\n")
                sections.append(gallery)
            }

            let joined = sections.filter { !$0.isEmpty }.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let content = joined.isEmpty ? "[X 书签](\(url))" : joined
            let title = XGraphQLHelpers.buildTweetTitle(
                authorLabel: user.name.isEmpty ? handle : user.name,
                articleTitle: xArt?.title,
                text: mainText,
                tid: tid
            )

            let hashtags: [String] = (legacy["entities"]?["hashtags"]?.arrayValue ?? []).compactMap { h in
                guard let t = h["text"]?.stringValue, !t.isEmpty else { return nil }
                return "#\(t)"
            }

            let metadata: [String: JSONValue] = [
                "tweet_id": .string(tid),
                "author_handle": .string(handle),
                "author_name": .string(user.name),
                "tags": .array(hashtags.map(JSONValue.string)),
                "photo_urls": .array(photoURLs.map(JSONValue.string)),
                "has_video": .bool(hasVideo),
                "likely_thread": .bool(likelyThread),
                "is_x_article": .bool(xArt != nil),
                "needs_thread_expansion": .bool(likelyThread || isIncompleteArticle),
                "vlm_extracted": .bool(vlmMD != nil),
                "has_full_content": .bool(!(likelyThread || isIncompleteArticle)),
                "favorite_count": .int(legacy["favorite_count"]?.intValue ?? 0),
                "bookmark_count": .int(legacy["bookmark_count"]?.intValue ?? 0),
            ]

            articles.append(
                ArticlePayload(
                    id: "x_\(tid)",
                    title: title,
                    content: content,
                    url: url,
                    source: ArticleSourceInfo(type: "x_bookmarks", name: sourceName, identifier: "https://x.com/i/bookmarks"),
                    author: authorDisplay,
                    publishedDate: XGraphQLHelpers.parseTwitterDate(legacy["created_at"]?.stringValue),
                    fetchedDate: nowISO,
                    metadata: metadata
                )
            )
            if articles.count >= maxItems { break }
        }

        if rawTweets.isEmpty, let domItems {
            for dom in domItems {
                let tid = (dom["id"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tid.isEmpty, !seen.contains(tid) else { continue }
                seen.insert(tid)
                orderedIds.append(tid)
                if knownSet.contains(tid) || knownSet.contains("x_\(tid)") {
                    if stopOnKnown { break }
                    continue
                }
                let handle = (dom["handle"]?.stringValue ?? "i").trimmingCharacters(in: .whitespacesAndNewlines)
                let text = (dom["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let url = dom["url"]?.stringValue?.nonEmpty ?? "https://x.com/\(handle)/status/\(tid)"
                let imgs = (dom["images"]?.arrayValue ?? []).compactMap(\.stringValue).filter { !$0.isEmpty }
                var parts: [String] = []
                if !text.isEmpty { parts.append(text) }
                if !imgs.isEmpty {
                    parts.append(imgs.enumerated().map { "![配图 \($0.offset + 1)](\($0.element))" }.joined(separator: "\n"))
                }
                let title = XGraphQLHelpers.buildTweetTitle(authorLabel: handle, articleTitle: nil, text: text, tid: tid)
                let content = parts.joined(separator: "\n\n").nonEmpty ?? url

                articles.append(
                    ArticlePayload(
                        id: "x_\(tid)",
                        title: title,
                        content: content,
                        url: url,
                        source: ArticleSourceInfo(type: "x_bookmarks", name: sourceName, identifier: "https://x.com/i/bookmarks"),
                        author: "@\(handle)",
                        publishedDate: XGraphQLHelpers.parseTwitterDate(dom["publishedAt"]?.stringValue),
                        fetchedDate: nowISO,
                        metadata: [
                            "tweet_id": .string(tid),
                            "author_handle": .string(handle),
                            "photo_urls": .array(imgs.map(JSONValue.string)),
                            "dom_fallback": .bool(true),
                            "has_full_content": .bool(true),
                        ]
                    )
                )
                if articles.count >= maxItems { break }
            }
        }

        return (articles, orderedIds)
    }

    private static func iterGraphQLTweets(_ payload: JSONValue) -> [[String: JSONValue]] {
        var results: [[String: JSONValue]] = []
        func walk(_ node: JSONValue) {
            switch node {
            case .object(let obj):
                if obj["type"]?.stringValue == "TimelineAddEntries",
                   let entries = obj["entries"]?.arrayValue {
                    for entry in entries {
                        guard let entryDict = entry.objectValue,
                              let entryId = entryDict["entryId"]?.stringValue,
                              entryId.hasPrefix("tweet-") else {
                            continue
                        }
                        let raw = entryDict["content"]?["itemContent"]?["tweet_results"]?["result"]
                        if let unwrapped = XGraphQLHelpers.unwrapTweetResult(raw) {
                            results.append(unwrapped)
                        }
                    }
                    return
                }
                for v in obj.values {
                    walk(v)
                }
            case .array(let arr):
                for item in arr { walk(item) }
            default:
                break
            }
        }
        walk(payload)
        return results
    }
}

// MARK: - Douyin Favorites Parser

public enum DouyinParser {
    public static let douyinReferer = "https://www.douyin.com/"
    public static let defaultUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    private static let htmlTagRegex = try! NSRegularExpression(pattern: #"<[^>]+>"#)
    private static let digitsOnlyRegex = try! NSRegularExpression(pattern: #"^\d+$"#)
    private static let hashtagFindRegex = try! NSRegularExpression(pattern: #"#([^\s#]{1,30})"#)
    private static let hashtagStripRegex = try! NSRegularExpression(pattern: #"#[^\s#]+"#)
    private static let wsCollapseRegex = try! NSRegularExpression(pattern: #"\s+"#)

    public static func parseSubtitleContent(_ rawText: String) -> String {
        let stripped = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return "" }

        if stripped.hasPrefix("{") || stripped.hasPrefix("[") {
            if let json = try? JSONValue.parse(string: stripped) {
                var lines: [String] = []
                if let obj = json.objectValue {
                    let items = obj["utterances"]?.arrayValue
                        ?? obj["body"]?.arrayValue
                        ?? obj["subtitles"]?.arrayValue
                        ?? obj["captions"]?.arrayValue
                    if let items {
                        for it in items {
                            let txt = it["text"]?.stringValue ?? it["content"]?.stringValue ?? it["value"]?.stringValue ?? ""
                            let clean = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !clean.isEmpty { lines.append(clean) }
                        }
                    } else if let events = obj["events"]?.arrayValue {
                        for ev in events {
                            for seg in ev["segs"]?.arrayValue ?? [] {
                                if let u = seg["utf8"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !u.isEmpty {
                                    lines.append(u)
                                }
                            }
                        }
                    }
                } else if let arr = json.arrayValue {
                    for it in arr {
                        let txt = it["text"]?.stringValue ?? it["content"]?.stringValue ?? ""
                        let clean = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !clean.isEmpty { lines.append(clean) }
                    }
                }
                var deduped: [String] = []
                for ln in lines where !ln.isEmpty && deduped.last != ln {
                    deduped.append(ln)
                }
                if !deduped.isEmpty {
                    return deduped.joined(separator: "\n")
                }
            }
        }

        var outLines: [String] = []
        for rawLn in stripped.components(separatedBy: .newlines) {
            var ln = rawLn.trimmingCharacters(in: .whitespacesAndNewlines)
            if ln.isEmpty || ln.uppercased().hasPrefix("WEBVTT") || ln.hasPrefix("NOTE") { continue }
            if ln.contains("-->") { continue }
            if digitsOnlyRegex.firstMatch(in: ln, range: NSRange(ln.startIndex..., in: ln)) != nil { continue }
            ln = htmlTagRegex.stringByReplacingMatches(in: ln, range: NSRange(ln.startIndex..., in: ln), withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !ln.isEmpty && outLines.last != ln {
                outLines.append(ln)
            }
        }
        return outLines.joined(separator: "\n")
    }

    public static func parse(
        payloads: [JSONValue],
        domItems: [[String: JSONValue]]?,
        knownIds: [String],
        maxItems: Int,
        config: CollectorConfig,
        asrClient: KoofrAsrClient,
        browser: BrowserCollecting?,
        spaceId: Int?,
        stopOnKnown: Bool = true,
        sourceName: String = "抖音收藏",
        logger: SafeLogger? = nil,
        http: HTTPTransport
    ) throws -> (articles: [ArticlePayload], seenIds: [String], queuedAsr: Int) {
        let knownSet = Set(knownIds.filter { !$0.isEmpty })
        var rawAwemes: [[String: JSONValue]] = []
        var seenIds = Set<String>()

        for payload in payloads {
            guard let obj = payload.objectValue else { continue }
            let awemeList = obj["aweme_list"]?.arrayValue ?? obj["data"]?["aweme_list"]?.arrayValue ?? []
            for item in awemeList {
                guard let aweme = item.objectValue else { continue }
                let aid = (aweme["aweme_id"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !aid.isEmpty && !seenIds.contains(aid) {
                    seenIds.insert(aid)
                    rawAwemes.append(aweme)
                }
            }
        }

        var orderedIds: [String] = []
        var targetAwemes: [[String: JSONValue]] = []
        for aweme in rawAwemes {
            let aid = (aweme["aweme_id"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            orderedIds.append(aid)
            if knownSet.contains(aid) || knownSet.contains("dy_\(aid)") {
                if stopOnKnown { break }
                continue
            }
            targetAwemes.append(aweme)
            if targetAwemes.count >= maxItems { break }
        }

        let workRoot = config.cacheDir.appendingPathComponent("media/douyin_batch_\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workRoot) }

        let nowISO = DateFormatting.isoTimestamp()

        struct ItemPlan {
            var aweme: [String: JSONValue]
            var isImageNote: Bool
            var itemDir: URL
            var imageKeys: [(key: String, url: String)] = []
            var subtitleKey: String? = nil
            var videoURL: String? = nil
            var subtitleText: String = ""
            var durationSec: Double = 0
            var videoKey: String? = nil
        }

        var phase1Downloads: [BrowserDownloadItem] = []
        var plans: [String: ItemPlan] = [:]

        for aweme in targetAwemes {
            let aid = (aweme["aweme_id"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let imagesRaw = aweme["images"]?.arrayValue ?? aweme["image_post_info"]?["images"]?.arrayValue ?? []
            let awemeType = aweme["aweme_type"]?.intValue ?? 0
            let isImageNote = !imagesRaw.isEmpty || [68, 2, 150].contains(awemeType)
            let itemDir = workRoot.appendingPathComponent("dy_\(aid)")
            try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)

            var plan = ItemPlan(aweme: aweme, isImageNote: isImageNote, itemDir: itemDir)
            if isImageNote {
                for (idx, imgVal) in imagesRaw.prefix(10).enumerated() {
                    if let imgObj = imgVal.objectValue, let imgURL = pickBestImageURL(imgObj) {
                        let dlKey = "\(aid)_img_\(idx)"
                        let dest = itemDir.appendingPathComponent(String(format: "card_%02d.jpg", idx))
                        phase1Downloads.append(BrowserDownloadItem(id: dlKey, url: imgURL, dest: dest.path))
                        plan.imageKeys.append((dlKey, imgURL))
                    }
                }
            } else {
                if let subURL = pickSubtitleURL(aweme) {
                    let dlKey = "\(aid)_sub"
                    let dest = itemDir.appendingPathComponent("subtitle.txt")
                    phase1Downloads.append(BrowserDownloadItem(id: dlKey, url: subURL, dest: dest.path))
                    plan.subtitleKey = dlKey
                }
                plan.videoURL = pickVideoStreamURL(aweme)
            }
            plans[aid] = plan
        }

        let phase1Saved = downloadDouyinFiles(phase1Downloads, browser: browser, spaceId: spaceId, http: http)

        var phase2Downloads: [BrowserDownloadItem] = []
        let canRunASR = config.asrEnabled && (
            (config.asrProvider == .instaboxKoofr && config.hasKoofrWebdav) ||
            (config.asrProvider == .openaiAPI && config.hasOpenAIAsr)
        )

        for aid in targetAwemes.compactMap({ $0["aweme_id"]?.stringValue }) {
            guard var plan = plans[aid], !plan.isImageNote else { continue }
            if let subKey = plan.subtitleKey, let subPath = phase1Saved[subKey],
               let rawSub = try? String(contentsOfFile: subPath, encoding: .utf8) {
                plan.subtitleText = parseSubtitleContent(rawSub)
            }
            let rawDur = plan.aweme["video"]?["duration"]?.intValue ?? 0
            let durSec = rawDur > 1000 ? Double(rawDur) / 1000.0 : Double(rawDur)
            plan.durationSec = durSec

            if plan.subtitleText.isEmpty,
               durSec <= Double(config.maxDurationMin * 60),
               canRunASR,
               let vURL = plan.videoURL {
                let vKey = "\(aid)_video"
                let vDest = plan.itemDir.appendingPathComponent("dy_\(aid).mp4")
                phase2Downloads.append(BrowserDownloadItem(id: vKey, url: vURL, dest: vDest.path))
                plan.videoKey = vKey
            }
            plans[aid] = plan
        }

        let phase2Saved = downloadDouyinFiles(phase2Downloads, browser: browser, spaceId: spaceId, http: http)

        var videosForKoofr: [String: URL] = [:]
        var directAsrTranscripts: [String: String] = [:]

        for aid in targetAwemes.compactMap({ $0["aweme_id"]?.stringValue }) {
            guard let plan = plans[aid], let vKey = plan.videoKey, let savedPath = phase2Saved[vKey] else { continue }
            let mp4URL = URL(fileURLWithPath: savedPath)
            if config.asrProvider == .openaiAPI {
                if let text = asrClient.transcribeVideoViaOpenAI(mp4URL) {
                    directAsrTranscripts["dy_\(aid)"] = text
                }
            } else {
                videosForKoofr["dy_\(aid)"] = mp4URL
            }
        }

        let queuedMap = videosForKoofr.isEmpty ? [:] : try asrClient.uploadVideosToKoofr(videosForKoofr)

        var articles: [ArticlePayload] = []
        for aweme in targetAwemes {
            let aid = (aweme["aweme_id"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let plan = plans[aid] else { continue }
            let isImageNote = plan.isImageNote
            let desc = (aweme["desc"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let authorObj = aweme["author"]?.objectValue ?? [:]
            let authorName = (authorObj["nickname"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let tags = extractDouyinTags(aweme: aweme, desc: desc)

            var publishedISO: String? = nil
            if let ct = aweme["create_time"]?.intValue, ct > 0 {
                publishedISO = DateFormatting.isoTimestamp(Date(timeIntervalSince1970: TimeInterval(ct)))
            }

            let url = isImageNote ? "https://www.douyin.com/note/\(aid)" : "https://www.douyin.com/video/\(aid)"
            var layers: [String] = []
            var sections: [String] = []
            if !desc.isEmpty {
                sections.append("**原帖文案**：\(desc)")
            }

            if isImageNote {
                let localImgs = plan.imageKeys.compactMap { phase1Saved[$0.key].map(URL.init(fileURLWithPath:)) }
                if !localImgs.isEmpty && config.hasVLM {
                    let sysP = "你是严谨的多模态知识提取助手。请完整、准确地提取这组图文卡片中的所有文字信息、清单条目、数据表格、工具名称、网址与核心结论，按阅读顺序整理为层次清晰的 Markdown。不要遗漏关键细节，不要编造。"
                    let usrP = "作者：\(authorName.isEmpty ? "未知" : authorName)\n原帖文案：\(desc.isEmpty ? "（无）" : desc)\n\n请提取这 \(localImgs.count) 张图文卡片中的完整文字与结构化要点（输出纯 Markdown 正文）："
                    if let vlmMD = VLMClient.extractImagesMarkdown(imagePaths: localImgs, prompt: usrP, systemPrompt: sysP, config: config, http: http) {
                        layers.append("image_note_vlm")
                        sections.append("## 图文卡片内容\n\n\(vlmMD)")
                    }
                }
            } else {
                if !plan.subtitleText.isEmpty {
                    layers.append("native_subtitle")
                    sections.append("## 视频口播全文\n\n\(plan.subtitleText)")
                } else if let apiText = directAsrTranscripts["dy_\(aid)"], !apiText.isEmpty {
                    layers.append("openai_asr")
                    sections.append("## 视频口播全文\n\n\(apiText)")
                } else if queuedMap["dy_\(aid)"] != nil {
                    layers.append("koofr_asr_queued")
                }
            }

            let joined = sections.filter { !$0.isEmpty }.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let content = joined.isEmpty ? "[抖音收藏](\(url))" : joined
            let title = cleanDouyinTitle(desc: desc, authorName: authorName, awemeId: aid)
            let nonQueueLayers = layers.filter { $0 != "koofr_asr_queued" }
            let stats = aweme["statistics"]?.objectValue ?? [:]
            let strippedDesc = hashtagStripRegex.stringByReplacingMatches(in: desc, range: NSRange(desc.startIndex..., in: desc), withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)

            var metadata: [String: JSONValue] = [
                "aweme_id": .string(aid),
                "media_kind": .string(isImageNote ? "image_note" : "video"),
                "author_name": .string(authorName),
                "author_unique_id": .string(authorObj["unique_id"]?.stringValue ?? authorObj["short_id"]?.stringValue ?? ""),
                "tags": .array(tags.map(JSONValue.string)),
                "duration_sec": .double(plan.durationSec),
                "extraction_layers": .array(layers.map(JSONValue.string)),
                "has_full_content": .bool(!nonQueueLayers.isEmpty || desc.count >= 80),
                "digg_count": .int(stats["digg_count"]?.intValue ?? 0),
                "collect_count": .int(stats["collect_count"]?.intValue ?? 0),
                "needs_smart_title": .bool(strippedDesc.count < 8),
            ]
            if !isImageNote, let qMeta = queuedMap["dy_\(aid)"] {
                for (k, v) in qMeta { metadata[k] = v }
            }

            articles.append(
                ArticlePayload(
                    id: "dy_\(aid)",
                    title: title,
                    content: content,
                    url: url,
                    source: ArticleSourceInfo(type: "douyin", name: sourceName, identifier: "https://www.douyin.com/user/self?showTab=favorite_collection"),
                    author: authorName.nonEmpty,
                    publishedDate: publishedISO,
                    fetchedDate: nowISO,
                    metadata: metadata
                )
            )
        }

        if rawAwemes.isEmpty, let domItems {
            for dom in domItems {
                let aid = (dom["id"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !aid.isEmpty, !seenIds.contains(aid) else { continue }
                seenIds.insert(aid)
                orderedIds.append(aid)
                if knownSet.contains(aid) || knownSet.contains("dy_\(aid)") {
                    if stopOnKnown { break }
                    continue
                }
                let rawTitle = (dom["title"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let kind = dom["kind"]?.stringValue ?? "video"
                let url = dom["url"]?.stringValue?.nonEmpty ?? "https://www.douyin.com/\(kind)/\(aid)"
                articles.append(
                    ArticlePayload(
                        id: "dy_\(aid)",
                        title: cleanDouyinTitle(desc: rawTitle, authorName: "", awemeId: aid),
                        content: rawTitle.nonEmpty ?? url,
                        url: url,
                        source: ArticleSourceInfo(type: "douyin", name: sourceName, identifier: "https://www.douyin.com/user/self?showTab=favorite_collection"),
                        author: nil,
                        publishedDate: nil,
                        fetchedDate: nowISO,
                        metadata: [
                            "aweme_id": .string(aid),
                            "media_kind": .string(kind == "note" ? "image_note" : "video"),
                            "dom_fallback": .bool(true),
                            "has_full_content": .bool(false),
                        ]
                    )
                )
                if articles.count >= maxItems { break }
            }
        }

        return (articles, orderedIds, queuedMap.count)
    }

    private static func pickBestImageURL(_ imgObj: [String: JSONValue]) -> String? {
        let urls = (imgObj["url_list"]?.arrayValue ?? imgObj["download_url_list"]?.arrayValue ?? [])
            .compactMap(\.stringValue)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !urls.isEmpty else { return nil }
        for u in urls {
            let low = u.lowercased()
            if low.contains(".jpeg") || low.contains(".jpg") || low.contains(".png") {
                return u
            }
        }
        return urls.last
    }

    private static func pickSubtitleURL(_ aweme: [String: JSONValue]) -> String? {
        let video = aweme["video"]?.objectValue ?? [:]
        var candidates: [JSONValue] = []
        for container in [video, aweme] {
            if let caps = container["cla_info"]?["caption_infos"]?.arrayValue {
                candidates.append(contentsOf: caps)
            }
            if let subs = container["subtitle_infos"]?.arrayValue {
                candidates.append(contentsOf: subs)
            }
        }
        for item in candidates {
            guard let dict = item.objectValue else { continue }
            if let u = dict["url"]?.stringValue?.nonEmpty { return u }
            if let first = dict["url_list"]?.arrayValue?.first?.stringValue?.nonEmpty { return first }
        }
        return nil
    }

    private static func pickVideoStreamURL(_ aweme: [String: JSONValue]) -> String? {
        let video = aweme["video"]?.objectValue ?? [:]
        var addrs: [JSONValue?] = [
            video["play_addr"],
            video["play_addr_h264"],
            video["play_addr_265"],
        ]
        if let bitRates = video["bit_rate"]?.arrayValue {
            for br in bitRates {
                addrs.append(br["play_addr"])
            }
        }
        addrs.append(video["download_addr"])
        for addr in addrs {
            if let list = addr?["url_list"]?.arrayValue {
                for u in list {
                    if let s = u.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), s.hasPrefix("http") {
                        return s
                    }
                }
            }
        }
        return nil
    }

    private static func extractDouyinTags(aweme: [String: JSONValue], desc: String) -> [String] {
        var tags: [String] = []
        for extra in aweme["text_extra"]?.arrayValue ?? [] {
            if let name = extra["hashtag_name"]?.stringValue?.nonEmpty {
                let t = "#\(name)"
                if !tags.contains(t) { tags.append(t) }
            }
        }
        let nsDesc = desc as NSString
        let matches = hashtagFindRegex.matches(in: desc, range: NSRange(location: 0, length: nsDesc.length))
        for m in matches where m.numberOfRanges >= 2 {
            let t = "#\(nsDesc.substring(with: m.range(at: 1)))"
            if !tags.contains(t) { tags.append(t) }
        }
        return tags
    }

    private static func cleanDouyinTitle(desc: String, authorName: String, awemeId: String) -> String {
        var cleaned = hashtagStripRegex.stringByReplacingMatches(in: desc, range: NSRange(desc.startIndex..., in: desc), withTemplate: "")
        cleaned = wsCollapseRegex.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: " ")
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r-—|｜,，。!！?？"))
        let snippet: String
        if cleaned.count > 28 {
            snippet = String(cleaned.prefix(28)) + "..."
        } else if !cleaned.isEmpty {
            snippet = cleaned
        } else {
            snippet = "作品 \(awemeId.suffix(6))"
        }
        let prefix = authorName.isEmpty ? "抖音收藏" : "抖音-\(authorName)"
        return "\(prefix)-\(snippet)"
    }

    private static func downloadDouyinFiles(
        _ downloads: [BrowserDownloadItem],
        browser: BrowserCollecting?,
        spaceId: Int?,
        http: HTTPTransport
    ) -> [String: String] {
        guard !downloads.isEmpty else { return [:] }
        var succeeded: [String: String] = [:]
        if let browser, browser.isAvailable() {
            let fromBrowser = browser.downloadMediaBatch(
                downloads: downloads,
                referer: douyinReferer,
                spaceId: spaceId,
                finishWhenDone: false
            )
            succeeded.merge(fromBrowser) { _, new in new }
        }

        let remaining = downloads.filter { succeeded[$0.id] == nil }
        if !remaining.isEmpty {
            let headers = ["Referer": douyinReferer, "User-Agent": defaultUA]
            for item in remaining {
                guard let url = URL(string: item.url) else { continue }
                let destURL = URL(fileURLWithPath: item.dest)
                try? FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let spec = HTTPRequestSpec(method: "GET", url: url, headers: headers, timeout: 60.0)
                if let urlSessionTransport = http as? URLSessionHTTPTransport {
                    if (try? urlSessionTransport.downloadToFile(spec, destination: destURL)) == true {
                        succeeded[item.id] = destURL.path
                    }
                } else if let resp = try? http.send(spec), resp.statusCode == 200, !resp.data.isEmpty {
                    if (try? resp.data.write(to: destURL)) != nil {
                        succeeded[item.id] = destURL.path
                    }
                }
            }
        }
        return succeeded
    }
}
