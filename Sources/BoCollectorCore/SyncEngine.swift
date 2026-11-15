import CryptoKit
import Darwin
import Foundation

public struct RemoteStatePayload: Sendable {
    public var recentIds: [String]
    public var pendingAsrArticles: [ArticlePayload]
    public var pendingRefetchArticles: [ArticlePayload]
    public var monitoredUsers: [XMonitorUser]
    public var xMonitorConfig: XMonitorRemoteConfig?
    public var totalArticles: Int
    public var lastSync: String?

    public init(
        recentIds: [String] = [],
        pendingAsrArticles: [ArticlePayload] = [],
        pendingRefetchArticles: [ArticlePayload] = [],
        monitoredUsers: [XMonitorUser] = [],
        xMonitorConfig: XMonitorRemoteConfig? = nil,
        totalArticles: Int = 0,
        lastSync: String? = nil
    ) {
        self.recentIds = recentIds
        self.pendingAsrArticles = pendingAsrArticles
        self.pendingRefetchArticles = pendingRefetchArticles
        self.monitoredUsers = monitoredUsers
        self.xMonitorConfig = xMonitorConfig
        self.totalArticles = totalArticles
        self.lastSync = lastSync
    }
}

public final class SyncEngine: @unchecked Sendable {
    public let config: CollectorConfig
    public let stateDir: URL
    public let statePath: URL
    public let logger: SafeLogger
    public let browser: BrowserCollecting
    public let asr: KoofrAsrClient
    public let healer: IncidentHealer
    public let http: HTTPTransport
    private let ownsHTTP: Bool

    public var stopping: Bool = false
    public var state: CollectorState

    public init(
        config: CollectorConfig,
        logger: SafeLogger? = nil,
        browser: BrowserCollecting? = nil,
        asrClient: KoofrAsrClient? = nil,
        healer: IncidentHealer? = nil,
        http: HTTPTransport? = nil,
        runner: CommandRunner = DefaultCommandRunner()
    ) {
        self.config = config
        self.stateDir = config.stateDir.standardizedFileURL
        try? SecureFileStore.ensureSecureDirectory(self.stateDir)
        self.statePath = self.stateDir.appendingPathComponent("state.json")

        let resolvedLogger = logger ?? SafeLogger(logPath: self.stateDir.appendingPathComponent("logs/collector.log"))
        self.logger = resolvedLogger

        if let providedHTTP = http {
            self.http = providedHTTP
            self.ownsHTTP = false
        } else {
            self.http = URLSessionHTTPTransport(config: config)
            self.ownsHTTP = true
        }

        self.browser = browser ?? EgoBrowserClient(
            cacheDir: config.cacheDir,
            spaceName: config.egoSpaceName,
            preferredBin: config.egoBin,
            runner: runner
        )
        self.asr = asrClient ?? KoofrAsrClient(config: config, logger: resolvedLogger, http: self.http, runner: runner)
        self.healer = healer ?? IncidentHealer(config: config, logger: resolvedLogger, runner: runner)
        self.state = Self.loadState(from: self.statePath)
    }

    public func close() {
        asr.close()
        if ownsHTTP {
            http.close()
        }
    }

    public static func loadState(from path: URL) -> CollectorState {
        if FileManager.default.fileExists(atPath: path.path),
           let data = try? Data(contentsOf: path),
           let decoded = try? JSONDecoder().decode(CollectorState.self, from: data) {
            return decoded
        }
        return CollectorState()
    }

    public func saveState() throws {
        if !config.remotePushURL.isEmpty {
            let targetHash = Self.sha256Hex(config.remotePushURL)
            if let prev = state.target, !prev.isEmpty, prev != targetHash {
                throw NSError(
                    domain: "BoCollector",
                    code: 409,
                    userInfo: [NSLocalizedDescriptionKey: "REMOTE_PUSH_URL changed; refusing to mix state across different cloud targets"]
                )
            }
            state.target = targetHash
        }
        state.updatedAt = DateFormatting.localTimestamp()
        try SecureFileStore.atomicWriteCodable(state, to: statePath)
    }

    private func cloudHeaders(jsonBody: Bool = false) -> [String: String] {
        var headers: [String: String] = [:]
        if jsonBody { headers["Content-Type"] = "application/json" }
        if !config.remoteIngestToken.isEmpty {
            headers["Authorization"] = "Bearer \(config.remoteIngestToken)"
        }
        return headers
    }

    public func fetchRemoteState(platform: String, sourceName: String? = nil) throws -> RemoteStatePayload {
        guard !config.remotePushURL.isEmpty, !config.remoteIngestToken.isEmpty else {
            throw NSError(domain: "BoCollector", code: 401, userInfo: [NSLocalizedDescriptionKey: "请先在配置面板填写云端接收地址与 Ingest Token"])
        }
        let name = platform == "rss" ? (sourceName ?? "") : (sourceName?.nonEmpty ?? SourceNames.displayName(for: platform))
        let url = try URLSessionHTTPTransport.makeURL(
            "\(config.remotePushURL)/api/ingest/state",
            query: ["source_type": platform, "source_name": name]
        )
        let resp = try http.send(HTTPRequestSpec(method: "GET", url: url, headers: cloudHeaders(), timeout: 30.0))
        if resp.statusCode >= 400 {
            throw CloudHTTPError(statusCode: resp.statusCode, message: "Cloud state request failed HTTP \(resp.statusCode)")
        }
        let body = try resp.json()
        guard body["status"]?.stringValue == "ok",
              let recentArr = body["recent_ids"]?.arrayValue else {
            throw NSError(domain: "BoCollector", code: 422, userInfo: [NSLocalizedDescriptionKey: "Invalid cloud /api/ingest/state payload"])
        }

        let recentIds = recentArr.compactMap(\.stringValue).filter { !$0.isEmpty }
        var pendingAsr: [ArticlePayload] = []
        if let rawPending = body["pending_asr_articles"]?.arrayValue {
            for item in rawPending {
                if let data = try? item.toData(),
                   let art = try? JSONDecoder().decode(ArticlePayload.self, from: data) {
                    pendingAsr.append(art)
                }
            }
        }

        var pendingRefetch: [ArticlePayload] = []
        if let rawRefetch = body["pending_refetch_articles"]?.arrayValue {
            for item in rawRefetch {
                if let data = try? item.toData(),
                   let art = try? JSONDecoder().decode(ArticlePayload.self, from: data) {
                    pendingRefetch.append(art)
                }
            }
        }

        var monUsers: [XMonitorUser] = []
        if let rawUsers = body["monitored_users"]?.arrayValue {
            for item in rawUsers {
                if let data = try? item.toData(),
                   let u = try? JSONDecoder().decode(XMonitorUser.self, from: data) {
                    monUsers.append(u)
                }
            }
        }

        var monCfg: XMonitorRemoteConfig? = nil
        if let rawCfg = body["x_monitor_config"], rawCfg != .null,
           let data = try? rawCfg.toData(),
           let decoded = try? JSONDecoder().decode(XMonitorRemoteConfig.self, from: data) {
            monCfg = decoded
        }

        return RemoteStatePayload(
            recentIds: recentIds,
            pendingAsrArticles: pendingAsr,
            pendingRefetchArticles: pendingRefetch,
            monitoredUsers: monUsers,
            xMonitorConfig: monCfg,
            totalArticles: body["total_articles"]?.intValue ?? 0,
            lastSync: body["last_sync"]?.stringValue
        )
    }

