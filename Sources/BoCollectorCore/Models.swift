import Foundation

public enum SourceNames {
    public static let mapping: [String: String] = [
        "x_bookmarks": "X 书签",
        "douyin": "抖音收藏",
        "x_monitor": "X 用户监控",
    ]

    public static func displayName(for platform: String) -> String {
        mapping[platform] ?? platform
    }
}

public func stripPrefixID(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("xm_") { s = String(s.dropFirst(3)) }
    else if s.hasPrefix("x_") { s = String(s.dropFirst(2)) }
    else if s.hasPrefix("dy_") { s = String(s.dropFirst(3)) }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Cloud Article & Ingest Payloads

public struct ArticleSourceInfo: Codable, Equatable, Sendable {
    public var type: String
    public var name: String
    public var identifier: String

    public init(type: String, name: String, identifier: String) {
        self.type = type
        self.name = name
        self.identifier = identifier
    }
}

public struct ArticlePayload: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var content: String
    public var url: String?
    public var source: ArticleSourceInfo
    public var author: String?
    public var publishedDate: String?
    public var fetchedDate: String
    public var metadata: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case id, title, content, url, source, author, metadata
        case publishedDate = "published_date"
        case fetchedDate = "fetched_date"
    }

    public init(
        id: String,
        title: String,
        content: String,
        url: String?,
        source: ArticleSourceInfo,
        author: String? = nil,
        publishedDate: String? = nil,
        fetchedDate: String = DateFormatting.isoTimestamp(),
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.url = url
        self.source = source
        self.author = author
        self.publishedDate = publishedDate
        self.fetchedDate = fetchedDate
        self.metadata = metadata
    }
}

// MARK: - X Monitor Cloud Models

public struct XMonitorUser: Codable, Equatable, Sendable, Identifiable {
    public var id: String { handle }
    public var handle: String
    public var displayName: String = ""
    public var avatarURL: String = ""
    public var note: String = ""
    public var tags: [String] = []
    public var enabled: Bool = true
    public var includeRetweets: Bool = false
    public var includeReplies: Bool = false
    public var minTextLength: Int? = nil
    public var lastTweetId: String = ""
    public var recentIds: [String] = []
    public var lastCheckedAt: String? = nil
    public var lastPostAt: String? = nil
    public var totalCaptured: Int = 0
    public var lastError: String? = nil

    enum CodingKeys: String, CodingKey {
        case handle, note, tags, enabled
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case includeRetweets = "include_retweets"
        case includeReplies = "include_replies"
        case minTextLength = "min_text_length"
        case lastTweetId = "last_tweet_id"
        case recentIds = "recent_ids"
        case lastCheckedAt = "last_checked_at"
        case lastPostAt = "last_post_at"
        case totalCaptured = "total_captured"
        case lastError = "last_error"
    }

    public init(handle: String, enabled: Bool = true) {
        self.handle = handle
        self.enabled = enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        handle = try c.decode(String.self, forKey: .handle)
        displayName = (try? c.decodeIfPresent(String.self, forKey: .displayName)) ?? ""
        avatarURL = (try? c.decodeIfPresent(String.self, forKey: .avatarURL)) ?? ""
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? ""
        tags = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? []
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        includeRetweets = (try? c.decodeIfPresent(Bool.self, forKey: .includeRetweets)) ?? false
        includeReplies = (try? c.decodeIfPresent(Bool.self, forKey: .includeReplies)) ?? false
        minTextLength = try? c.decodeIfPresent(Int.self, forKey: .minTextLength)
        lastTweetId = (try? c.decodeIfPresent(String.self, forKey: .lastTweetId)) ?? ""
        recentIds = (try? c.decodeIfPresent([String].self, forKey: .recentIds)) ?? []
        lastCheckedAt = try? c.decodeIfPresent(String.self, forKey: .lastCheckedAt)
        lastPostAt = try? c.decodeIfPresent(String.self, forKey: .lastPostAt)
        totalCaptured = (try? c.decodeIfPresent(Int.self, forKey: .totalCaptured)) ?? 0
        lastError = try? c.decodeIfPresent(String.self, forKey: .lastError)
    }
}

public struct XMonitorRemoteConfig: Codable, Equatable, Sendable {
    public var listURL: String = ""
    public var defaultMinTextLength: Int = 20
    public var maxItemsPerUser: Int = 20
    public var autoTranslateZh: Bool = true
    public var extractInfographics: Bool = true

