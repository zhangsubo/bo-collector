import BoCollectorCore
import Foundation
import XCTest

// MARK: - Test Mocks

final class TestBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ initial: T) {
        self.storage = initial
    }

    var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }
}

final class MockHTTPTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequestSpec) throws -> HTTPResponseData
    private let lock = NSLock()
    private(set) var recorded: [HTTPRequestSpec] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ spec: HTTPRequestSpec) throws -> HTTPResponseData {
        lock.lock()
        recorded.append(spec)
        lock.unlock()
        return try handler(spec)
    }
}

final class MockCommandRunner: CommandRunner, @unchecked Sendable {
    struct Call: Sendable {
        let executable: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private(set) var calls: [Call] = []
    private let handler: @Sendable (String, [String]) throws -> SubprocessResult

    init(_ handler: @escaping @Sendable (String, [String]) throws -> SubprocessResult) {
        self.handler = handler
    }

    func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?,
        timeout: TimeInterval
    ) throws -> SubprocessResult {
        lock.lock()
        calls.append(Call(executable: executable, arguments: arguments))
        lock.unlock()
        return try handler(executable, arguments)
    }
}

final class MockBrowserClient: BrowserCollecting, @unchecked Sendable {
    var available: Bool = true
    var feedResult: BrowserCollectResult = BrowserCollectResult(status: "ok")
    var monitorResult: BrowserCollectResult = BrowserCollectResult(status: "ok")
    var downloadedFiles: [String: Data] = [:]
    var lastFeedKnownIds: [String] = []
    var extractResultsByURL: [String: BrowserArticleExtractResult] = [:]
    var defaultExtractResult: BrowserArticleExtractResult = BrowserArticleExtractResult(status: "unavailable")
    var extractedURLs: [String] = []

    func isAvailable() -> Bool { available }
    func checkVersion() -> (ok: Bool, detail: String) { (available, "mock-ego 1.0") }
    func ensureSpace(spaceId: Int?) -> BrowserCollectResult { BrowserCollectResult(status: "ok", spaceId: spaceId ?? 42) }
    func finishSpace(spaceId: Int?) {}

    func collectFeed(
        platform: String,
        knownIds: [String],
        maxItems: Int,
        handoff: Bool,
        keepOpen: Bool,
        backfill: Bool,
        spaceId: Int?,
        collectsId: String
    ) -> BrowserCollectResult {
        lastFeedKnownIds = knownIds
        return feedResult
    }

    func collectXMonitor(
        handles: [String],
        knownIdsByHandle: [String: [String]],
        listURL: String,
        maxItemsPerUser: Int,
        handoff: Bool,
        keepOpen: Bool
    ) -> BrowserCollectResult {
        monitorResult
    }

    func downloadMediaBatch(
        downloads: [BrowserDownloadItem],
        referer: String,
        spaceId: Int?,
        finishWhenDone: Bool
    ) -> [String: String] {
        var out: [String: String] = [:]
        for item in downloads {
            if let data = downloadedFiles[item.url] {
                let destURL = URL(fileURLWithPath: item.dest)
                try? FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: destURL)
                out[item.id] = destURL.path
            }
        }
        return out
    }

    func extractReadableArticle(url: String, handoff: Bool) -> BrowserArticleExtractResult {
        extractedURLs.append(url)
        return extractResultsByURL[url] ?? defaultExtractResult
    }
}

// MARK: - Unit Tests