    public func pushArticlesBatch(
        platform: String,
        articles: [ArticlePayload],
        recentIds: [String],
        sourceName: String? = nil,
        clean: Bool = true,
        forceClean: Bool = false,
        xMonitorUserStates: [String: XMonitorUserStateUpdate]? = nil
    ) throws -> [String: JSONValue] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let articlesJSON = try JSONValue.parse(data: encoder.encode(articles))

        var payloadObj: [String: JSONValue] = [
            "source_type": .string(platform),
            "source_name": .string(sourceName?.nonEmpty ?? SourceNames.displayName(for: platform)),
            "clean": .bool(clean),
            "force_clean": .bool(forceClean),
            "articles": articlesJSON,
            "recent_ids": .array(recentIds.map(JSONValue.string)),
        ]
        if let userStates = xMonitorUserStates, !userStates.isEmpty {
            payloadObj["x_monitor_user_states"] = try JSONValue.parse(data: encoder.encode(userStates))
        }

        guard let url = URL(string: "\(config.remotePushURL)/api/ingest/articles") else {
            throw HTTPTransportError(message: "Invalid cloud ingest URL")
        }
        let bodyData = try JSONValue.object(payloadObj).toData()
        let resp = try http.send(
            HTTPRequestSpec(method: "POST", url: url, headers: cloudHeaders(jsonBody: true), body: bodyData, timeout: 180.0)
        )
        if resp.statusCode >= 400 {
            if resp.statusCode == 422,
               let json = try? resp.json(),
               json["detail"]?.stringValue == "已有内容处理任务运行中，请稍后重试" {
                throw RemotePipelineBusyError("HTTP 422 pipeline busy")
            }
            throw CloudHTTPError(statusCode: resp.statusCode, message: "Cloud ingest failed HTTP \(resp.statusCode)")
        }
        return (try resp.json()).objectValue ?? [:]
    }

    public func pushSingleArticle(
        platform: String,
        article: ArticlePayload,
        recentIds: [String]? = nil,
        clean: Bool = true,
        forceClean: Bool = false
    ) throws -> [String: JSONValue] {
        let rIds = recentIds ?? [stripPrefixID(article.id)]
        return try pushArticlesBatch(
            platform: platform,
            articles: [article],
            recentIds: rIds,
            sourceName: platform == "rss" ? article.source.name : nil,
            clean: clean,
            forceClean: forceClean
        )
    }

    public func flushOutbox(platform: String, remoteIds: Set<String>? = nil) throws -> Int {
        guard var srcState = state.sources[platform], let outbox = srcState.outbox, !outbox.isEmpty else {
            return 0
        }

        let effectiveRemoteIds: Set<String>
        if let remoteIds {
            effectiveRemoteIds = remoteIds
        } else {
            let remoteBody = try fetchRemoteState(platform: platform)
            effectiveRemoteIds = Set(remoteBody.recentIds.map(stripPrefixID).filter { !$0.isEmpty })
        }

        var pushed = 0
        for item in outbox {
            let aid = stripPrefixID(item.id)
            if effectiveRemoteIds.contains(aid) {
                try acknowledge(platform: platform, articleId: item.id)
                continue
            }
            let shouldClean = item.metadata["asr_status"]?.stringValue != "pending"
            let res = try pushSingleArticle(platform: platform, article: item, recentIds: [aid], clean: shouldClean)
            let saveFailed = res["save_failed"]?.intValue ?? 0
            let saved = res["saved"]?.intValue ?? 0
            let dup = res["duplicates"]?.intValue ?? 0
            if saveFailed > 0 || (saved + dup) < 1 {
                throw NSError(domain: "BoCollector", code: 502, userInfo: [NSLocalizedDescriptionKey: "Cloud ingest did not confirm save"])
            }
            try acknowledge(platform: platform, articleId: item.id)
            pushed += 1
        }

        srcState = state.sources[platform] ?? srcState
        if srcState.outbox?.isEmpty ?? true {
            srcState.outbox = nil
            state.sources[platform] = srcState
            try saveState()
        }
        return pushed
    }

    private func acknowledge(platform: String, articleId: String) throws {
        var src = state.sources[platform] ?? SourceState(name: SourceNames.displayName(for: platform))
        let raw = stripPrefixID(articleId)
        var knownSet = Set(src.known)
        if !raw.isEmpty { knownSet.insert(raw) }
        src.known = knownSet.sorted()
        src.saved += 1
        src.sinceRest = (src.sinceRest ?? 0) + 1
        let remaining = (src.outbox ?? []).filter { $0.id != articleId }
        src.outbox = remaining.isEmpty ? nil : remaining
        state.sources[platform] = src
        try saveState()
    }

    public func harvestAsr() throws -> AsrStateSummary {
        guard config.hasKoofrWebdav else {
            return AsrStateSummary()
        }
        let remoteBody = try fetchRemoteState(platform: "douyin")
        let pendingArticles = remoteBody.pendingAsrArticles
        if pendingArticles.isEmpty {
            let empty = AsrStateSummary(checked: 0, completed: 0, stillPending: 0)
            state.asr = empty
            try saveState()
            return empty
        }

        let readyMap = try asr.fetchReadyTranscripts(pendingArticles: pendingArticles)
        let byId = Dictionary(uniqueKeysWithValues: pendingArticles.map { ($0.id, $0) })
        var completed = 0

        for (artId, (transcript, inboxRel)) in readyMap {
            guard let orig = byId[artId] else { continue }
            let upgraded = ASRTranscriptFormatter.applyTranscript(to: orig, transcript: transcript)
            let res = try pushSingleArticle(
                platform: "douyin",
                article: upgraded,
                recentIds: [stripPrefixID(artId)],
                clean: true,
                forceClean: true
            )
            let saveFailed = res["save_failed"]?.intValue ?? 0
            let saved = res["saved"]?.intValue ?? 0
            let dup = res["duplicates"]?.intValue ?? 0
            if saveFailed == 0 && (saved + dup) >= 1 {
                if !inboxRel.isEmpty {
                    asr.deleteInboxMedia(inboxRel)
                }
                completed += 1
            }
        }

        let stillPending = max(0, pendingArticles.count - completed)
        if stillPending > 0 {
            let now = Date().timeIntervalSince1970
            let lastRetrigger = state.lastAsrRetriggerAt ?? 0
            if now - lastRetrigger >= 900 {
                if asr.triggerInstaboxWorker() {
                    state.lastAsrRetriggerAt = now
                }
            }
        }

        let summary = AsrStateSummary(checked: pendingArticles.count, completed: completed, stillPending: stillPending)
        state.asr = summary
        try saveState()
        if completed > 0 {
            logger.info("已从 Koofr 回收补齐 \(completed) 篇抖音语音稿（仍待转写 \(stillPending) 篇）")
        }
        return summary
    }

    public func triggerCloudHarvestAsr() throws -> JSONValue {
        guard let url = URL(string: "\(config.remotePushURL)/api/ingest/harvest-asr") else {
            throw HTTPTransportError(message: "Invalid cloud harvest-asr URL")
        }
        let bodyData = try JSONValue.object(["clean": .bool(true)]).toData()
        let resp = try http.send(HTTPRequestSpec(method: "POST", url: url, headers: cloudHeaders(jsonBody: true), body: bodyData, timeout: 180.0))
        if resp.statusCode >= 400 {
            throw CloudHTTPError(statusCode: resp.statusCode, message: "Cloud harvest-asr HTTP \(resp.statusCode)")
        }
        return try resp.json()
    }

    public func harvestPendingRefetches(limitOverride: Int? = nil) throws -> RssRefetchSummary {
        guard config.rssRefetchEnabled,
              !config.remotePushURL.isEmpty,
              !config.remoteIngestToken.isEmpty else {
            return RssRefetchSummary()
        }
        let remoteBody = try fetchRemoteState(platform: "rss", sourceName: "")
        let pendingArticles = remoteBody.pendingRefetchArticles
        if pendingArticles.isEmpty {
            let empty = RssRefetchSummary()
            state.rssRefetch = empty
            try saveState()
            return empty
        }

        let refetchEngine = ArticleRefetchEngine(config: config, http: http, browser: browser, logger: logger)
        let summary = try refetchEngine.refetchPending(articles: pendingArticles, limitOverride: limitOverride) { [weak self] upgradedArt, shouldClean in
            guard let self else { return [:] }
            return try self.pushSingleArticle(
                platform: "rss",
                article: upgradedArt,
                recentIds: [upgradedArt.id],
                clean: shouldClean,
                forceClean: shouldClean
            )
        }

        state.rssRefetch = summary
        try saveState()
        if summary.totalSucceeded > 0 || summary.exhausted > 0 {
            logger.info(
                "[RSS 边缘补抓] 检查 \(summary.checked) 篇 -> HTTP 补齐 \(summary.succeededHTTP) 篇 / ego-lite 补齐 \(summary.succeededBrowser) 篇"
                + (summary.stillPending > 0 ? " / 仍待补抓 \(summary.stillPending) 篇" : "")
                + (summary.exhausted > 0 ? " / 达上限放弃 \(summary.exhausted) 篇" : "")
            )
        }
        return summary
    }

    private static func rssSummaryJSON(_ summary: RssRefetchSummary) -> JSONValue {
        .object([
            "checked": .int(summary.checked),
            "succeeded_http": .int(summary.succeededHTTP),
            "succeeded_browser": .int(summary.succeededBrowser),
            "still_pending": .int(summary.stillPending),
            "exhausted": .int(summary.exhausted),
        ])
    }

    // MARK: - Incremental Sync

    public func syncOnce(
        platforms: [String]? = nil,
        limitOverride: Int? = nil,
        ignoreAuthPause: Bool = false
    ) -> [String: JSONValue] {
        let targets = platforms ?? config.enabledDefaultPlatforms
        if state.healer?.authPaused == true && !ignoreAuthPause && targets != ["rss"] {
            let pausedPlat = state.healer?.authPlatform ?? "unknown"
            logger.warn("当前处于人工验证暂停态 (\(pausedPlat))，请验证后执行恢复采集")
            return ["status": .string("auth_paused"), "platform": .string(pausedPlat)]
        }

        return withRunLock { locked in
            guard locked else {
                logger.info("已有采集任务正在运行，本次跳过")
                return ["status": .string("already_running")]
            }

            if ignoreAuthPause {
                var hm = state.healer ?? HealerState()
                hm.authPaused = false
                state.healer = hm
                try? saveState()
            }

            var stage = "init"
            do {
                stage = "harvest_asr"
                let asrRes = try harvestAsr()

                var results: [String: JSONValue] = [:]
                var firstTransientError: String? = nil
                var rssRes = state.rssRefetch ?? RssRefetchSummary()

                if platforms == nil && config.rssRefetchEnabled {
                    stage = "harvest_rss_refetch"
                    do {
                        rssRes = try harvestPendingRefetches(limitOverride: limitOverride)
                    } catch {
                        let (label, transient) = ErrorSanitizer.summarize(error)
                        if transient {
                            logger.warn("[RSS 边缘补抓] 瞬时网络/队列波动 (\(label))，已延后重试")
                            if firstTransientError == nil { firstTransientError = label }
                        } else {
                            throw error
                        }
                    }
                }

                for plat in targets {
                    stage = "sync:\(plat)"
                    do {
                        if plat == "x_monitor" {
                            results[plat] = try syncXMonitorIncremental(limitOverride: limitOverride)
                        } else if plat == "rss" {
                            rssRes = try harvestPendingRefetches(limitOverride: limitOverride)
                            results[plat] = Self.rssSummaryJSON(rssRes)
                        } else {
                            results[plat] = try syncFeedIncremental(platform: plat, limitOverride: limitOverride)
                        }
                    } catch let authErr as AuthRequiredError {
                        throw authErr
                    } catch {
                        let (label, transient) = ErrorSanitizer.summarize(error)
                        if transient {
                            logger.warn("[\(SourceNames.displayName(for: plat))] 瞬时网络/队列波动 (\(label))，已跳过该源并继续其余任务")
                            results[plat] = .object(["status": .string("retry_wait"), "error": .string(label)])
                            if firstTransientError == nil { firstTransientError = label }
                        } else {
                            throw error
                        }
                    }
                }

                if let transientLabel = firstTransientError {
                    state.status = "retry_wait"
                    state.lastTransientError = transientLabel
                    try? saveState()
                    return [
                        "status": .string("retry_wait"),
                        "error": .string(transientLabel),
                        "asr": .object([
                            "checked": .int(asrRes.checked),
                            "completed": .int(asrRes.completed),
                            "still_pending": .int(asrRes.stillPending),
                        ]),
                        "rss_refetch": Self.rssSummaryJSON(rssRes),
                        "sources": .object(results),
                    ]
                }

                healer.recordSuccess(state: &state)
                state.status = "idle"
                try saveState()
                return [
                    "status": .string("ok"),
                    "asr": .object([
                        "checked": .int(asrRes.checked),
                        "completed": .int(asrRes.completed),
                        "still_pending": .int(asrRes.stillPending),
                    ]),
                    "rss_refetch": Self.rssSummaryJSON(rssRes),
                    "sources": .object(results),
                ]
            } catch let authErr as AuthRequiredError {
                healer.handleAuthPause(state: &state, platform: authErr.platform, reason: authErr.message)
                state.status = "auth_paused"
                try? saveState()
                return [
                    "status": .string("auth_paused"),
                    "platform": .string(authErr.platform),
                    "reason": .string(authErr.message),
                ]
            } catch {
                let (label, transient) = ErrorSanitizer.summarize(error)
                if transient {
                    logger.warn("瞬时网络/队列忙 (\(label))，保留 outbox 下轮自动对账续传")
                    state.status = "retry_wait"
                    state.lastTransientError = label
                    try? saveState()
                    return ["status": .string("retry_wait"), "error": .string(label)]
                }

                let (_, ibState) = asr.getInstaboxState()
                let healRes = healer.handleUnexpectedFailure(
                    state: &state,
                    errorLabel: label,
                    stage: stage,
                    instaboxState: ibState
                )
                state.status = "error"
                try? saveState()
                return [
                    "status": .string("error"),
                    "error": .string(label),
                    "healer": .object(healRes),
                ]
            }
        }
    }

    private func syncFeedIncremental(platform: String, limitOverride: Int?) throws -> JSONValue {
        let remoteBody = try fetchRemoteState(platform: platform)
        let remoteIds = Set(remoteBody.recentIds.map(stripPrefixID).filter { !$0.isEmpty })

        var srcState = state.sources[platform] ?? SourceState(name: SourceNames.displayName(for: platform))
        srcState.known = Set(srcState.known).union(remoteIds).sorted()
        state.sources[platform] = srcState
        try saveState()

        let replayed = try flushOutbox(platform: platform, remoteIds: remoteIds)
        srcState = state.sources[platform] ?? srcState

        let maxItems = max(1, limitOverride ?? (platform == "x_bookmarks" ? config.syncMaxItemsX : config.syncMaxItemsDouyin))
        let keepOpen = (platform == "douyin")
        let orderedKnown = srcState.known.filter { !remoteIds.contains($0) } + remoteIds.sorted()

        let res = browser.collectFeed(
            platform: platform,
            knownIds: orderedKnown,
            maxItems: maxItems,
            handoff: true,
            keepOpen: keepOpen,
            backfill: false,
            spaceId: nil,
            collectsId: platform == "douyin" ? config.douyinCollectsId : ""
        )
        if res.status == "handoff_required" || res.status == "login_required" {
            throw AuthRequiredError(platform: platform, message: res.message.nonEmpty ?? res.status)
        }
        if res.status != "ok" {
            if let sid = res.spaceId { browser.finishSpace(spaceId: sid) }
            throw NSError(domain: "EgoBrowser", code: 500, userInfo: [NSLocalizedDescriptionKey: res.message.nonEmpty ?? "\(platform) browser error (\(res.status))"])
        }

        var queuedAsr = 0
        let articles: [ArticlePayload]
        let seenIds: [String]
        do {
            if platform == "x_bookmarks" {
                (articles, seenIds) = XBookmarksParser.parse(
                    payloads: res.payloads,
                    domItems: res.domItems,
                    knownIds: srcState.known,
                    maxItems: maxItems,
                    config: config,
                    stopOnKnown: true,
                    http: http
                )
            } else {
                (articles, seenIds, queuedAsr) = try DouyinParser.parse(
                    payloads: res.payloads,
                    domItems: res.domItems,
                    knownIds: srcState.known,
                    maxItems: maxItems,
                    config: config,
                    asrClient: asr,
                    browser: browser,
                    spaceId: res.spaceId,
                    stopOnKnown: true,
                    logger: logger,
                    http: http
                )
            }
        } catch {
            if keepOpen, let sid = res.spaceId { browser.finishSpace(spaceId: sid) }
            throw error
        }
        if keepOpen, let sid = res.spaceId {
            browser.finishSpace(spaceId: sid)
        }

        var pushed = 0
        if !articles.isEmpty {
            srcState = state.sources[platform] ?? srcState
            srcState.outbox = articles
            state.sources[platform] = srcState
            try saveState()
            pushed = try flushOutbox(platform: platform, remoteIds: remoteIds)
        }

        srcState = state.sources[platform] ?? srcState
        if !seenIds.isEmpty {
            let cleanSeen = Set(seenIds.map(stripPrefixID).filter { !$0.isEmpty })
            srcState.known = Set(srcState.known).union(cleanSeen).sorted()
        }
        srcState.status = "ready"
        state.sources[platform] = srcState
        try saveState()

        logger.info(
            "[\(SourceNames.displayName(for: platform))] 增量完成: 新增入库 \(pushed) 条"
            + (replayed > 0 ? "，补传 \(replayed) 条" : "")
            + (queuedAsr > 0 ? "，直传 Koofr 待转写 \(queuedAsr) 条" : "")
        )
        return .object([
            "pushed": .int(pushed),
            "replayed": .int(replayed),
            "asr_queued": .int(queuedAsr),
        ])
    }

    private func syncXMonitorIncremental(limitOverride: Int?) throws -> JSONValue {
        let remoteBody = try fetchRemoteState(platform: "x_monitor")
        let remoteIds = Set(remoteBody.recentIds.map(stripPrefixID).filter { !$0.isEmpty })

        var srcState = state.sources["x_monitor"] ?? SourceState(name: SourceNames.displayName(for: "x_monitor"))
        srcState.known = Set(srcState.known).union(remoteIds).sorted()
        state.sources["x_monitor"] = srcState
        try saveState()

        let replayed = try flushOutbox(platform: "x_monitor", remoteIds: remoteIds)
        srcState = state.sources["x_monitor"] ?? srcState

        let xmEngine = XMonitorEngine(config: config, browser: browser, http: http, logger: logger)
        let monCfg = xmEngine.effectiveMonitorConfig(remote: remoteBody.xMonitorConfig)
        let users = xmEngine.mergeUsers(remoteUsers: remoteBody.monitoredUsers)
        let hasListURL = !monCfg.listURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if users.isEmpty && !hasListURL {
            logger.info("[X 用户监控] 当前无启用中的监控博主且未绑定 X List，跳过采集")
            return .object(["pushed": .int(0), "replayed": .int(replayed), "checked_users": .int(0)])
        }

        let orderedKnown = srcState.known.filter { !remoteIds.contains($0) } + remoteIds.sorted()
        let (articles, userStates, channel) = try xmEngine.collectIncremental(
            users: users,
            monitorCfg: monCfg,
            localKnownIds: Array(orderedKnown.suffix(500)),
            limitOverride: limitOverride,
            handoff: true
        )

        let recentNativeIds = articles.map { stripPrefixID($0.id) }.filter { !$0.isEmpty }
        var pushed = 0
        if !articles.isEmpty {
            srcState = state.sources["x_monitor"] ?? srcState
            let existingOutbox = srcState.outbox ?? []
            let existingIds = Set(existingOutbox.map(\.id))
            srcState.outbox = existingOutbox + articles.filter { !existingIds.contains($0.id) }
            state.sources["x_monitor"] = srcState
            try saveState()
            pushed = try flushOutbox(platform: "x_monitor", remoteIds: remoteIds)
        }

        srcState = state.sources["x_monitor"] ?? srcState
        var knownSet = Set(srcState.known)
        for rid in recentNativeIds where !rid.isEmpty {
            knownSet.insert(rid)
        }
        for uUpd in userStates.values {
            for rid in uUpd.recentIds ?? [] {
                let clean = stripPrefixID(rid)
                if !clean.isEmpty { knownSet.insert(clean) }
            }
        }
        srcState.known = knownSet.sorted()
        srcState.status = "ready"
        state.sources["x_monitor"] = srcState
        try saveState()

        if !userStates.isEmpty {
            _ = try? pushArticlesBatch(
                platform: "x_monitor",
                articles: [],
                recentIds: recentNativeIds,
                clean: false,
                forceClean: false,
                xMonitorUserStates: userStates
            )
        }

        let checkedCount = max(users.count, userStates.count)
        logger.info(
            "[X 用户监控] 通道 \(channel) 巡检 \(checkedCount) 位博主，新增入库 \(pushed) 条"
            + (replayed > 0 ? "，补传 \(replayed) 条" : "")
        )
        return .object([
            "pushed": .int(pushed),
            "replayed": .int(replayed),
            "checked_users": .int(checkedCount),
            "channel": .string(channel),
        ])
    }

    // MARK: - L2 Tampermonkey Passive Raw Ingest

    public func ingestRawPayloads(
        sourceType: String,
        payloads: [JSONValue],
        domItems: [[String: JSONValue]]? = nil,
        sourceName: String = "",
        clean: Bool = true
    ) throws -> [String: JSONValue] {
        guard ["x_bookmarks", "douyin", "x_monitor"].contains(sourceType) else {
            throw NSError(domain: "BoCollector", code: 422, userInfo: [NSLocalizedDescriptionKey: "不支持的 source_type: \(sourceType)"])
        }
        let remoteBody = try fetchRemoteState(platform: sourceType, sourceName: sourceName.nonEmpty)
        let remoteIds = Set(remoteBody.recentIds.map(stripPrefixID).filter { !$0.isEmpty })

        var articles: [ArticlePayload] = []
        var seenIds: [String] = []
        var userStates: [String: XMonitorUserStateUpdate]? = nil

        if sourceType == "x_bookmarks" {
            (articles, seenIds) = XBookmarksParser.parse(
                payloads: payloads,
                domItems: domItems,
                knownIds: Array(remoteIds),
                maxItems: 200,
                config: config,
                stopOnKnown: false,
                sourceName: sourceName.nonEmpty ?? "X 书签",
                http: http
            )
        } else if sourceType == "douyin" {
            let parsed = try DouyinParser.parse(
                payloads: payloads,
                domItems: domItems,
                knownIds: Array(remoteIds),
                maxItems: 100,
                config: config,
                asrClient: asr,
                browser: browser,
                spaceId: nil,
                stopOnKnown: false,
                sourceName: sourceName.nonEmpty ?? "抖音收藏",
                logger: logger,
                http: http
            )
            articles = parsed.articles
            seenIds = parsed.seenIds
        } else {
            let xmEngine = XMonitorEngine(config: config, browser: browser, http: http, logger: logger)
            let monCfg = xmEngine.effectiveMonitorConfig(remote: remoteBody.xMonitorConfig)
            let users = xmEngine.mergeUsers(remoteUsers: remoteBody.monitoredUsers)
            let parsed = xmEngine.parseRawPayloads(
                payloads: payloads,
                domItems: domItems,
                users: users,
                monitorCfg: monCfg,
                localKnownIds: Array(remoteIds),
                incremental: true,
                maxItemsPerUser: monCfg.maxItemsPerUser,
                onlyObservedUsers: true
            )
            articles = parsed.articles
            userStates = parsed.userStates
            seenIds = articles.map { stripPrefixID($0.id) }
        }

        if articles.isEmpty && (userStates?.isEmpty ?? true) {
            return [
                "status": .string("ok"),
                "mode": .string("remote_push"),
                "parsed": .int(0),
                "saved": .int(0),
                "duplicates": .int(0),
                "save_failed": .int(0),
            ]
        }

        let hasPendingAsr = articles.contains { $0.metadata["asr_status"]?.stringValue == "pending" }
        let effectiveClean = clean && !hasPendingAsr
        let cleanSeenIds = seenIds.map(stripPrefixID).filter { !$0.isEmpty }

        var saved = 0
        var dup = 0
        var failed = 0

        if articles.isEmpty {
            let pushRes = try pushArticlesBatch(
                platform: sourceType,
                articles: [],
                recentIds: cleanSeenIds,
                sourceName: sourceName.nonEmpty,
                clean: false,
                forceClean: false,
                xMonitorUserStates: userStates
            )
            saved += pushRes["saved"]?.intValue ?? 0
            dup += pushRes["duplicates"]?.intValue ?? 0
            failed += pushRes["save_failed"]?.intValue ?? 0
        } else {
            let chunkSize = effectiveClean ? 2 : max(1, articles.count)
            var idx = 0
            while idx < articles.count {
                let end = min(idx + chunkSize, articles.count)
                let slice = Array(articles[idx..<end])
                let sliceIds = slice.map { stripPrefixID($0.id) }.filter { !$0.isEmpty }
                let isLast = (end == articles.count)
                let pushRes = try pushArticlesBatch(
                    platform: sourceType,
                    articles: slice,
                    recentIds: isLast ? cleanSeenIds : sliceIds,
                    sourceName: sourceName.nonEmpty,
                    clean: effectiveClean,
                    forceClean: false,
                    xMonitorUserStates: nil
                )
                saved += pushRes["saved"]?.intValue ?? 0
                dup += pushRes["duplicates"]?.intValue ?? 0
                failed += pushRes["save_failed"]?.intValue ?? 0
                idx = end
            }
            if let userStates, !userStates.isEmpty {
                _ = try? pushArticlesBatch(
                    platform: sourceType,
                    articles: [],
                    recentIds: cleanSeenIds,
                    sourceName: sourceName.nonEmpty,
                    clean: false,
                    forceClean: false,
                    xMonitorUserStates: userStates
                )
            }
        }

        if failed == 0 {
            var src = state.sources[sourceType] ?? SourceState(name: SourceNames.displayName(for: sourceType))
            src.known = Set(src.known).union(seenIds.map(stripPrefixID).filter { !$0.isEmpty }).sorted()
            src.saved += saved
            state.sources[sourceType] = src
            try? saveState()
        }

        logger.info("[L2 油猴桥接] \(SourceNames.displayName(for: sourceType)) 解析 \(articles.count) 条 -> 云端入库 \(saved) 条")
        return [
            "status": .string("ok"),
            "mode": .string("remote_push"),
            "parsed": .int(articles.count),
            "saved": .int(saved),
            "duplicates": .int(dup),
            "save_failed": .int(failed),
        ]
    }

    // MARK: - Paced Historical Backfill

    public func runBackfillLoop(
        platforms: [String]? = nil,
        maxTotal: Int? = nil,
        restSeconds: Int = 300
    ) throws -> [String: JSONValue] {
        let targets = (platforms ?? ["x_bookmarks", "douyin"]).filter { $0 == "x_bookmarks" || $0 == "douyin" }
        let stopFlag = stateDir.appendingPathComponent("STOP")

        return try withRunLockThrowing { locked in
            guard locked else {
                throw NSError(domain: "BoCollector", code: 409, userInfo: [NSLocalizedDescriptionKey: "已有采集任务正在运行，请勿重复启动"])
            }
            try? FileManager.default.removeItem(at: stopFlag)

            for plat in targets {
                let remote = try fetchRemoteState(platform: plat)
                var src = state.sources[plat] ?? SourceState(name: SourceNames.displayName(for: plat))
                src.known = Set(src.known).union(remote.recentIds.map(stripPrefixID).filter { !$0.isEmpty }).sorted()
                if src.nextAt == nil { src.nextAt = 0 }
                if src.status != "completed" && src.status != "no_new_items" {
                    src.status = "ready"
                }
                state.sources[plat] = src
            }
            state.status = "running_backfill"
            try saveState()

            while !stopping && !FileManager.default.fileExists(atPath: stopFlag.path) {
                var active = false
                for plat in targets {
                    guard var src = state.sources[plat] else { continue }
                    if let maxTotal, src.saved >= maxTotal, (src.outbox?.isEmpty ?? true) {
                        src.status = "limit_reached"
                        state.sources[plat] = src
                    }
                    if ["completed", "no_new_items", "limit_reached"].contains(src.status) {
                        continue
                    }
                    active = true
                    if Date().timeIntervalSince1970 < (src.nextAt ?? 0) {
                        continue
                    }

                    do {
                        try backfillOneBatch(platform: plat, maxTotal: maxTotal, restSeconds: restSeconds)
                        healer.recordSuccess(state: &state)
                    } catch let authErr as AuthRequiredError {
                        healer.handleAuthPause(state: &state, platform: authErr.platform, reason: authErr.message)
                        state.status = "auth_paused"
                        try saveState()
                        return ["status": .string("auth_paused"), "platform": .string(authErr.platform)]
                    } catch {
                        let (label, transient) = ErrorSanitizer.summarize(error)
                        if !transient {
                            let (_, ibState) = asr.getInstaboxState()
                            _ = healer.handleUnexpectedFailure(state: &state, errorLabel: label, stage: "backfill:\(plat)", instaboxState: ibState)
                            state.status = "paused"
                            try saveState()
                            throw error
                        }
                        var cur = state.sources[plat] ?? src
                        let fails = (cur.failures ?? 0) + 1
                        cur.failures = fails
                        let backoff = min(1800, restSeconds * (1 << min(fails - 1, 3)))
                        cur.nextAt = Date().timeIntervalSince1970 + Double(backoff)
                        cur.status = "retry_wait"
                        state.sources[plat] = cur
                        try saveState()
                        logger.warn("[\(plat)] 可恢复异常 \(label)，退避后自动对账重试")
                    }
                }

                if Date().timeIntervalSince1970 >= (state.harvestAt ?? 0) {
                    _ = try? harvestAsr()
                    state.harvestAt = Date().timeIntervalSince1970 + 300
                    try saveState()
                }

                if !active && (state.asr?.stillPending ?? 0) == 0 {
                    let allDone = targets.allSatisfy { state.sources[$0]?.status == "completed" }
                    state.status = allDone ? "completed" : "needs_review"
                    try saveState()
                    if allDone, let sid = state.browserSpaceId {
                        browser.finishSpace(spaceId: sid)
                    }
                    break
                }
                Thread.sleep(forTimeInterval: 1.0)
            }

            if state.status == "running_backfill" {
                state.status = "stopped"
                try saveState()
            }
            return ["status": .string(state.status)]
        }
    }

    private func backfillOneBatch(platform: String, maxTotal: Int?, restSeconds: Int) throws {
        guard var src = state.sources[platform] else { return }
        if !(src.outbox?.isEmpty ?? true) {
            _ = try flushOutbox(platform: platform)
            try scheduleBackfillRest(platform: platform, restSeconds: restSeconds)
            return
        }

        if platform == "douyin", (src.sinceRest ?? 0) >= 100 {
            src.sinceRest = 0
            src.status = "resting"
            src.nextAt = Date().timeIntervalSince1970 + Double(restSeconds)
            state.sources[platform] = src
            try saveState()
            return
        }

        var limit = platform == "x_bookmarks" ? 10 : min(5, 100 - (src.sinceRest ?? 0))
        if let maxTotal {
            limit = min(limit, max(1, maxTotal - src.saved))
        }

        let spRes = browser.ensureSpace(spaceId: state.browserSpaceId)
        guard spRes.status == "ok", let ensuredSpaceId = spRes.spaceId else {
            throw AuthRequiredError(platform: platform, message: spRes.message.nonEmpty ?? "浏览器空间不可用")
        }
        if ensuredSpaceId != state.browserSpaceId {
            state.browserSpaceId = ensuredSpaceId
            for (k, var s) in state.sources {
                if var cap = s.capture {
                    cap.spaceId = ensuredSpaceId
                    s.capture = cap
                    state.sources[k] = s
                }
            }
            try saveState()
        }

        for _ in 0..<2 {
            src = state.sources[platform] ?? src
            var capture = src.capture
            if capture == nil && src.endSeen == true {
                src.status = "completed"
                state.sources[platform] = src
                try saveState()
                return
            }
            let fresh: Bool
            if capture == nil {
                let res = browser.collectFeed(
                    platform: platform,
                    knownIds: src.known,
                    maxItems: limit,
                    handoff: true,
                    keepOpen: true,
                    backfill: true,
                    spaceId: state.browserSpaceId,
                    collectsId: platform == "douyin" ? config.douyinCollectsId : ""
                )
                if res.status == "handoff_required" || res.status == "login_required" {
                    throw AuthRequiredError(platform: platform, message: res.message.nonEmpty ?? res.status)
                }
                if res.status != "ok" {
                    throw NSError(domain: "EgoBrowser", code: 500, userInfo: [NSLocalizedDescriptionKey: res.message.nonEmpty ?? "\(platform) backfill failed"])
                }
                let snap = CaptureSnapshot(payloads: res.payloads, domItems: res.domItems, spaceId: res.spaceId)
                state.browserSpaceId = res.spaceId
                src.capture = snap
                state.sources[platform] = src
                try saveState()
                capture = snap
                fresh = true
            } else {
                fresh = false
            }

            guard let snap = capture else { return }
            if FeedEndDetector.detectFeedEnded(platform: platform, payloads: snap.payloads) {
                src.endSeen = true
            }

            let articles: [ArticlePayload]
            let scannedIds: [String]
            if platform == "x_bookmarks" {
                (articles, scannedIds) = XBookmarksParser.parse(
                    payloads: snap.payloads,
                    domItems: snap.domItems,
                    knownIds: src.known,
                    maxItems: limit,
                    config: config,
                    stopOnKnown: false,
                    http: http
                )
            } else {
                (articles, scannedIds, _) = try DouyinParser.parse(
                    payloads: snap.payloads,
                    domItems: snap.domItems,
                    knownIds: src.known,
                    maxItems: limit,
                    config: config,
                    asrClient: asr,
                    browser: browser,
                    spaceId: snap.spaceId,
                    stopOnKnown: false,
                    logger: logger,
                    http: http
                )
            }

            if !articles.isEmpty {
                src.emptyRounds = 0
                src.outbox = articles
                state.sources[platform] = src
                try saveState()
                _ = try flushOutbox(platform: platform)
                try scheduleBackfillRest(platform: platform, restSeconds: restSeconds)
                return
            }

            src = state.sources[platform] ?? src
            src.capture = nil
            state.sources[platform] = src
            try saveState()

            if src.endSeen == true {
                src.status = "completed"
                state.sources[platform] = src
                try saveState()
                return
            }
            if fresh {
                let sig = scannedIds.isEmpty ? "" : Self.sha256Hex(scannedIds.joined(separator: ","))
                let advancing = !sig.isEmpty && sig != (src.scanSignature ?? "")
                src.scanSignature = sig
                let nextEmpty = advancing ? 0 : (src.emptyRounds ?? 0) + 1
                src.emptyRounds = nextEmpty
                src.status = nextEmpty >= 3 ? "no_new_items" : "resting"
                src.nextAt = Date().timeIntervalSince1970 + Double(restSeconds)
                state.sources[platform] = src
                try saveState()
                return
            }
        }
    }

    private func scheduleBackfillRest(platform: String, restSeconds: Int) throws {
        guard var src = state.sources[platform] else { return }
        let shouldRest = platform != "douyin" || (src.sinceRest ?? 0) >= 100
        src.nextAt = Date().timeIntervalSince1970 + Double(shouldRest ? restSeconds : 0)
        src.status = shouldRest ? "resting" : "ready"
        if shouldRest { src.sinceRest = 0 }
        src.failures = 0
        state.sources[platform] = src
        try saveState()
    }

    // MARK: - Legacy State Import & Doctor

    public func importLegacyState(from legacyURL: URL) throws -> [String: Int] {
        guard FileManager.default.fileExists(atPath: legacyURL.path) else {
            throw NSError(domain: "BoCollector", code: 404, userInfo: [NSLocalizedDescriptionKey: "未找到旧进度文件: \(legacyURL.path)"])
        }
        let data = try Data(contentsOf: legacyURL)
        let legacy = try JSONDecoder().decode(CollectorState.self, from: data)
        var importedCounts: [String: Int] = [:]

        for (plat, oldItem) in legacy.sources where SourceNames.mapping[plat] != nil {
            var cur = state.sources[plat] ?? SourceState(name: SourceNames.displayName(for: plat))
            let before = cur.known.count
            let mergedKnown = Set(cur.known).union(oldItem.known.map(stripPrefixID).filter { !$0.isEmpty }).sorted()
            cur.known = mergedKnown
            cur.saved = max(cur.saved, oldItem.saved)
            if let oldOutbox = oldItem.outbox, !oldOutbox.isEmpty, (cur.outbox?.isEmpty ?? true) {
                cur.outbox = oldOutbox
            }
            state.sources[plat] = cur
            importedCounts[plat] = mergedKnown.count - before
        }
        try saveState()
        return importedCounts
    }

    public static func runDoctor(config: CollectorConfig, runner: CommandRunner = DefaultCommandRunner()) -> [DoctorCheckItem] {
        var checks: [DoctorCheckItem] = []
        let fm = FileManager.default

        let cfgExists = fm.fileExists(atPath: config.configPath.path)
        var modeStr = "missing"
        if cfgExists, let attrs = try? fm.attributesOfItem(atPath: config.configPath.path),
           let perm = (attrs[.posixPermissions] as? NSNumber)?.intValue {
            modeStr = String(format: "0o%o", perm & 0o777)
        }
        checks.append(
            DoctorCheckItem(
                check: "config_file",
                ok: cfgExists && !config.remotePushURL.isEmpty && !config.remoteIngestToken.isEmpty,
                detail: "\(config.configPath.path) (mode=\(modeStr), proxy=\(config.proxyMode.rawValue))",
                critical: true
            )
        )

        let browser = EgoBrowserClient(cacheDir: config.cacheDir, spaceName: config.egoSpaceName, preferredBin: config.egoBin, runner: runner)
        let (egoOk, egoVer) = browser.checkVersion()
        checks.append(DoctorCheckItem(check: "ego_browser", ok: egoOk, detail: egoVer, critical: true))

        let silentLogger = SafeLogger(logPath: config.stateDir.appendingPathComponent("logs/collector.log"), echo: false)
        let engine = SyncEngine(config: config, logger: silentLogger, browser: browser, runner: runner)
        defer { engine.close() }

        var cloudOk = false
        var cloudDetail = "missing url or token"
        if !config.remotePushURL.isEmpty && !config.remoteIngestToken.isEmpty {
            do {
                let st = try engine.fetchRemoteState(platform: "x_bookmarks")
                cloudOk = true
                cloudDetail = "connected (\(config.remotePushURL), recent_x=\(st.recentIds.count))"
            } catch {
                cloudDetail = ErrorSanitizer.summarize(error).label
            }
        }
        checks.append(DoctorCheckItem(check: "cloud_ingest_api", ok: cloudOk, detail: cloudDetail, critical: true))

        if config.asrEnabled && config.asrProvider == .instaboxKoofr {
            var koofrOk = false
            var koofrDetail = "credentials not configured"
            if config.hasKoofrWebdav {
                do {
                    try engine.asr.ensureRemoteDirs()
                    koofrOk = true
                    koofrDetail = "WebDAV RW ready (ASR/inbox/\(config.koofrSubdir))"
                } catch {
                    koofrDetail = ErrorSanitizer.summarize(error).label
                }
            }
            checks.append(DoctorCheckItem(check: "koofr_webdav", ok: koofrOk, detail: koofrDetail, critical: true))

            let ibBin = KoofrAsrClient.findInstaboxBinary(preferred: config.instaboxBin)
            let (ibOk, ibState) = engine.asr.getInstaboxState(instaboxBin: ibBin)
            checks.append(
                DoctorCheckItem(
                    check: "instabox_sandbox",
                    ok: ibOk,
                    detail: ibBin != nil ? "\(config.instaboxAsrBox): \(ibState) (non-waking check)" : "instabox CLI missing",
                    critical: false
                )
            )
        } else if config.asrEnabled && config.asrProvider == .openaiAPI {
            checks.append(
                DoctorCheckItem(
                    check: "openai_asr_api",
                    ok: config.hasOpenAIAsr,
                    detail: config.hasOpenAIAsr ? "\(config.asrModel) @ \(config.asrApiBase)" : "ASR API Key 未配置",
                    critical: true
                )
            )
        }

        let orcaBin = IncidentHealer.findOrcaBinary(preferred: config.orcaBin)
        let svc = LaunchAgentManager.status(runner: runner)
        checks.append(
            DoctorCheckItem(
                check: "vlm_service_healer",
                ok: true,
                detail: "vlm=\(config.hasVLM ? config.vlmModel : "off"), launchd=\(svc.loaded ? "loaded" : "off"), orca=\(orcaBin != nil ? "found" : "missing")",
                critical: false
            )
        )
        return checks
    }

    // MARK: - POSIX flock Helpers

    private func withRunLock<T>(_ body: (Bool) -> T) -> T {
        let lockPath = stateDir.appendingPathComponent("run.lock")
        let fd = open(lockPath.path, O_WRONLY | O_CREAT, 0o600)
        guard fd >= 0 else { return body(false) }
        defer { _ = Darwin.close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            return body(false)
        }
        defer { _ = flock(fd, LOCK_UN) }
        return body(true)
    }

    private func withRunLockThrowing<T>(_ body: (Bool) throws -> T) throws -> T {
        let lockPath = stateDir.appendingPathComponent("run.lock")
        let fd = open(lockPath.path, O_WRONLY | O_CREAT, 0o600)
        guard fd >= 0 else { return try body(false) }
        defer { _ = Darwin.close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            return try body(false)
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try body(true)
    }

    private static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
