import Foundation

public enum XMonitorFilter {
    private static let reservedPaths: Set<String> = [
        "home", "explore", "notifications", "messages", "bookmarks", "lists", "communities",
        "i", "search", "settings", "compose", "login", "logout", "signup", "tos", "privacy",
        "intent", "share", "hashtag", "jobs", "grok",
    ]
    private static let handleRegex = try! NSRegularExpression(pattern: #"^[A-Za-z0-9_]{1,15}$"#)
    private static let listURLRegex = try! NSRegularExpression(pattern: #"(?:x\.com|twitter\.com)/i/lists/(\d+)"#, options: [.caseInsensitive])
    private static let urlRegex = try! NSRegularExpression(pattern: #"https?://\S+"#)
    private static let leadingMentionsRegex = try! NSRegularExpression(pattern: #"^(?:@[A-Za-z0-9_]{1,15}\s*)+"#)
    private static let wsRegex = try! NSRegularExpression(pattern: #"\s+"#)
    private static let xMediaPathRegex = try! NSRegularExpression(pattern: #"/status/\d+/(?:photo|video)/\d+"#)
    private static let splitHandlesRegex = try! NSRegularExpression(pattern: #"[\s,;，；、]+"#)

    public static func normalizeHandle(_ raw: String) -> String? {
        var val = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !val.isEmpty else { return nil }

        let lowStart = val.lowercased()
        if val.contains("://") || lowStart.hasPrefix("x.com/") || lowStart.hasPrefix("twitter.com/")
            || lowStart.hasPrefix("www.x.com/") || lowStart.hasPrefix("www.twitter.com/") {
            let toParse = val.contains("://") ? val : "https://\(val)"
            guard let parsed = URL(string: toParse),
                  let host = parsed.host?.lowercased(),
                  ["x.com", "www.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com"].contains(host) else {
                return nil
            }
            let parts = parsed.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            guard let first = parts.first else { return nil }
            val = first
        }

        val = val.trimmingCharacters(in: CharacterSet(charactersIn: " @/"))
        guard !val.isEmpty,
              handleRegex.firstMatch(in: val, range: NSRange(val.startIndex..., in: val)) != nil else {
            return nil
        }
        let lowered = val.lowercased()
        if reservedPaths.contains(lowered) { return nil }
        return lowered
    }

    public static func parseHandles(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let ns = trimmed as NSString
        var tokens: [String] = []
        var lastIdx = 0
        for m in splitHandlesRegex.matches(in: trimmed, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > lastIdx {
                tokens.append(ns.substring(with: NSRange(location: lastIdx, length: m.range.location - lastIdx)))
            }
            lastIdx = m.range.location + m.range.length
        }
        if lastIdx < ns.length {
            tokens.append(ns.substring(from: lastIdx))
        }

        var seen = Set<String>()
        var result: [String] = []
        for tok in tokens {
            if let h = normalizeHandle(tok), !seen.contains(h) {
                seen.insert(h)
                result.append(h)
            }
        }
        return result
    }

    public static func normalizeListURL(_ raw: String) -> String {
        let val = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !val.isEmpty else { return "" }
        if val.allSatisfy(\.isNumber) {
            return "https://x.com/i/lists/\(val)"
        }
        let ns = val as NSString
        if let m = listURLRegex.firstMatch(in: val, range: NSRange(location: 0, length: ns.length)),
           m.numberOfRanges >= 2 {
            return "https://x.com/i/lists/\(ns.substring(with: m.range(at: 1)))"
        }
        return ""
    }

    public static func cleanTextForLength(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        var s = urlRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        s = leadingMentionsRegex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        s = wsRegex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isExternalExpandedURL(_ raw: String?) -> Bool {
        guard let u = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              u.hasPrefix("http://") || u.hasPrefix("https://"),
              let parsed = URL(string: u),
              let host = parsed.host?.lowercased(),
              !host.isEmpty,
              host != "t.co" else {
            return false
        }
        if ["x.com", "www.x.com", "twitter.com", "www.twitter.com", "pic.x.com", "pic.twitter.com"].contains(host) {
            if host == "pic.x.com" || host == "pic.twitter.com" { return false }
            let path = parsed.path
            if xMediaPathRegex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil {
                return false
            }
        }
        return true
    }

    public static func shouldKeepTweet(
        text: String,
        isPromoted: Bool = false,
        isRetweet: Bool = false,
        isReply: Bool = false,
        isSelfReply: Bool = false,
        hasMedia: Bool = false,
        hasExternalURL: Bool = false,
        hasQuote: Bool = false,
        isXArticle: Bool = false,
        includeRetweets: Bool = false,
        includeReplies: Bool = false,
        minTextLength: Int = 20
    ) -> (keep: Bool, reason: String) {
        if isPromoted { return (false, "promoted") }
        if isRetweet && !includeRetweets { return (false, "retweet") }
        if isReply && !isSelfReply && !includeReplies { return (false, "reply_to_other") }

        let hasRichAttachment = hasMedia || hasExternalURL || hasQuote || isXArticle
        if !hasRichAttachment && minTextLength > 0 {
            let cleanLen = cleanTextForLength(text).count
            if cleanLen < minTextLength {
                return (false, "short_text(\(cleanLen)<\(minTextLength))")
            }
        }
        return (true, "kept")
    }

    public static func tweetIdUInt64(_ raw: String?) -> UInt64 {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return 0 }
        return UInt64(s) ?? 0
    }

    public static func maxTweetId(_ a: String?, _ b: String?) -> String {
        let ia = tweetIdUInt64(a)
        let ib = tweetIdUInt64(b)
        if ib > ia { return (b ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        if ia > 0 { return (a ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        return (b ?? a ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - X User Monitor Engine (Local ego-lite GraphQL/DOM + L2 Passive Raw -> Cloud bo-distiller)

public final class XMonitorEngine: @unchecked Sendable {
    public let config: CollectorConfig
    public let browser: BrowserCollecting
    public let http: HTTPTransport
    public let logger: SafeLogger?

    public init(
        config: CollectorConfig,
        browser: BrowserCollecting,
        http: HTTPTransport,
        logger: SafeLogger? = nil
    ) {
        self.config = config
        self.browser = browser
        self.http = http
        self.logger = logger
    }

    public func effectiveMonitorConfig(remote: XMonitorRemoteConfig?) -> XMonitorRemoteConfig {
        var merged = remote ?? XMonitorRemoteConfig()
        let localList = XMonitorFilter.normalizeListURL(config.xMonitorListURL)
        if !localList.isEmpty {
            merged.listURL = localList
        }
        if config.xMonitorMaxItemsPerUser > 0 {
            merged.maxItemsPerUser = config.xMonitorMaxItemsPerUser
        }
        if config.xMonitorDefaultMinLength >= 0 {
            merged.defaultMinTextLength = config.xMonitorDefaultMinLength
        }
        merged.extractInfographics = config.xMonitorExtractInfographics
        return merged
    }

    public func mergeUsers(remoteUsers: [XMonitorUser], localKnownByHandle: [String: [String]] = [:]) -> [XMonitorUser] {
        var byHandle: [String: XMonitorUser] = [:]
        var orderedHandles: [String] = []
        for u in remoteUsers where u.enabled {
            guard let h = XMonitorFilter.normalizeHandle(u.handle) else { continue }
            var copy = u
            copy.handle = h
            if let extra = localKnownByHandle[h], !extra.isEmpty {
                copy.recentIds = Self.dedupeKeepOrder(extra + copy.recentIds, limit: 300)
                for eid in extra {
                    copy.lastTweetId = XMonitorFilter.maxTweetId(copy.lastTweetId, eid)
                }
            }
            byHandle[h] = copy
            orderedHandles.append(h)
        }
        for localH in XMonitorFilter.parseHandles(config.xMonitorLocalHandles) {
            if byHandle[localH] == nil {
                var u = XMonitorUser(handle: localH, enabled: true)
                if let extra = localKnownByHandle[localH] {
                    u.recentIds = Array(extra.prefix(300))
                    for eid in extra {
                        u.lastTweetId = XMonitorFilter.maxTweetId(u.lastTweetId, eid)
                    }
                }
                byHandle[localH] = u
                orderedHandles.append(localH)
            }
        }
        return orderedHandles.compactMap { byHandle[$0] }
    }

    public func collectIncremental(
        users: [XMonitorUser],
        monitorCfg: XMonitorRemoteConfig,
        localKnownIds: [String] = [],
        limitOverride: Int? = nil,
        handoff: Bool = true
    ) throws -> (articles: [ArticlePayload], userStates: [String: XMonitorUserStateUpdate], channel: String) {
        let hasList = !monitorCfg.listURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !users.isEmpty || hasList else {
            return ([], [:], "idle")
        }
        guard browser.isAvailable() else {
            throw NSError(
                domain: "XMonitor",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "本机未检测到 ego-browser CLI，无法执行本地 X 用户监控抓取"]
            )
        }
        let maxItems = max(1, limitOverride ?? monitorCfg.maxItemsPerUser)
        let (arts, states) = try collectViaEgo(
            users: users,
            monitorCfg: monitorCfg,
            localKnownIds: localKnownIds,
            maxItems: maxItems,
            handoff: handoff
        )
        return (arts, states, "ego")
    }

    // MARK: - ego-lite Browser & L2 Passive Raw Payloads

    private func collectViaEgo(
        users: [XMonitorUser],
        monitorCfg: XMonitorRemoteConfig,
        localKnownIds: [String],
        maxItems: Int,
        handoff: Bool
    ) throws -> ([ArticlePayload], [String: XMonitorUserStateUpdate]) {
        var knownByHandle: [String: [String]] = [:]
        for u in users {
            var ids = u.recentIds.filter { !$0.isEmpty }
            if !u.lastTweetId.isEmpty && !ids.contains(u.lastTweetId) {
                ids.insert(u.lastTweetId, at: 0)
            }
            knownByHandle[u.handle.lowercased()] = ids
        }
        if !localKnownIds.isEmpty {
            knownByHandle["__list__"] = Array(localKnownIds.suffix(500))
        }

        let res = browser.collectXMonitor(
            handles: users.map(\.handle),
            knownIdsByHandle: knownByHandle,
            listURL: monitorCfg.listURL,
            maxItemsPerUser: maxItems,
            handoff: handoff,
            keepOpen: false
        )
        if res.status == "handoff_required" || res.status == "login_required" {
            throw AuthRequiredError(platform: "x_monitor", message: res.message.nonEmpty ?? res.status)
        }
        if res.status != "ok" {
            throw NSError(domain: "XMonitor", code: 500, userInfo: [NSLocalizedDescriptionKey: res.message.nonEmpty ?? "X 监控浏览器采集失败 (\(res.status))"])
        }

        return parseRawPayloads(
            payloads: res.payloads,
            domItems: res.domItems,
            users: users,
            monitorCfg: monitorCfg,
            localKnownIds: localKnownIds,
            incremental: true,
            maxItemsPerUser: maxItems
        )
    }

    public func parseRawPayloads(
        payloads: [JSONValue],
        domItems: [[String: JSONValue]]?,
        users: [XMonitorUser],
        monitorCfg: XMonitorRemoteConfig,
        localKnownIds: [String] = [],
        incremental: Bool = true,
        maxItemsPerUser: Int = 20,
        maxVLMCalls: Int = 6,
        onlyObservedUsers: Bool = false
    ) -> (articles: [ArticlePayload], userStates: [String: XMonitorUserStateUpdate]) {
        var usersByHandle = Dictionary(uniqueKeysWithValues: users.map { ($0.handle.lowercased(), $0) })
        let autoDiscoverFromList = !monitorCfg.listURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let globalKnownSet = Set(localKnownIds.filter { !$0.isEmpty })
        let checkedISO = DateFormatting.isoTimestamp()

        var rawEntries: [(tweet: [String: JSONValue], isPinned: Bool)] = []
        var seenTids = Set<String>()
        for payload in payloads {
            for (node, pinned) in Self.iterGraphQLMonitorTweets(payload) {
                let tid = node["rest_id"]?.stringValue ?? ""
                guard !tid.isEmpty, !seenTids.contains(tid) else { continue }
                seenTids.insert(tid)
                rawEntries.append((node, pinned))
            }
        }

        if autoDiscoverFromList {
            for (node, _) in rawEntries {
                let uInfo = XGraphQLHelpers.extractUserInfo(node)
                guard let h = XMonitorFilter.normalizeHandle(uInfo.handle) else { continue }
                if usersByHandle[h] == nil {
                    var discovered = XMonitorUser(handle: h, enabled: true)
                    discovered.displayName = uInfo.name
                    discovered.avatarURL = uInfo.avatarURL
                    usersByHandle[h] = discovered
                }
            }
            if let domItems {
                for dom in domItems {
                    guard let h = XMonitorFilter.normalizeHandle(dom["handle"]?.stringValue ?? "") else { continue }
                    if usersByHandle[h] == nil {
                        usersByHandle[h] = XMonitorUser(handle: h, enabled: true)
                    }
                }
            }
        }

        var groupedNodes: [String: [(tweet: [String: JSONValue], isPinned: Bool)]] = Dictionary(uniqueKeysWithValues: usersByHandle.keys.map { ($0, []) })
        for (node, pinned) in rawEntries {
            let uInfo = XGraphQLHelpers.extractUserInfo(node)
            let h = uInfo.handle.lowercased()
            if groupedNodes[h] != nil {
                groupedNodes[h]?.append((node, pinned))
            }
        }

        // Process handles with the freshest tweets first so per-round VLM budget prioritizes newest posts
        let sortedHandles = usersByHandle.keys.sorted { lhs, rhs in
            let lMax = (groupedNodes[lhs] ?? []).map { XMonitorFilter.tweetIdUInt64($0.tweet["rest_id"]?.stringValue) }.max() ?? 0
            let rMax = (groupedNodes[rhs] ?? []).map { XMonitorFilter.tweetIdUInt64($0.tweet["rest_id"]?.stringValue) }.max() ?? 0
            if lMax != rMax { return lMax > rMax }
            return lhs < rhs
        }

        var vlmBudget = max(0, maxVLMCalls)
        var allArticles: [ArticlePayload] = []
        var userStates: [String: XMonitorUserStateUpdate] = [:]

        for handle in sortedHandles {
            guard let u = usersByHandle[handle] else { continue }
            let entries = groupedNodes[handle] ?? []
            let knownSet = Set(u.recentIds.filter { !$0.isEmpty }).union(globalKnownSet)
            let prevWm = incremental ? XMonitorFilter.tweetIdUInt64(u.lastTweetId) : 0
            var newWm = u.lastTweetId
            var seenForUser: [String] = []
            var latestPostAt = u.lastPostAt
            var displayName: String? = nil
            var avatarURL: String? = nil
            var kept: [ArticlePayload] = []

            for (tweetNode, isPinned) in entries {
                let tid = (tweetNode["rest_id"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tid.isEmpty else { continue }
                let uInfo = XGraphQLHelpers.extractUserInfo(tweetNode)
                if !uInfo.name.isEmpty { displayName = uInfo.name }
                if !uInfo.avatarURL.isEmpty { avatarURL = uInfo.avatarURL }

                if !isPinned {
                    newWm = XMonitorFilter.maxTweetId(newWm, tid)
                }
                seenForUser.append(tid)

                if incremental {
                    if knownSet.contains(tid) || knownSet.contains("xm_\(tid)") {
                        if isPinned { continue }
                        break
                    }
                    if prevWm > 0 && XMonitorFilter.tweetIdUInt64(tid) <= prevWm {
                        if isPinned { continue }
                        break
                    }
                }

                if let art = graphQLTweetToArticle(tweetObj: tweetNode, user: u, monitorCfg: monitorCfg, vlmBudget: &vlmBudget) {
                    kept.append(art)
                    if let pub = art.publishedDate, latestPostAt == nil || pub > (latestPostAt ?? "") {
                        latestPostAt = pub
                    }
                    if kept.count >= maxItemsPerUser { break }
                }
            }

            if entries.isEmpty, let domItems {
                for dom in domItems {
                    let domHandle = (dom["handle"]?.stringValue ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " @")).lowercased()
                    guard domHandle == handle else { continue }
                    let tid = (dom["id"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !tid.isEmpty, !seenTids.contains(tid) else { continue }
                    seenTids.insert(tid)
                    let isPinned = dom["isPinned"]?.boolValue ?? false
                    if !isPinned {
                        newWm = XMonitorFilter.maxTweetId(newWm, tid)
                    }
                    seenForUser.append(tid)
                    if incremental && (knownSet.contains(tid) || (prevWm > 0 && XMonitorFilter.tweetIdUInt64(tid) <= prevWm)) {
                        if isPinned { continue }
                        break
                    }
                    if let art = domItemToArticle(dom: dom, user: u, monitorCfg: monitorCfg) {
                        kept.append(art)
                        if kept.count >= maxItemsPerUser { break }
                    }
                }
            }

            let mergedRecent = Self.dedupeKeepOrder(seenForUser + u.recentIds, limit: 300)
            if !entries.isEmpty || !seenForUser.isEmpty || !onlyObservedUsers {
                userStates[handle] = XMonitorUserStateUpdate(
                    lastTweetId: newWm,
                    recentIds: mergedRecent,
                    lastCheckedAt: checkedISO,
                    lastPostAt: latestPostAt,
                    capturedDelta: kept.count,
                    lastError: "",
                    displayName: displayName,
                    avatarURL: avatarURL
                )
            }
            allArticles.append(contentsOf: kept)
        }

        allArticles.sort { XMonitorFilter.tweetIdUInt64($0.metadata["tweet_id"]?.stringValue) < XMonitorFilter.tweetIdUInt64($1.metadata["tweet_id"]?.stringValue) }
        return (allArticles, userStates)
    }

    private static func iterGraphQLMonitorTweets(_ payload: JSONValue) -> [(tweet: [String: JSONValue], isPinned: Bool)] {
        var results: [([String: JSONValue], Bool)] = []

        func extractItem(_ itemContent: JSONValue?, isPinned: Bool) {
            guard let ic = itemContent?.objectValue else { return }
            if ic["promotedMetadata"] != nil && ic["promotedMetadata"] != .null { return }
            if let unwrapped = XGraphQLHelpers.unwrapTweetResult(ic["tweet_results"]?["result"]) {
                results.append((unwrapped, isPinned))
            }
        }

        func walk(_ node: JSONValue) {
            switch node {
            case .object(let obj):
                let instType = obj["type"]?.stringValue ?? ""
                if instType == "TimelinePinEntry", let entry = obj["entry"]?.objectValue {
                    extractItem(entry["content"]?["itemContent"], isPinned: true)
                    return
                }
                if instType == "TimelineAddEntries", let entries = obj["entries"]?.arrayValue {
                    for entryVal in entries {
                        guard let entry = entryVal.objectValue else { continue }
                        let entryId = entry["entryId"]?.stringValue ?? ""
                        if entryId.hasPrefix("promoted-") || entryId.hasPrefix("who-to-follow-") || entryId.hasPrefix("cursor-") {
                            continue
                        }
                        let content = entry["content"]?.objectValue ?? [:]
                        if entryId.hasPrefix("tweet-") {
                            extractItem(content["itemContent"], isPinned: false)
                        } else if let items = content["items"]?.arrayValue {
                            for subVal in items {
                                guard let sub = subVal.objectValue else { continue }
                                let subId = sub["entryId"]?.stringValue ?? ""
                                if subId.contains("promoted") { continue }
                                extractItem(sub["item"]?["itemContent"], isPinned: false)
                            }
                        }
                    }
                    return
                }
                for v in obj.values { walk(v) }
            case .array(let arr):
                for v in arr { walk(v) }
            default:
                break
            }
        }
        walk(payload)
        return results
    }

    private func graphQLTweetToArticle(
        tweetObj: [String: JSONValue],
        user: XMonitorUser,
        monitorCfg: XMonitorRemoteConfig,
        vlmBudget: inout Int
    ) -> ArticlePayload? {
        let tid = (tweetObj["rest_id"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tid.isEmpty else { return nil }

        let legacy = tweetObj["legacy"]?.objectValue ?? [:]
        let uInfo = XGraphQLHelpers.extractUserInfo(tweetObj)
        let handle = (uInfo.handle.nonEmpty ?? user.handle).lowercased()
        let authorName = uInfo.name.nonEmpty ?? user.displayName.nonEmpty ?? handle
        let avatarURL = uInfo.avatarURL.nonEmpty ?? user.avatarURL

        let rtTweet = XGraphQLHelpers.unwrapTweetResult(legacy["retweeted_status_result"]?["result"])
        var mainText = XGraphQLHelpers.extractTweetText(tweetObj)
        let isRetweet = rtTweet != nil || mainText.hasPrefix("RT @")

        let inReplyUid = (legacy["in_reply_to_user_id_str"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        let inReplyUname = (legacy["in_reply_to_screen_name"]?.stringValue ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " @")).lowercased()
        let inReplyTid = (legacy["in_reply_to_status_id_str"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        let isReply = !inReplyTid.isEmpty || !inReplyUid.isEmpty || !inReplyUname.isEmpty
        let isSelfReply = isReply && (
            (!inReplyUid.isEmpty && !uInfo.id.isEmpty && inReplyUid == uInfo.id) ||
            (!inReplyUname.isEmpty && inReplyUname == handle)
        )

        let xArticle = XGraphQLHelpers.extractXArticle(tweetObj)
        let urlEntities = legacy["entities"]?["urls"]?.arrayValue ?? []
        let hasExternalURL = urlEntities.contains { XMonitorFilter.isExternalExpandedURL($0["expanded_url"]?.stringValue) }

        let mediaList = legacy["extended_entities"]?["media"]?.arrayValue ?? legacy["entities"]?["media"]?.arrayValue ?? []
        var photoURLs: [String] = []
        var hasVideo = false
        for m in mediaList {
            let mType = m["type"]?.stringValue ?? ""
            if mType == "photo", let u = m["media_url_https"]?.stringValue?.nonEmpty {
                photoURLs.append(u)
            } else if mType == "video" || mType == "animated_gif" {
                hasVideo = true
            }
        }

        let quotedTweet = XGraphQLHelpers.unwrapTweetResult(tweetObj["quoted_status_result"]?["result"])
        let minLen = user.minTextLength ?? monitorCfg.defaultMinTextLength
        let (keep, _) = XMonitorFilter.shouldKeepTweet(
            text: mainText,
            isPromoted: false,
            isRetweet: isRetweet,
            isReply: isReply,
            isSelfReply: isSelfReply,
            hasMedia: !photoURLs.isEmpty || hasVideo,
            hasExternalURL: hasExternalURL,
            hasQuote: quotedTweet != nil,
            isXArticle: xArticle != nil,
            includeRetweets: user.includeRetweets,
            includeReplies: user.includeReplies,
            minTextLength: minLen
        )
        guard keep else { return nil }

        if isRetweet, let rtTweet {
            let rtU = XGraphQLHelpers.extractUserInfo(rtTweet)
            let rtText = XGraphQLHelpers.extractTweetText(rtTweet)
            if !rtText.isEmpty {
                mainText = rtU.handle.isEmpty ? "RT: \(rtText)" : "RT @\(rtU.handle): \(rtText)"
            }
        }

        var quotedMeta: JSONValue = .null
        var quotedMD = ""
        if let quotedTweet {
            let qU = XGraphQLHelpers.extractUserInfo(quotedTweet)
            let qText = XGraphQLHelpers.extractTweetText(quotedTweet)
            let qTid = quotedTweet["rest_id"]?.stringValue ?? ""
            if !qText.isEmpty {
                let qAuthor = qU.handle.isEmpty ? (qU.name.nonEmpty ?? "引用推文") : "@\(qU.handle)"
                let qLines = qText.components(separatedBy: .newlines).map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n")
                quotedMD = "> **引用 \(qAuthor)**：\n\(qLines)"
                quotedMeta = .object([
                    "id": .string(qTid),
                    "author_handle": .string(qU.handle),
                    "author_name": .string(qU.name),
                    "text": .string(qText),
                    "url": .string(qTid.isEmpty ? "" : "https://x.com/\(qU.handle.isEmpty ? "i" : qU.handle)/status/\(qTid)"),
                ])
            }
        }

        let hasSelfThread = legacy["self_thread"] != nil && legacy["self_thread"] != .null
        let likelyThread = isSelfReply || hasSelfThread || XGraphQLHelpers.hasThreadMarker(mainText)
        let isIncompleteArticle = xArticle != nil && !(xArticle?.hasFullBlocks ?? true)
        let authorDisplay = (!authorName.isEmpty && authorName != handle) ? "\(authorName) (@\(handle))" : "@\(handle)"
        let url = "https://x.com/\(handle)/status/\(tid)"

        var sections: [String] = []
        if let art = xArticle, !art.title.isEmpty { sections.append("# \(art.title)") }
        if let art = xArticle, !art.body.isEmpty { sections.append(art.body) }
        if !mainText.isEmpty && (xArticle == nil || !(xArticle?.body.contains(mainText) ?? false)) {
            sections.append(mainText)
        }
        if !quotedMD.isEmpty { sections.append(quotedMD) }

        var vlmExtracted: String? = nil
        if vlmBudget > 0 && XGraphQLHelpers.shouldRunInfographicVLM(
            text: mainText,
            photoURLs: photoURLs,
            config: config,
            featureEnabled: monitorCfg.extractInfographics
        ) {
            vlmBudget -= 1
            vlmExtracted = XGraphQLHelpers.extractPhotosVLM(
                tweetId: tid,
                photoURLs: photoURLs,
                tweetText: mainText,
                author: authorDisplay,
                config: config,
                http: http
            )
            if let v = vlmExtracted {
                sections.append("## 配图结构化内容\n\n\(v)")
            }
        }
        if !photoURLs.isEmpty {
            sections.append(photoURLs.enumerated().map { "![配图 \($0.offset + 1)](\($0.element))" }.joined(separator: "\n"))
        }

        let content = sections.filter { !$0.isEmpty }.joined(separator: "\n\n").nonEmpty ?? "[X 监控推文](\(url))"
        let title = XGraphQLHelpers.buildTweetTitle(authorLabel: authorName, articleTitle: xArticle?.title.nonEmpty, text: mainText, tid: tid)
        let hashtags: [String] = (legacy["entities"]?["hashtags"]?.arrayValue ?? []).compactMap { h in
            h["text"]?.stringValue?.nonEmpty.map { "#\($0)" }
        }
        let mergedTags = Self.dedupeKeepOrder(user.tags + hashtags, limit: 50)

        let likeCnt = legacy["favorite_count"]?.intValue ?? 0
        let bmCnt = legacy["bookmark_count"]?.intValue ?? 0
        let metrics: [String: JSONValue] = [
            "like_count": .int(likeCnt),
            "retweet_count": .int(legacy["retweet_count"]?.intValue ?? 0),
            "reply_count": .int(legacy["reply_count"]?.intValue ?? 0),
            "quote_count": .int(legacy["quote_count"]?.intValue ?? 0),
            "bookmark_count": .int(bmCnt),
            "view_count": .int(tweetObj["views"]?["count"]?.intValue ?? 0),
        ]

        let metadata: [String: JSONValue] = [
            "tweet_id": .string(tid),
            "author_handle": .string(handle),
            "author_name": .string(authorName),
            "author_avatar": .string(avatarURL),
            "monitor_tags": .array(user.tags.map(JSONValue.string)),
            "tags": .array(mergedTags.map(JSONValue.string)),
            "raw_tweet_text": .string(mainText),
            "photo_urls": .array(photoURLs.map(JSONValue.string)),
            "has_video": .bool(hasVideo),
            "quoted_tweet": quotedMeta,
            "is_retweet": .bool(isRetweet),
            "is_self_reply": .bool(isSelfReply),
            "likely_thread": .bool(likelyThread),
            "is_x_article": .bool(xArticle != nil),
            "needs_thread_expansion": .bool(likelyThread || isIncompleteArticle),
            "vlm_extracted": .bool(vlmExtracted != nil),
            "has_full_content": .bool(!(likelyThread || isIncompleteArticle)),
            "favorite_count": .int(likeCnt),
            "bookmark_count": .int(bmCnt),
            "metrics": .object(metrics),
        ]

        return ArticlePayload(
            id: "xm_\(tid)",
            title: title,
            content: content,
            url: url,
            source: ArticleSourceInfo(type: "x_monitor", name: "@\(handle)", identifier: "https://x.com/\(handle)"),
            author: authorDisplay,
            publishedDate: XGraphQLHelpers.parseTwitterDate(legacy["created_at"]?.stringValue),
            metadata: metadata
        )
    }

    private func domItemToArticle(
        dom: [String: JSONValue],
        user: XMonitorUser,
        monitorCfg: XMonitorRemoteConfig
    ) -> ArticlePayload? {
        let tid = (dom["id"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tid.isEmpty else { return nil }
        let handle = user.handle.lowercased()
        let text = (dom["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let imgs = (dom["images"]?.arrayValue ?? []).compactMap(\.stringValue).filter { !$0.isEmpty }
        let isRetweet = (dom["isRetweet"]?.boolValue ?? false) || text.hasPrefix("RT @")
        let minLen = user.minTextLength ?? monitorCfg.defaultMinTextLength

        let (keep, _) = XMonitorFilter.shouldKeepTweet(
            text: text,
            isRetweet: isRetweet,
            hasMedia: !imgs.isEmpty,
            includeRetweets: user.includeRetweets,
            includeReplies: user.includeReplies,
            minTextLength: minLen
        )
        guard keep else { return nil }

        let url = dom["url"]?.stringValue?.nonEmpty ?? "https://x.com/\(handle)/status/\(tid)"
        var parts: [String] = []
        if !text.isEmpty { parts.append(text) }
        if !imgs.isEmpty {
            parts.append(imgs.enumerated().map { "![配图 \($0.offset + 1)](\($0.element))" }.joined(separator: "\n"))
        }
        let content = parts.joined(separator: "\n\n").nonEmpty ?? "[X 监控推文](\(url))"
        let authorName = user.displayName.nonEmpty ?? handle
        let title = XGraphQLHelpers.buildTweetTitle(authorLabel: authorName, articleTitle: nil, text: text, tid: tid)

        return ArticlePayload(
            id: "xm_\(tid)",
            title: title,
            content: content,
            url: url,
            source: ArticleSourceInfo(type: "x_monitor", name: "@\(handle)", identifier: "https://x.com/\(handle)"),
            author: authorName != handle ? "\(authorName) (@\(handle))" : "@\(handle)",
            publishedDate: XGraphQLHelpers.parseTwitterDate(dom["publishedAt"]?.stringValue),
            metadata: [
                "tweet_id": .string(tid),
                "author_handle": .string(handle),
                "author_name": .string(authorName),
                "author_avatar": .string(user.avatarURL),
                "monitor_tags": .array(user.tags.map(JSONValue.string)),
                "tags": .array(user.tags.map(JSONValue.string)),
                "raw_tweet_text": .string(text),
                "photo_urls": .array(imgs.map(JSONValue.string)),
                "dom_fallback": .bool(true),
                "has_full_content": .bool(true),
            ]
        )
    }

    private static func dedupeKeepOrder(_ items: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for it in items where !it.isEmpty && !seen.contains(it) {
            seen.insert(it)
            out.append(it)
            if out.count >= limit { break }
        }
        return out
    }
}