    enum CodingKeys: String, CodingKey {
        case listURL = "list_url"
        case defaultMinTextLength = "default_min_text_length"
        case maxItemsPerUser = "max_items_per_user"
        case autoTranslateZh = "auto_translate_zh"
        case extractInfographics = "extract_infographics"
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        listURL = (try? c.decodeIfPresent(String.self, forKey: .listURL)) ?? ""
        defaultMinTextLength = (try? c.decodeIfPresent(Int.self, forKey: .defaultMinTextLength)) ?? 20
        maxItemsPerUser = (try? c.decodeIfPresent(Int.self, forKey: .maxItemsPerUser)) ?? 20
        autoTranslateZh = (try? c.decodeIfPresent(Bool.self, forKey: .autoTranslateZh)) ?? true
        extractInfographics = (try? c.decodeIfPresent(Bool.self, forKey: .extractInfographics)) ?? true
    }
}

public struct XMonitorUserStateUpdate: Codable, Equatable, Sendable {
    public var lastTweetId: String?
    public var recentIds: [String]?
    public var lastCheckedAt: String?
    public var lastPostAt: String?
    public var capturedDelta: Int
    public var lastError: String
    public var displayName: String?
    public var avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case lastTweetId = "last_tweet_id"
        case recentIds = "recent_ids"
        case lastCheckedAt = "last_checked_at"
        case lastPostAt = "last_post_at"
        case capturedDelta = "captured_delta"
        case lastError = "last_error"
        case displayName = "display_name"
        case avatarURL = "avatar_url"
    }

    public init(
        lastTweetId: String? = nil,
        recentIds: [String]? = nil,
        lastCheckedAt: String? = nil,
        lastPostAt: String? = nil,
        capturedDelta: Int = 0,
        lastError: String = "",
        displayName: String? = nil,
        avatarURL: String? = nil
    ) {
        self.lastTweetId = lastTweetId
        self.recentIds = recentIds
        self.lastCheckedAt = lastCheckedAt
        self.lastPostAt = lastPostAt
        self.capturedDelta = capturedDelta
        self.lastError = lastError
        self.displayName = displayName
        self.avatarURL = avatarURL
    }
}

// MARK: - Persistent Local State (100% compatible with ~/.local/state/bo-collector/state.json)

public struct AsrStateSummary: Codable, Equatable, Sendable {
    public var checked: Int = 0
    public var completed: Int = 0
    public var stillPending: Int = 0

    enum CodingKeys: String, CodingKey {
        case checked, completed
        case stillPending = "still_pending"
    }

    public init(checked: Int = 0, completed: Int = 0, stillPending: Int = 0) {
        self.checked = checked
        self.completed = completed
        self.stillPending = stillPending
    }
}

public struct HealerState: Codable, Equatable, Sendable {
    public var authPaused: Bool?
    public var authPlatform: String?
    public var authReason: String?
    public var lastAuthNotifyAt: Double?
    public var consecutiveFailures: Int = 0
    public var lastCodeError: String?
    public var lastErrorAt: String?
    public var lastHealAt: Double?
    public var lastHealResult: String?

    enum CodingKeys: String, CodingKey {
        case authPaused = "auth_paused"
        case authPlatform = "auth_platform"
        case authReason = "auth_reason"
        case lastAuthNotifyAt = "last_auth_notify_at"
        case consecutiveFailures = "consecutive_failures"
        case lastCodeError = "last_code_error"
        case lastErrorAt = "last_error_at"
        case lastHealAt = "last_heal_at"
        case lastHealResult = "last_heal_result"
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        authPaused = try? c.decodeIfPresent(Bool.self, forKey: .authPaused)
        authPlatform = try? c.decodeIfPresent(String.self, forKey: .authPlatform)
        authReason = try? c.decodeIfPresent(String.self, forKey: .authReason)
        lastAuthNotifyAt = try? c.decodeIfPresent(Double.self, forKey: .lastAuthNotifyAt)
        consecutiveFailures = (try? c.decodeIfPresent(Int.self, forKey: .consecutiveFailures)) ?? 0
        lastCodeError = try? c.decodeIfPresent(String.self, forKey: .lastCodeError)
        lastErrorAt = try? c.decodeIfPresent(String.self, forKey: .lastErrorAt)
        lastHealAt = try? c.decodeIfPresent(Double.self, forKey: .lastHealAt)
        lastHealResult = try? c.decodeIfPresent(String.self, forKey: .lastHealResult)
    }
}