final class BoCollectorTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("BoCollectorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    private func makeTestConfig() -> CollectorConfig {
        var cfg = CollectorConfig()
        cfg.configPath = tempRoot.appendingPathComponent("config/config.json")
        cfg.stateDir = tempRoot.appendingPathComponent("state")
        cfg.cacheDir = tempRoot.appendingPathComponent("cache")
        cfg.remotePushURL = "https://distiller.example.com"
        cfg.remoteIngestToken = "test-ingest-token"
        cfg.koofrWebdavURL = "https://app.koofr.net/dav/Koofr"
        cfg.koofrEmail = "user@example.com"
        cfg.koofrAppPassword = "app-secret-password"
        cfg.koofrSubdir = "bo-distiller"
        cfg.instaboxAsrBox = "box-test"
        cfg.instaboxBin = "/usr/bin/true"
        return cfg
    }

    func testConfigAutoMigratesLegacyEnvAndImportsBoDistiller() throws {
        let cfgDir = tempRoot.appendingPathComponent("cfg")
        try FileManager.default.createDirectory(at: cfgDir, withIntermediateDirectories: true)
        let legacyEnv = cfgDir.appendingPathComponent("config.env")
        let envText = """
        REMOTE_PUSH_URL='https://distiller.example.com/'
        REMOTE_INGEST_TOKEN="tok_legacy_123"
        KOOFR_EMAIL='tester@example.com'
        KOOFR_APP_PASSWORD='pw_value'
        SYNC_MAX_ITEMS_X=45
        VLM_ENABLED=true
        VLM_MODEL=gpt-4o-mini
        """
        try envText.write(to: legacyEnv, atomically: true, encoding: .utf8)

        let jsonURL = cfgDir.appendingPathComponent("config.json")
        let migrated = CollectorConfig.load(
            configPath: jsonURL,
            stateDir: tempRoot.appendingPathComponent("state"),
            cacheDir: tempRoot.appendingPathComponent("cache"),
            environment: [:]
        )

        XCTAssertEqual(migrated.remotePushURL, "https://distiller.example.com")
        XCTAssertEqual(migrated.remoteIngestToken, "tok_legacy_123")
        XCTAssertEqual(migrated.koofrEmail, "tester@example.com")
        XCTAssertEqual(migrated.koofrAppPassword, "pw_value")
        XCTAssertEqual(migrated.syncMaxItemsX, 45)
        XCTAssertEqual(migrated.vlmModel, "gpt-4o-mini")
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path))

        let perms = try FileManager.default.attributesOfItem(atPath: jsonURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((perms?.intValue ?? 0) & 0o777, 0o600)

        // Also verify pure-Swift bo-distiller directory import with YAML provider inheritance
        let bdDir = tempRoot.appendingPathComponent("bo-distiller")
        try FileManager.default.createDirectory(at: bdDir, withIntermediateDirectories: true)
        try "INGEST_TOKEN=bd_ing_999\nVISION_API_KEY=vision_sec\n".write(
            to: bdDir.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )
        let yaml = """
        llm:
          default_provider: openai_compat
          providers:
            openai_compat:
              api_base: https://api.example.com/v1
              api_key: ${VISION_API_KEY}
              model: vision-flash-v1
        multimodal:
          remote_push_url: https://cloud.example.org
          vlm_enabled: true
        """
        try yaml.write(to: bdDir.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)

        var importedCfg = CollectorConfig()
        importedCfg.configPath = cfgDir.appendingPathComponent("imported.json")
        let fields = try importedCfg.importFromBoDistiller(directory: bdDir)
        XCTAssertTrue(fields.contains("remote_ingest_token"))
        XCTAssertEqual(importedCfg.remotePushURL, "https://cloud.example.org")
        XCTAssertEqual(importedCfg.remoteIngestToken, "bd_ing_999")
        XCTAssertEqual(importedCfg.vlmApiBase, "https://api.example.com/v1")
        XCTAssertEqual(importedCfg.vlmApiKey, "vision_sec")
        XCTAssertEqual(importedCfg.vlmModel, "vision-flash-v1")
    }

    func testXBookmarksGraphQLParserExtractsLongTweetQuoteAndStopsOnKnown() throws {
        let cfg = makeTestConfig()
        let http = MockHTTPTransport { _ in HTTPResponseData(statusCode: 200) }

        let graphqlPayload = try JSONValue.parse(string: """
        {
          "data": {
            "bookmark_timeline_v2": {
              "timeline": {
                "instructions": [
                  {
                    "type": "TimelineAddEntries",
                    "entries": [
                      {
                        "entryId": "tweet-19001",
                        "content": {
                          "itemContent": {
                            "tweet_results": {
                              "result": {
                                "__typename": "Tweet",
                                "rest_id": "19001",
                                "core": {
                                  "user_results": {
                                    "result": {
                                      "rest_id": "u1",
                                      "legacy": { "name": "Alice", "screen_name": "alice_dev" }
                                    }
                                  }
                                },
                                "note_tweet": {
                                  "note_tweet_results": {
                                    "result": {
                                      "text": "Deep dive into Swift 6 concurrency https://t.co/xyz",
                                      "entity_set": {
                                        "urls": [{ "url": "https://t.co/xyz", "expanded_url": "https://swift.org/blog" }]
                                      }
                                    }
                                  }
                                },
                                "quoted_status_result": {
                                  "result": {
                                    "__typename": "Tweet",
                                    "rest_id": "18999",
                                    "core": {
                                      "user_results": {
                                        "result": { "rest_id": "u2", "legacy": { "name": "Bob", "screen_name": "bob" } }
                                      }
                                    },
                                    "legacy": { "full_text": "Original benchmark numbers" }
                                  }
                                },
                                "legacy": {
                                  "full_text": "Short truncated",
                                  "created_at": "Wed Oct 10 20:19:24 +0000 2018",
                                  "favorite_count": 88,
                                  "bookmark_count": 12
                                }
                              }
                            }
                          }
                        }
                      },
                      {
                        "entryId": "tweet-19000",
                        "content": {
                          "itemContent": {
                            "tweet_results": {
                              "result": {
                                "__typename": "Tweet",
                                "rest_id": "19000",
                                "legacy": { "full_text": "Already known bookmark" }
                              }
                            }
                          }
                        }
                      }
                    ]
                  }
                ]
              }
            }
          }
        }
        """)

        let (articles, seenIds) = XBookmarksParser.parse(
            payloads: [graphqlPayload],
            domItems: nil,
            knownIds: ["19000"],
            maxItems: 30,
            config: cfg,
            stopOnKnown: true,
            http: http
        )

        XCTAssertEqual(articles.count, 1)
        XCTAssertEqual(seenIds, ["19001", "19000"])
        XCTAssertEqual(articles[0].id, "x_19001")
        XCTAssertTrue(articles[0].content.contains("https://swift.org/blog"))
        XCTAssertTrue(articles[0].content.contains("> **引用 @bob**"))
        XCTAssertEqual(articles[0].metadata["favorite_count"]?.intValue, 88)
    }

    func testDouyinParserStreamsSubtitlelessVideoToKoofrAndWakesInstabox() throws {
        let cfg = makeTestConfig()
        let fakeVideoBytes = Data(repeating: 0xAB, count: 4096)

        let http = MockHTTPTransport { spec in
            if spec.method == "PROPFIND" {
                return HTTPResponseData(statusCode: 207)
            }
            if spec.method == "HEAD" {
                return HTTPResponseData(statusCode: 404)
            }
            if spec.method == "PUT" {
                XCTAssertNotNil(spec.uploadFileURL)
                return HTTPResponseData(statusCode: 201)
            }
            return HTTPResponseData(statusCode: 200)
        }

        let cmdRunner = MockCommandRunner { _, args in
            if args.first == "get" {
                return SubprocessResult(exitCode: 0, stdout: "{\"state\":\"running\"}")
            }
            if args.first == "exec" {
                XCTAssertTrue(args.joined(separator: " ").contains("systemctl --user start --no-block"))
                return SubprocessResult(exitCode: 0, stdout: "ok")
            }
            return SubprocessResult(exitCode: 0)
        }

        let browser = MockBrowserClient()
        browser.downloadedFiles["https://cdn.douyin.example/sub1.json"] = Data("{\"utterances\":[{\"text\":\"第一句字幕\"},{\"text\":\"第二句字幕\"}]}".utf8)
        browser.downloadedFiles["https://cdn.douyin.example/v2.mp4"] = fakeVideoBytes

        let asrClient = KoofrAsrClient(config: cfg, http: http, runner: cmdRunner)

        let payload = try JSONValue.parse(string: """
        {
          "status_code": 0,
          "has_more": 0,
          "aweme_list": [
            {
              "aweme_id": "7001",
              "desc": "带原生字幕作品 #AI工具",
              "author": { "nickname": "测试作者" },
              "video": {
                "duration": 30000,
                "cla_info": { "caption_infos": [{ "url": "https://cdn.douyin.example/sub1.json" }] },
                "play_addr": { "url_list": ["https://cdn.douyin.example/v1.mp4"] }
              }
            },
            {
              "aweme_id": "7002",
              "desc": "无字幕干货视频",
              "author": { "nickname": "口播博主" },
              "video": {
                "duration": 45000,
                "play_addr": { "url_list": ["https://cdn.douyin.example/v2.mp4"] }
              }
            }
          ]
        }
        """)

        let (articles, _, queuedAsr) = try DouyinParser.parse(
            payloads: [payload],
            domItems: nil,
            knownIds: [],
            maxItems: 20,
            config: cfg,
            asrClient: asrClient,
            browser: browser,
            spaceId: 1,
            http: http
        )

        XCTAssertEqual(articles.count, 2)
        XCTAssertEqual(queuedAsr, 1)
        XCTAssertTrue(articles[0].content.contains("第一句字幕\n第二句字幕"))
        XCTAssertNil(articles[0].metadata["asr_status"])
        XCTAssertEqual(articles[1].metadata["asr_status"]?.stringValue, "pending")
        XCTAssertEqual(articles[1].metadata["asr_inbox_media"]?.stringValue, "bo-distiller/dy_7002.mp4")
        XCTAssertEqual(articles[1].metadata["asr_remote_md"]?.stringValue, "bo-distiller/dy_7002.md")
        XCTAssertTrue(FeedEndDetector.detectFeedEnded(platform: "douyin", payloads: [payload]))

        let propfindCount = http.recorded.filter { $0.method == "PROPFIND" }.count
        let putCount = http.recorded.filter { $0.method == "PUT" }.count
        XCTAssertEqual(propfindCount, 2)
        XCTAssertEqual(putCount, 1)
        XCTAssertTrue(cmdRunner.calls.contains(where: { $0.arguments.first == "exec" }))
    }

    func testAsrHarvestMergesTranscriptAndDeletesInboxVideo() throws {
        let cfg = makeTestConfig()
        let pushedBodies = TestBox<[JSONValue]>([])
        let deletedURLs = TestBox<[String]>([])

        let http = MockHTTPTransport { spec in
            let urlStr = spec.url.absoluteString
            if urlStr.contains("/api/ingest/state") {
                let pendingJSON: JSONValue = .object([
                    "status": .string("ok"),
                    "recent_ids": .array([.string("7002")]),
                    "pending_asr_articles": .array([
                        .object([
                            "id": .string("dy_7002"),
                            "title": .string("抖音-口播博主-无字幕干货视频"),
                            "content": .string("**原帖文案**：无字幕干货视频"),
                            "url": .string("https://www.douyin.com/video/7002"),
                            "source": .object(["type": .string("douyin"), "name": .string("抖音收藏"), "identifier": .string("douyin")]),
                            "fetched_date": .string("2026-11-13T10:00:00Z"),
                            "metadata": .object([
                                "aweme_id": .string("7002"),
                                "extraction_layers": .array([.string("koofr_asr_queued")]),
                                "asr_status": .string("pending"),
                                "asr_inbox_media": .string("bo-distiller/dy_7002.mp4"),
                                "asr_remote_md": .string("bo-distiller/dy_7002.md"),
                            ]),
                        ])
                    ]),
                ])
                return HTTPResponseData(statusCode: 200, data: try pendingJSON.toData())
            }
            if spec.method == "GET" && urlStr.contains("/ASR/output/bo-distiller/dy_7002.md") {
                let md = "---\nsource: sensevoice\n---\n<|zh|><|NEUTRAL|>这里是完整转写口播正文。"
                return HTTPResponseData(statusCode: 200, data: Data(md.utf8))
            }
            if spec.method == "POST" && urlStr.contains("/api/ingest/articles") {
                if let b = spec.body, let parsed = try? JSONValue.parse(data: b) {
                    pushedBodies.withLock { $0.append(parsed) }
                }
                return HTTPResponseData(statusCode: 200, data: Data("{\"status\":\"ok\",\"saved\":1,\"duplicates\":0,\"save_failed\":0}".utf8))
            }
            if spec.method == "DELETE" {
                deletedURLs.withLock { $0.append(urlStr) }
                return HTTPResponseData(statusCode: 204)
            }
            return HTTPResponseData(statusCode: 200)
        }

        let logger = SafeLogger(logPath: cfg.stateDir.appendingPathComponent("logs/collector.log"), echo: false)
        let engine = SyncEngine(config: cfg, logger: logger, browser: MockBrowserClient(), http: http)
        defer { engine.close() }

        let summary = try engine.harvestAsr()
        XCTAssertEqual(summary.checked, 1)
        XCTAssertEqual(summary.completed, 1)
        XCTAssertEqual(summary.stillPending, 0)
        XCTAssertEqual(deletedURLs.value, ["https://app.koofr.net/dav/Koofr/ASR/inbox/bo-distiller/dy_7002.mp4"])

        let pushedArt = pushedBodies.value.first?["articles"]?.arrayValue?.first
        XCTAssertEqual(pushedBodies.value.first?["force_clean"]?.boolValue, true)
        XCTAssertEqual(pushedArt?["metadata"]?["asr_status"]?.stringValue, "completed")
        XCTAssertTrue((pushedArt?["content"]?.stringValue ?? "").contains("## 视频口播全文\n\n这里是完整转写口播正文。"))
    }

    func testXMonitorFilterAndPinnedTweetDoesNotCutOffNewTweets() throws {
        var cfg = makeTestConfig()
        cfg.xMonitorEnabled = true
        let http = MockHTTPTransport { _ in HTTPResponseData(statusCode: 200) }
        let mockBrowser = MockBrowserClient()
        let xmEngine = XMonitorEngine(config: cfg, browser: mockBrowser, http: http)

        var user = XMonitorUser(handle: "karpathy", enabled: true)
        user.lastTweetId = "1050"
        user.recentIds = ["1050", "900"]
        user.tags = ["AI"]

        let gqlPayload = try JSONValue.parse(string: """
        {
          "data": {
            "user": {
              "result": {
                "timeline_v2": {
                  "timeline": {
                    "instructions": [
                      {
                        "type": "TimelinePinEntry",
                        "entry": {
                          "entryId": "tweet-900",
                          "content": {
                            "itemContent": {
                              "tweet_results": {
                                "result": {
                                  "__typename": "Tweet",
                                  "rest_id": "900",
                                  "core": { "user_results": { "result": { "rest_id": "u1", "legacy": { "name": "Andrej", "screen_name": "karpathy" } } } },
                                  "legacy": { "full_text": "Old pinned announcement with enough length to pass filter easily." }
                                }
                              }
                            }
                          }
                        }
                      },
                      {
                        "type": "TimelineAddEntries",
                        "entries": [
                          {
                            "entryId": "tweet-1060",
                            "content": {
                              "itemContent": {
                                "tweet_results": {
                                  "result": {
                                    "__typename": "Tweet",
                                    "rest_id": "1060",
                                    "core": { "user_results": { "result": { "rest_id": "u1", "legacy": { "name": "Andrej", "screen_name": "karpathy" } } } },
                                    "legacy": { "full_text": "lol" }
                                  }
                                }
                              }
                            }
                          },
                          {
                            "entryId": "tweet-1055",
                            "content": {
                              "itemContent": {
                                "tweet_results": {
                                  "result": {
                                    "__typename": "Tweet",
                                    "rest_id": "1055",
                                    "core": { "user_results": { "result": { "rest_id": "u1", "legacy": { "name": "Andrej", "screen_name": "karpathy" } } } },
                                    "legacy": { "full_text": "New detailed post about LLM pretraining pipelines and tokenizer tradeoffs." }
                                  }
                                }
                              }
                            }
                          },
                          {
                            "entryId": "tweet-1050",
                            "content": {
                              "itemContent": {
                                "tweet_results": {
                                  "result": {
                                    "__typename": "Tweet",
                                    "rest_id": "1050",
                                    "core": { "user_results": { "result": { "rest_id": "u1", "legacy": { "name": "Andrej", "screen_name": "karpathy" } } } },
                                    "legacy": { "full_text": "Previous watermark tweet that was already ingested earlier." }
                                  }
                                }
                              }
                            }
                          }
                        ]
                      }
                    ]
                  }
                }
              }
            }
          }
        }
        """)

        mockBrowser.monitorResult = BrowserCollectResult(status: "ok", payloads: [gqlPayload])
        let (articles, states, channel) = try xmEngine.collectIncremental(
            users: [user],
            monitorCfg: XMonitorRemoteConfig()
        )

        // Tweet 900 is pinned (skipped without cutting off 1060/1055), 1060 is short noise ("lol") filtered out
        // YET 1060 still advances watermark to "1060", and 1055 is captured via local ego-lite!
        XCTAssertEqual(channel, "ego")
        XCTAssertEqual(articles.count, 1)
        XCTAssertEqual(articles[0].id, "xm_1055")
        XCTAssertEqual(articles[0].source.name, "@karpathy")
        XCTAssertEqual(states["karpathy"]?.lastTweetId, "1060")
        XCTAssertEqual(states["karpathy"]?.capturedDelta, 1)

        // Also verify standalone X List mode when users == [] (auto-discovers List members & respects localKnownIds)
        var listCfg = XMonitorRemoteConfig()
        listCfg.listURL = "https://x.com/i/lists/1234567890123456789"
        let (listArts, listStates, listChannel) = try xmEngine.collectIncremental(
            users: [],
            monitorCfg: listCfg,
            localKnownIds: ["1050", "900"]
        )
        XCTAssertEqual(listChannel, "ego")
        XCTAssertEqual(listArts.map(\.id), ["xm_1055"])
        XCTAssertEqual(listStates["karpathy"]?.lastTweetId, "1060")
    }

    func testXMonitorStandaloneListOutboxPerArticlePushAndCrashRecovery() throws {
        var cfg = makeTestConfig()
        cfg.xBookmarksEnabled = false
        cfg.douyinEnabled = false
        cfg.xMonitorEnabled = true
        cfg.xMonitorListURL = "https://x.com/i/lists/1234567890123456789"

        let gqlPayload = try JSONValue.parse(string: """
        {
          "data": {
            "list": {
              "tweets_timeline": {
                "timeline": {
                  "instructions": [
                    {
                      "type": "TimelineAddEntries",
                      "entries": [
                        {
                          "entryId": "tweet-2002",
                          "content": {
                            "itemContent": {
                              "tweet_results": {
                                "result": {
                                  "__typename": "Tweet",
                                  "rest_id": "2002",
                                  "core": { "user_results": { "result": { "rest_id": "u2", "legacy": { "name": "Simon", "screen_name": "simonw" } } } },
                                  "legacy": { "full_text": "Second list post with substantial technical content about SQLite and LLM tools." }
                                }
                              }
                            }
                          }
                        },
                        {
                          "entryId": "tweet-2001",
                          "content": {
                            "itemContent": {
                              "tweet_results": {
                                "result": {
                                  "__typename": "Tweet",
                                  "rest_id": "2001",
                                  "core": { "user_results": { "result": { "rest_id": "u1", "legacy": { "name": "Andrej", "screen_name": "karpathy" } } } },
                                  "legacy": { "full_text": "First list post with substantial technical content about neural network training." }
                                }
                              }
                            }
                          }
                        }
                      ]
                    }
                  ]
                }
              }
            }
          }
        }
        """)

        let postedPayloads = TestBox<[JSONValue]>([])
        let dropSecondArticleOnce = TestBox<Bool>(true)
        let articlePostCalls = TestBox<Int>(0)

        let http = MockHTTPTransport { spec in
            if spec.url.absoluteString.contains("/api/ingest/state") {
                let stateResp: JSONValue = .object([
                    "status": .string("ok"),
                    "recent_ids": .array([]),
                    "monitored_users": .array([]),
                ])
                return HTTPResponseData(statusCode: 200, data: try stateResp.toData())
            }
            if spec.url.absoluteString.contains("/api/ingest/articles") {
                let body = try JSONValue.parse(data: spec.body ?? Data())
                let arts = body["articles"]?.arrayValue ?? []
                if !arts.isEmpty {
                    let callNum = articlePostCalls.withLock {
                        $0 += 1
                        return $0
                    }
                    // Verify each pushSingleArticle sends at most 1 article per request (Cloudflare <100s safe)
                    XCTAssertEqual(arts.count, 1)
                    if callNum == 2 && dropSecondArticleOnce.value {
                        dropSecondArticleOnce.value = false
                        throw HTTPTransportError(message: "URLError(-1005): The network connection was lost.")
                    }
                }
                postedPayloads.withLock { $0.append(body) }
                return HTTPResponseData(
                    statusCode: 200,
                    data: Data("{\"status\":\"ok\",\"saved\":\(arts.count),\"duplicates\":0,\"save_failed\":0}".utf8)
                )
            }
            return HTTPResponseData(statusCode: 200)
        }

        let logger = SafeLogger(logPath: cfg.stateDir.appendingPathComponent("logs/collector.log"), echo: false)
        let mockBrowser = MockBrowserClient()
        mockBrowser.monitorResult = BrowserCollectResult(status: "ok", payloads: [gqlPayload])
        let engine = SyncEngine(config: cfg, logger: logger, browser: mockBrowser, http: http)
        defer { engine.close() }

        // Run 1: tweet 2001 succeeds & acknowledged; tweet 2002 hits URLError(-1005) -> transient retry_wait, stays in outbox!
        let firstRes = engine.syncOnce(platforms: ["x_monitor"])
        XCTAssertEqual(firstRes["status"]?.stringValue, "retry_wait")
        XCTAssertEqual(engine.state.sources["x_monitor"]?.saved, 1)
        XCTAssertEqual(engine.state.sources["x_monitor"]?.known, ["2001"])
        XCTAssertEqual(engine.state.sources["x_monitor"]?.outbox?.map(\.id), ["xm_2002"])

        // Run 2: outbox replays xm_2002 first, then incremental scan sees 2001 & 2002 already known -> 0 duplicates, exact saved == 2!
        let secondRes = engine.syncOnce(platforms: ["x_monitor"])
        XCTAssertEqual(secondRes["status"]?.stringValue, "ok")
        XCTAssertNil(engine.state.sources["x_monitor"]?.outbox)
        XCTAssertEqual(engine.state.sources["x_monitor"]?.saved, 2)
        XCTAssertEqual(engine.state.sources["x_monitor"]?.known, ["2001", "2002"])

        // Metadata state sync sent with clean == false and x_monitor_user_states populated
        let stateSyncPost = postedPayloads.value.last
        XCTAssertEqual(stateSyncPost?["clean"]?.boolValue, false)
        XCTAssertNotNil(stateSyncPost?["x_monitor_user_states"]?["karpathy"])
        XCTAssertNotNil(stateSyncPost?["x_monitor_user_states"]?["simonw"])
    }

    func testOutboxReconciliationAnd422PipelineBusyRetry() throws {
        var cfg = makeTestConfig()
        cfg.douyinEnabled = false

        let returnBusy422 = TestBox<Bool>(true)
        let http = MockHTTPTransport { spec in
            if spec.url.absoluteString.contains("/api/ingest/state") {
                let stateResp: JSONValue = .object([
                    "status": .string("ok"),
                    "recent_ids": .array([.string("already_in_cloud_1")]),
                    "pending_asr_articles": .array([]),
                ])
                return HTTPResponseData(statusCode: 200, data: try stateResp.toData())
            }
            if spec.url.absoluteString.contains("/api/ingest/articles") {
                if returnBusy422.value {
                    return HTTPResponseData(
                        statusCode: 422,
                        data: Data("{\"detail\":\"已有内容处理任务运行中，请稍后重试\"}".utf8)
                    )
                }
                return HTTPResponseData(
                    statusCode: 200,
                    data: Data("{\"status\":\"ok\",\"saved\":1,\"duplicates\":0,\"save_failed\":0}".utf8)
                )
            }
            return HTTPResponseData(statusCode: 200)
        }

        let logger = SafeLogger(logPath: cfg.stateDir.appendingPathComponent("logs/collector.log"), echo: false)
        let browser = MockBrowserClient()
        let engine = SyncEngine(config: cfg, logger: logger, browser: browser, http: http)
        defer { engine.close() }

        let a1 = ArticlePayload(
            id: "x_already_in_cloud_1",
            title: "Already Saved",
            content: "Text 1",
            url: "https://x.com/i/status/1",
            source: ArticleSourceInfo(type: "x_bookmarks", name: "X 书签", identifier: "https://x.com/i/bookmarks"),
            author: "@u"
        )
        let a2 = ArticlePayload(
            id: "x_need_push_2",
            title: "Need Push",
            content: "Text 2",
            url: "https://x.com/i/status/2",
            source: ArticleSourceInfo(type: "x_bookmarks", name: "X 书签", identifier: "https://x.com/i/bookmarks"),
            author: "@u"
        )
        var src = SourceState(name: "X 书签", known: [], saved: 0, status: "ready")
        src.outbox = [a1, a2]
        engine.state.sources["x_bookmarks"] = src
        try engine.saveState()

        // First run: a1 reconciled without POST, a2 hits HTTP 422 busy -> retry_wait & remains in outbox
        let firstRes = engine.syncOnce(platforms: ["x_bookmarks"])
        XCTAssertEqual(firstRes["status"]?.stringValue, "retry_wait")
        XCTAssertEqual(engine.state.sources["x_bookmarks"]?.outbox?.map(\.id), ["x_need_push_2"])

        // Second run: pipeline free -> outbox flushed cleanly
        returnBusy422.value = false
        let secondRes = engine.syncOnce(platforms: ["x_bookmarks"])
        XCTAssertEqual(secondRes["status"]?.stringValue, "ok")
        XCTAssertNil(engine.state.sources["x_bookmarks"]?.outbox)
        XCTAssertEqual(engine.state.sources["x_bookmarks"]?.saved, 2)
    }

    func testIncidentHealerSanitizationAuthPauseAndOrcaTrigger() throws {
        var cfg = makeTestConfig()
        cfg.orcaBin = "/usr/bin/true"
        cfg.orcaHealAutomationId = "auto_heal_123"

        let sanitized = ErrorSanitizer.sanitizeDetail("Failed https://user:pass123@example.com/api?token=sec999 Authorization: Bearer my_jwt_tok")
        XCTAssertFalse(sanitized.contains("pass123"))
        XCTAssertFalse(sanitized.contains("sec999"))
        XCTAssertFalse(sanitized.contains("my_jwt_tok"))

        let cmdRunner = MockCommandRunner { _, args in
            if args.contains("runs") {
                return SubprocessResult(exitCode: 0, stdout: "{\"ok\":true,\"result\":{\"runs\":[]}}")
            }
            if args.contains("run") {
                return SubprocessResult(exitCode: 0, stdout: "{\"ok\":true}")
            }
            return SubprocessResult(exitCode: 0)
        }

        let logger = SafeLogger(logPath: cfg.stateDir.appendingPathComponent("logs/collector.log"), echo: false)
        let healer = IncidentHealer(config: cfg, logger: logger, projectRoot: tempRoot, runner: cmdRunner)
        var state = CollectorState()

        healer.handleAuthPause(state: &state, platform: "douyin", reason: "滑块验证")
        XCTAssertEqual(state.healer?.authPaused, true)
        XCTAssertFalse(cmdRunner.calls.contains(where: { $0.arguments.contains("automations") }))

        // Browser net::ERR_TIMED_OUT must be treated as transient network jitter, not a code bug
        let gotoErr = NSError(domain: "EgoBrowser", code: 500, userInfo: [NSLocalizedDescriptionKey: "page.goto failed: net::ERR_TIMED_OUT"])
        let (_, isTimeoutTransient) = ErrorSanitizer.summarize(gotoErr)
        XCTAssertTrue(isTimeoutTransient)

        // First code failure: below threshold (1/2)
        let f1 = healer.handleUnexpectedFailure(state: &state, errorLabel: "CloudHTTPError HTTP 401", stage: "sync:x_bookmarks")
        XCTAssertEqual(f1["triggered"]?.boolValue, false)

        // Second consecutive code failure: writes incident.json and wakes Orca automation
        let f2 = healer.handleUnexpectedFailure(state: &state, errorLabel: "CloudHTTPError HTTP 401", stage: "sync:x_bookmarks")
        XCTAssertEqual(f2["triggered"]?.boolValue, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: healer.incidentPath.path))
    }

    func testLocalBridgeServerEndToEndOverLoopback() throws {
        var cfg = makeTestConfig()
        cfg.bridgeToken = "local-bridge-tok"
        let bridgeCfg = cfg
        let logger = SafeLogger(logPath: bridgeCfg.stateDir.appendingPathComponent("logs/collector.log"), echo: false)

        let server = LocalBridgeServer(
            configProvider: { bridgeCfg },
            logger: logger,
            ingestHandler: { sourceType, payloads, _, _, _ in
                return [
                    "status": .string("ok"),
                    "mode": .string("remote_push"),
                    "source_type": .string(sourceType),
                    "parsed": .int(payloads.count),
                    "saved": .int(payloads.count),
                    "duplicates": .int(0),
                    "save_failed": .int(0),
                ]
            }
        )
        try server.start(portOverride: 0)
        defer { server.stop() }

        let port = server.listeningPort
        XCTAssertGreaterThan(port, 0)

        let client = URLSessionHTTPTransport(config: cfg)
        defer { client.close() }

        // 1. /healthz
        let healthResp = try client.send(HTTPRequestSpec(method: "GET", url: URL(string: "http://127.0.0.1:\(port)/healthz")!))
        XCTAssertEqual(healthResp.statusCode, 200)
        XCTAssertEqual((try healthResp.json())["mode"]?.stringValue, "local_bridge")

        // 2. /api/ingest/userscript.user.js
        let jsResp = try client.send(HTTPRequestSpec(method: "GET", url: URL(string: "http://127.0.0.1:\(port)/api/ingest/userscript.user.js")!))
        XCTAssertEqual(jsResp.statusCode, 200)
        XCTAssertTrue(jsResp.text.contains("==UserScript=="))
        XCTAssertTrue(jsResp.text.contains("http://127.0.0.1:\(port)"))

        // 3. Unauthorized /api/ingest/raw without token -> 401
        let unauthResp = try client.send(
            HTTPRequestSpec(
                method: "POST",
                url: URL(string: "http://127.0.0.1:\(port)/api/ingest/raw")!,
                headers: ["Content-Type": "application/json"],
                body: Data("{\"source_type\":\"x_bookmarks\",\"payloads\":[{}]}".utf8)
            )
        )
        XCTAssertEqual(unauthResp.statusCode, 401)

        // 4. Authorized /api/ingest/raw -> 200
        let authResp = try client.send(
            HTTPRequestSpec(
                method: "POST",
                url: URL(string: "http://127.0.0.1:\(port)/api/ingest/raw")!,
                headers: [
                    "Content-Type": "application/json",
                    "Authorization": "Bearer local-bridge-tok",
                    "Origin": "https://x.com",
                ],
                body: Data("{\"source_type\":\"x_bookmarks\",\"payloads\":[{\"a\":1},{\"b\":2}]}".utf8)
            )
        )
        XCTAssertEqual(authResp.statusCode, 200)
        XCTAssertEqual(authResp.header("access-control-allow-origin"), "https://x.com")
        let rawJSON = try authResp.json()
        XCTAssertEqual(rawJSON["saved"]?.intValue, 2)
    }

    func testArticleRefetchMarkdownExtractionAndInterstitialBoundary() throws {
        let baseURL = URL(string: "https://blog.example.com/posts/2026/rss-design")!
        let blogHTML = """
        <!doctype html>
        <html>
        <head><title>Ignored Site Suffix</title><script>if (1 < 2 && 3 > 1) { console.log("ok"); }</script></head>
        <body>
          <nav><a href="/home">Home</a></nav>
          <article>
            <h1>Designing Three-Tier RSS Full-Text Recovery</h1>
            <p>Modern feeds often ship truncated summaries. See <a href="/docs/spec">the specification</a> for background details and edge constraints across cloud and residential networks.</p>
            <img src="/assets/architecture.png" alt="Architecture Diagram" />
            <img src="https://tracker.example.com/pixel.gif" width="1" height="1" />
            <pre><code class="language-swift">let ok = true
        print(ok)</code></pre>
            <ul>
              <li>Server-first direct extraction</li>
              <li>Mac residential proxy and browser fallback</li>
            </ul>
            <p>This paragraph ensures the extracted body comfortably exceeds the minimum readable character threshold for full-text upgrades.</p>
          </article>
          <footer>Copyright 2026</footer>
        </body>
        </html>
        """

        let extracted = ArticleRefetchEngine.extractMarkdownFromHTML(blogHTML, baseURL: baseURL)
        XCTAssertNotNil(extracted)
        XCTAssertEqual(extracted?.title, "Designing Three-Tier RSS Full-Text Recovery")
        let md = extracted?.markdown ?? ""
        XCTAssertTrue(md.contains("# Designing Three-Tier RSS Full-Text Recovery"))
        XCTAssertTrue(md.contains("[the specification](https://blog.example.com/docs/spec)"))
        XCTAssertTrue(md.contains("![Architecture Diagram](https://blog.example.com/assets/architecture.png)"))
        XCTAssertFalse(md.contains("pixel.gif"))
        XCTAssertTrue(md.contains("```swift\nlet ok = true"))
        XCTAssertTrue(md.contains("- Server-first direct extraction"))
        XCTAssertFalse(md.contains("Copyright 2026"))

        // WeChat #js_content often carries style="visibility: hidden;" in static HTML and uses data-src on images
        let wechatHTML = """
        <html><body>
          <h1 id="activity-name">微信公众号深度技术长文标题</h1>
          <div id="js_content" style="visibility: hidden;">
            <p>这是一篇来自微信公众号 RSS 源的正文内容，用于验证在未执行前端脚本把 visibility 改为 visible 之前，原生解析器依然能够保留 #js_content 容器并正确解析懒加载图片与段落结构。</p>
            <p><img data-src="https://mmbiz.qpic.cn/mmbiz_png/demo123/640?wx_fmt=png" alt="示意图" /></p>
            <p>第二段继续补充足够多的正文字符数，确保超过最小可读正文长度阈值并完整输出 Markdown 文本与图片链接。</p>
          </div>
        </body></html>
        """
        let wxExtracted = ArticleRefetchEngine.extractMarkdownFromHTML(wechatHTML, baseURL: URL(string: "https://mp.weixin.qq.com/s/abc"))
        XCTAssertNotNil(wxExtracted)
        XCTAssertEqual(wxExtracted?.title, "微信公众号深度技术长文标题")
        XCTAssertTrue(wxExtracted?.markdown.contains("https://mmbiz.qpic.cn/mmbiz_png/demo123/640?wx_fmt=png") == true)

        // Anti-bot / CAPTCHA interstitials must be strictly rejected
        let turnstileHTML = """
        <html><head><title>Just a moment...</title></head>
        <body><div class="cf-turnstile"></div><p>Verify you are human to continue.</p></body></html>
        """
        XCTAssertNil(ArticleRefetchEngine.extractMarkdownFromHTML(turnstileHTML, baseURL: baseURL))

        let wxBlockHTML = """
        <html><body><div>当前环境异常，完成验证后即可继续访问。</div></body></html>
        """
        XCTAssertNil(ArticleRefetchEngine.extractMarkdownFromHTML(wxBlockHTML, baseURL: URL(string: "https://mp.weixin.qq.com/s/blocked")))
    }

    func testRssPendingRefetchStageAHttpStageBBrowserFallbackAndExhaustedCap() throws {
        let cfg = makeTestConfig()
        let postedPayloads = TestBox<[JSONValue]>([])

        let richArticleHTML = """
        <html><body><article>
          <h2>Full Origin Article via Stage A HTTP</h2>
          <p>This full article body was fetched directly over macOS URLSession through the user's residential network, replacing the short RSS summary cleanly and refreshing pipeline_raw so cloud bo-distiller re-cleans and indexes the full content.</p>
          <p>Additional technical details covering ETag conditional requests, OPML batch import, and cross-source URL deduplication.</p>
        </article></body></html>
        """

        let http = MockHTTPTransport { spec in
            let urlStr = spec.url.absoluteString
            if urlStr.contains("/api/ingest/state") {
                XCTAssertTrue(urlStr.contains("source_type=rss"))
                let stateResp: JSONValue = .object([
                    "status": .string("ok"),
                    "recent_ids": .array([]),
                    "pending_refetch_articles": .array([
                        .object([
                            "id": .string("rss_a1"),
                            "title": .string("Stage A HTTP Article"),
                            "content": .string("Short teaser..."),
                            "url": .string("https://simonwillison.net/2026/Nov/15/full-post/"),
                            "source": .object(["type": .string("rss"), "name": .string("Simon Willison"), "identifier": .string("https://simonwillison.net/atom/everything/")]),
                            "fetched_date": .string("2026-11-15T05:00:00Z"),
                            "metadata": .object([
                                "refetch_status": .string("pending_edge"),
                                "refetch_attempts": .int(0),
                                "fetch_mode": .string("auto"),
                                "pipeline_raw": .object(["content": .string("Short teaser..."), "title": .string("Stage A HTTP Article")]),
                            ]),
                        ]),
                        .object([
                            "id": .string("rss_a2"),
                            "title": .string("Stage B Browser Fallback Article"),
                            "content": .string("Read more..."),
                            "url": .string("https://csr-blog.example.org/post/2"),
                            "source": .object(["type": .string("rss"), "name": .string("CSR Tech Blog"), "identifier": .string("https://csr-blog.example.org/rss.xml")]),
                            "fetched_date": .string("2026-11-15T05:00:00Z"),
                            "metadata": .object([
                                "refetch_status": .string("pending_edge"),
                                "refetch_attempts": .int(1),
                                "fetch_mode": .string("auto"),
                                "pipeline_raw": .object(["content": .string("Read more..."), "title": .string("Stage B Browser Fallback Article")]),
                            ]),
                        ]),
                        .object([
                            "id": .string("rss_a3"),
                            "title": .string("Gated Interstitial Article"),
                            "content": .string("Summary kept safely."),
                            "url": .string("https://gated.example.net/post/3"),
                            "source": .object(["type": .string("rss"), "name": .string("Gated Feed"), "identifier": .string("https://gated.example.net/feed.xml")]),
                            "fetched_date": .string("2026-11-15T05:00:00Z"),
                            "metadata": .object([
                                "refetch_status": .string("pending_edge"),
                                "refetch_attempts": .int(2),
                                "fetch_mode": .string("auto"),
                                "pipeline_raw": .object(["content": .string("Summary kept safely."), "title": .string("Gated Interstitial Article")]),
                            ]),
                        ]),
                    ]),
                ])
                return HTTPResponseData(statusCode: 200, data: try stateResp.toData())
            }
            if urlStr == "https://simonwillison.net/2026/Nov/15/full-post/" {
                return HTTPResponseData(statusCode: 200, headers: ["Content-Type": "text/html; charset=utf-8"], data: Data(richArticleHTML.utf8))
            }
            if urlStr == "https://csr-blog.example.org/post/2" {
                // Empty CSR shell -> Stage A yields nil, triggers Stage B browser fallback
                return HTTPResponseData(statusCode: 200, headers: ["Content-Type": "text/html"], data: Data("<html><body><div id='app'></div></body></html>".utf8))
            }
            if urlStr == "https://gated.example.net/post/3" {
                return HTTPResponseData(statusCode: 403, data: Data("Forbidden".utf8))
            }
            if spec.method == "POST" && urlStr.contains("/api/ingest/articles") {
                let body = try JSONValue.parse(data: spec.body ?? Data())
                postedPayloads.withLock { $0.append(body) }
                return HTTPResponseData(statusCode: 200, data: Data("{\"status\":\"ok\",\"saved\":1,\"duplicates\":0,\"save_failed\":0}".utf8))
            }
            return HTTPResponseData(statusCode: 200)
        }

        let browser = MockBrowserClient()
        browser.extractResultsByURL["https://csr-blog.example.org/post/2"] = BrowserArticleExtractResult(
            status: "ok",
            title: "Stage B Browser Fallback Article",
            markdown: "## Rendered via Ego Browser\n\nThis rich client-side rendered article body was extracted cleanly from the isolated bo-collector-refetch TaskSpace and exceeds all length checks.",
            finalURL: "https://csr-blog.example.org/post/2"
        )
        browser.extractResultsByURL["https://gated.example.net/post/3"] = BrowserArticleExtractResult(
            status: "interstitial_blocked",
            message: "Origin page gated by verification interstitial"
        )

        let logger = SafeLogger(logPath: cfg.stateDir.appendingPathComponent("logs/collector.log"), echo: false)
        let engine = SyncEngine(config: cfg, logger: logger, browser: browser, http: http)
        defer { engine.close() }

        let summary = try engine.harvestPendingRefetches()
        XCTAssertEqual(summary.checked, 3)
        XCTAssertEqual(summary.succeededHTTP, 1)
        XCTAssertEqual(summary.succeededBrowser, 1)
        XCTAssertEqual(summary.exhausted, 1)
        XCTAssertEqual(summary.stillPending, 0)
        XCTAssertEqual(engine.state.rssRefetch, summary)

        // Stage A succeeded without invoking browser for rss_a1; browser was only called for rss_a2 and rss_a3
        XCTAssertEqual(browser.extractedURLs, ["https://csr-blog.example.org/post/2", "https://gated.example.net/post/3"])

        let posts = postedPayloads.value
        XCTAssertEqual(posts.count, 3)

        // 1. rss_a1: edge_http upgrade with refreshed pipeline_raw and force_clean=true
        let post1Art = posts[0]["articles"]?.arrayValue?.first
        XCTAssertEqual(posts[0]["source_name"]?.stringValue, "Simon Willison")
        XCTAssertEqual(posts[0]["clean"]?.boolValue, true)
        XCTAssertEqual(posts[0]["force_clean"]?.boolValue, true)
        XCTAssertEqual(post1Art?["metadata"]?["refetch_status"]?.stringValue, "succeeded_edge")
        XCTAssertEqual(post1Art?["metadata"]?["refetch_channel"]?.stringValue, "edge_http")
        XCTAssertEqual(post1Art?["metadata"]?["has_full_content"]?.boolValue, true)
        XCTAssertEqual(post1Art?["metadata"]?["pipeline_raw"]?["content"]?.stringValue, post1Art?["content"]?.stringValue)

        // 2. rss_a2: edge_browser upgrade
        let post2Art = posts[1]["articles"]?.arrayValue?.first
        XCTAssertEqual(posts[1]["force_clean"]?.boolValue, true)
        XCTAssertEqual(post2Art?["metadata"]?["refetch_channel"]?.stringValue, "edge_browser")
        XCTAssertTrue((post2Art?["content"]?.stringValue ?? "").contains("Rendered via Ego Browser"))

        // 3. rss_a3: 3rd failed attempt -> exhausted, summary preserved, clean=false
        let post3Art = posts[2]["articles"]?.arrayValue?.first
        XCTAssertEqual(posts[2]["clean"]?.boolValue, false)
        XCTAssertEqual(posts[2]["force_clean"]?.boolValue, false)
        XCTAssertEqual(post3Art?["content"]?.stringValue, "Summary kept safely.")
        XCTAssertEqual(post3Art?["metadata"]?["refetch_attempts"]?.intValue, 3)
        XCTAssertEqual(post3Art?["metadata"]?["refetch_status"]?.stringValue, "exhausted")
    }
}