public struct CaptureSnapshot: Codable, Equatable, Sendable {
    public var payloads: [JSONValue]
    public var domItems: [[String: JSONValue]]
    public var spaceId: Int?

    enum CodingKeys: String, CodingKey {
        case payloads
        case domItems = "dom_items"
        case spaceId = "space_id"
    }

    public init(payloads: [JSONValue], domItems: [[String: JSONValue]], spaceId: Int?) {
        self.payloads = payloads
        self.domItems = domItems
        self.spaceId = spaceId
    }
}

public struct SourceState: Codable, Equatable, Sendable {
    public var name: String
    public var known: [String] = []
    public var saved: Int = 0
    public var status: String = "ready"
    public var outbox: [ArticlePayload]? = nil
    public var sinceRest: Int? = nil
    public var nextAt: Double? = nil
    public var failures: Int? = nil
    public var emptyRounds: Int? = nil
    public var scanSignature: String? = nil
    public var endSeen: Bool? = nil
    public var capture: CaptureSnapshot? = nil

    enum CodingKeys: String, CodingKey {
        case name, known, saved, status, outbox, failures, capture
        case sinceRest = "since_rest"
        case nextAt = "next_at"
        case emptyRounds = "empty_rounds"
        case scanSignature = "scan_signature"
        case endSeen = "end_seen"
    }

    public init(name: String, known: [String] = [], saved: Int = 0, status: String = "ready") {
        self.name = name
        self.known = known
        self.saved = saved
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        known = (try? c.decodeIfPresent([String].self, forKey: .known)) ?? []
        saved = (try? c.decodeIfPresent(Int.self, forKey: .saved)) ?? 0
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "ready"
        outbox = try? c.decodeIfPresent([ArticlePayload].self, forKey: .outbox)
        sinceRest = try? c.decodeIfPresent(Int.self, forKey: .sinceRest)
        nextAt = try? c.decodeIfPresent(Double.self, forKey: .nextAt)
        failures = try? c.decodeIfPresent(Int.self, forKey: .failures)
        emptyRounds = try? c.decodeIfPresent(Int.self, forKey: .emptyRounds)
        scanSignature = try? c.decodeIfPresent(String.self, forKey: .scanSignature)
        endSeen = try? c.decodeIfPresent(Bool.self, forKey: .endSeen)
        capture = try? c.decodeIfPresent(CaptureSnapshot.self, forKey: .capture)
    }
}

public struct CollectorState: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var target: String? = nil
    public var status: String = "idle"
    public var updatedAt: String? = nil
    public var lastTransientError: String? = nil
    public var lastAsrRetriggerAt: Double? = nil
    public var harvestAt: Double? = nil
    public var browserSpaceId: Int? = nil
    public var asr: AsrStateSummary? = nil
    public var healer: HealerState? = nil
    public var sources: [String: SourceState] = [:]

    enum CodingKeys: String, CodingKey {
        case version, target, status, asr, healer, sources
        case updatedAt = "updated_at"
        case lastTransientError = "last_transient_error"
        case lastAsrRetriggerAt = "last_asr_retrigger_at"
        case harvestAt = "harvest_at"
        case browserSpaceId = "browser_space_id"
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        target = try? c.decodeIfPresent(String.self, forKey: .target)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "idle"
        updatedAt = try? c.decodeIfPresent(String.self, forKey: .updatedAt)
        lastTransientError = try? c.decodeIfPresent(String.self, forKey: .lastTransientError)
        lastAsrRetriggerAt = try? c.decodeIfPresent(Double.self, forKey: .lastAsrRetriggerAt)
        harvestAt = try? c.decodeIfPresent(Double.self, forKey: .harvestAt)
        browserSpaceId = try? c.decodeIfPresent(Int.self, forKey: .browserSpaceId)
        asr = try? c.decodeIfPresent(AsrStateSummary.self, forKey: .asr)
        healer = try? c.decodeIfPresent(HealerState.self, forKey: .healer)
        sources = (try? c.decodeIfPresent([String: SourceState].self, forKey: .sources)) ?? [:]
    }
}

// MARK: - Diagnostics

public struct DoctorCheckItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String { check }
    public var check: String
    public var ok: Bool
    public var detail: String
    public var critical: Bool

    public init(check: String, ok: Bool, detail: String, critical: Bool = true) {
        self.check = check
        self.ok = ok
        self.detail = detail
        self.critical = critical
    }
}
