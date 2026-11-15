import Foundation
import Darwin

public enum NetworkProxyMode: String, Codable, CaseIterable, Sendable {
    case system = "system"
    case custom = "custom"
    case direct = "direct"

    public var displayName: String {
        switch self {
        case .system: return "跟随 macOS 系统代理（推荐，自动兼容 Surge/Clash）"
        case .custom: return "指定 HTTP/HTTPS 代理"
        case .direct: return "强制直连（忽略系统代理）"
        }
    }
}

public enum AsrProviderMode: String, Codable, CaseIterable, Sendable {
    case instaboxKoofr = "instabox_koofr"
    case openaiAPI = "openai_api"

    public var displayName: String {
        switch self {
        case .instaboxKoofr: return "Instabox + Koofr WebDAV（流式传网盘后即可关机）"
        case .openaiAPI: return "OpenAI 兼容语音 API（本地抽音轨直传如 SiliconFlow SenseVoice）"
        }
    }
}

/// Complete standalone configuration replacing both legacy config.env and local bo-distiller edge settings.
public struct CollectorConfig: Codable, Equatable, Sendable {
    // 1. Cloud Ingest & Network Proxy
    public var remotePushURL: String = ""
    public var remoteIngestToken: String = ""
    public var proxyMode: NetworkProxyMode = .system
    public var customProxyHost: String = "127.0.0.1"
    public var customProxyPort: Int = 6152

    // 2. Edge Collection Sources
    // 2a. X Bookmarks
    public var xBookmarksEnabled: Bool = true
    public var syncMaxItemsX: Int = 30
    public var xExtractInfographics: Bool = true

    // 2b. Douyin Favorites
    public var douyinEnabled: Bool = true
    public var syncMaxItemsDouyin: Int = 20
    public var douyinCollectsId: String = ""
    public var maxVideoMB: Int = 150
    public var maxDurationMin: Int = 25

    // 2c. X User Monitor (local ego-lite capture -> push to cloud bo-distiller)
    public var xMonitorEnabled: Bool = false
    public var xMonitorListURL: String = ""
    public var xMonitorLocalHandles: String = ""
    public var xMonitorDefaultMinLength: Int = 20
    public var xMonitorMaxItemsPerUser: Int = 20
    public var xMonitorExtractInfographics: Bool = true

    // 2d. RSS Pending Full-Text Edge Refetch (cloud RSS summary -> Mac residential IP / ego-browser fallback)
    public var rssRefetchEnabled: Bool = true
    public var rssRefetchMaxPerRun: Int = 15
    public var rssRefetchUseBrowserFallback: Bool = true

    // 3. ASR (Subtitle-less Douyin Video Transcription)
    public var asrEnabled: Bool = true
    public var asrProvider: AsrProviderMode = .instaboxKoofr
    public var koofrWebdavURL: String = "https://app.koofr.net/dav/Koofr"
    public var koofrEmail: String = ""
    public var koofrAppPassword: String = ""
    public var koofrSubdir: String = "bo-distiller"
    public var instaboxAsrBox: String = ""
    public var instaboxAsrService: String = "bo-distiller-asr.service"
    public var instaboxBin: String = ""
    public var asrApiBase: String = "https://api.siliconflow.cn/v1"
    public var asrApiKey: String = ""
    public var asrModel: String = "FunAudioLLM/SenseVoiceSmall"
    public var asrTimeout: Int = 300

    // 4. Lightweight Vision Model (VLM for Douyin Image Notes & X Infographics)
    public var vlmEnabled: Bool = true
    public var vlmApiBase: String = ""
    public var vlmApiKey: String = ""
    public var vlmModel: String = ""
    public var vlmTimeout: Int = 120

    // 5. Browser, L2 Tampermonkey Local Bridge, LaunchAgent & Self-Healing
    public var egoSpaceName: String = "bo-collector"
    public var egoBin: String = ""
    public var bridgeEnabled: Bool = false
    public var bridgeHost: String = "127.0.0.1"
    public var bridgePort: Int = 18765
    public var bridgeToken: String = ""
    public var syncIntervalSeconds: Int = 1800
    public var orcaBin: String = "orca"
    public var orcaHealAutomationId: String = ""
    public var healCooldownSeconds: Int = 21600

    // Runtime resolved paths (not encoded in JSON)
    public var configPath: URL = CollectorPaths.defaultConfigJSONPath()
    public var stateDir: URL = CollectorPaths.defaultStateDir()
    public var cacheDir: URL = CollectorPaths.defaultCacheDir()

    enum CodingKeys: String, CodingKey {
        case remotePushURL = "remote_push_url"
        case remoteIngestToken = "remote_ingest_token"
        case proxyMode = "proxy_mode"
        case customProxyHost = "custom_proxy_host"
        case customProxyPort = "custom_proxy_port"
        case xBookmarksEnabled = "x_bookmarks_enabled"
        case syncMaxItemsX = "sync_max_items_x"
        case xExtractInfographics = "x_extract_infographics"
        case douyinEnabled = "douyin_enabled"
        case syncMaxItemsDouyin = "sync_max_items_douyin"
        case douyinCollectsId = "douyin_collects_id"
        case maxVideoMB = "max_video_mb"
        case maxDurationMin = "max_duration_min"
        case xMonitorEnabled = "x_monitor_enabled"
        case xMonitorListURL = "x_monitor_list_url"
        case xMonitorLocalHandles = "x_monitor_local_handles"
        case xMonitorDefaultMinLength = "x_monitor_default_min_length"
        case xMonitorMaxItemsPerUser = "x_monitor_max_items_per_user"
        case xMonitorExtractInfographics = "x_monitor_extract_infographics"
        case rssRefetchEnabled = "rss_refetch_enabled"
        case rssRefetchMaxPerRun = "rss_refetch_max_per_run"
        case rssRefetchUseBrowserFallback = "rss_refetch_use_browser_fallback"
        case asrEnabled = "asr_enabled"
        case asrProvider = "asr_provider"
        case koofrWebdavURL = "koofr_webdav_url"
        case koofrEmail = "koofr_email"
        case koofrAppPassword = "koofr_app_password"
        case koofrSubdir = "koofr_subdir"
        case instaboxAsrBox = "instabox_asr_box"
        case instaboxAsrService = "instabox_asr_service"
        case instaboxBin = "instabox_bin"
        case asrApiBase = "asr_api_base"
        case asrApiKey = "asr_api_key"
        case asrModel = "asr_model"
        case asrTimeout = "asr_timeout"
        case vlmEnabled = "vlm_enabled"
        case vlmApiBase = "vlm_api_base"
        case vlmApiKey = "vlm_api_key"
        case vlmModel = "vlm_model"
        case vlmTimeout = "vlm_timeout"
        case egoSpaceName = "ego_space_name"
        case egoBin = "ego_bin"
        case bridgeEnabled = "bridge_enabled"
        case bridgeHost = "bridge_host"
        case bridgePort = "bridge_port"
        case bridgeToken = "bridge_token"
        case syncIntervalSeconds = "sync_interval_seconds"
        case orcaBin = "orca_bin"
        case orcaHealAutomationId = "orca_heal_automation_id"
        case healCooldownSeconds = "heal_cooldown_seconds"
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let def = CollectorConfig()
        remotePushURL = try c.decodeIfPresent(String.self, forKey: .remotePushURL) ?? def.remotePushURL
        remoteIngestToken = try c.decodeIfPresent(String.self, forKey: .remoteIngestToken) ?? def.remoteIngestToken
        proxyMode = try c.decodeIfPresent(NetworkProxyMode.self, forKey: .proxyMode) ?? def.proxyMode
        customProxyHost = try c.decodeIfPresent(String.self, forKey: .customProxyHost) ?? def.customProxyHost
        customProxyPort = try c.decodeIfPresent(Int.self, forKey: .customProxyPort) ?? def.customProxyPort

        xBookmarksEnabled = try c.decodeIfPresent(Bool.self, forKey: .xBookmarksEnabled) ?? def.xBookmarksEnabled
        syncMaxItemsX = max(1, try c.decodeIfPresent(Int.self, forKey: .syncMaxItemsX) ?? def.syncMaxItemsX)
        xExtractInfographics = try c.decodeIfPresent(Bool.self, forKey: .xExtractInfographics) ?? def.xExtractInfographics

        douyinEnabled = try c.decodeIfPresent(Bool.self, forKey: .douyinEnabled) ?? def.douyinEnabled
        syncMaxItemsDouyin = max(1, try c.decodeIfPresent(Int.self, forKey: .syncMaxItemsDouyin) ?? def.syncMaxItemsDouyin)
        douyinCollectsId = try c.decodeIfPresent(String.self, forKey: .douyinCollectsId) ?? def.douyinCollectsId
        maxVideoMB = max(5, try c.decodeIfPresent(Int.self, forKey: .maxVideoMB) ?? def.maxVideoMB)
        maxDurationMin = max(1, try c.decodeIfPresent(Int.self, forKey: .maxDurationMin) ?? def.maxDurationMin)

        xMonitorEnabled = try c.decodeIfPresent(Bool.self, forKey: .xMonitorEnabled) ?? def.xMonitorEnabled
        xMonitorListURL = try c.decodeIfPresent(String.self, forKey: .xMonitorListURL) ?? def.xMonitorListURL
        xMonitorLocalHandles = try c.decodeIfPresent(String.self, forKey: .xMonitorLocalHandles) ?? def.xMonitorLocalHandles
        xMonitorDefaultMinLength = max(0, try c.decodeIfPresent(Int.self, forKey: .xMonitorDefaultMinLength) ?? def.xMonitorDefaultMinLength)
        xMonitorMaxItemsPerUser = max(1, try c.decodeIfPresent(Int.self, forKey: .xMonitorMaxItemsPerUser) ?? def.xMonitorMaxItemsPerUser)
        xMonitorExtractInfographics = try c.decodeIfPresent(Bool.self, forKey: .xMonitorExtractInfographics) ?? def.xMonitorExtractInfographics

        rssRefetchEnabled = try c.decodeIfPresent(Bool.self, forKey: .rssRefetchEnabled) ?? def.rssRefetchEnabled
        rssRefetchMaxPerRun = max(1, min(100, try c.decodeIfPresent(Int.self, forKey: .rssRefetchMaxPerRun) ?? def.rssRefetchMaxPerRun))
        rssRefetchUseBrowserFallback = try c.decodeIfPresent(Bool.self, forKey: .rssRefetchUseBrowserFallback) ?? def.rssRefetchUseBrowserFallback

        asrEnabled = try c.decodeIfPresent(Bool.self, forKey: .asrEnabled) ?? def.asrEnabled
        asrProvider = try c.decodeIfPresent(AsrProviderMode.self, forKey: .asrProvider) ?? def.asrProvider
        koofrWebdavURL = try c.decodeIfPresent(String.self, forKey: .koofrWebdavURL) ?? def.koofrWebdavURL
        koofrEmail = try c.decodeIfPresent(String.self, forKey: .koofrEmail) ?? def.koofrEmail
        koofrAppPassword = try c.decodeIfPresent(String.self, forKey: .koofrAppPassword) ?? def.koofrAppPassword
        koofrSubdir = try c.decodeIfPresent(String.self, forKey: .koofrSubdir) ?? def.koofrSubdir
        instaboxAsrBox = try c.decodeIfPresent(String.self, forKey: .instaboxAsrBox) ?? def.instaboxAsrBox
        instaboxAsrService = try c.decodeIfPresent(String.self, forKey: .instaboxAsrService) ?? def.instaboxAsrService
        instaboxBin = try c.decodeIfPresent(String.self, forKey: .instaboxBin) ?? def.instaboxBin
        asrApiBase = try c.decodeIfPresent(String.self, forKey: .asrApiBase) ?? def.asrApiBase
        asrApiKey = try c.decodeIfPresent(String.self, forKey: .asrApiKey) ?? def.asrApiKey
        asrModel = try c.decodeIfPresent(String.self, forKey: .asrModel) ?? def.asrModel
        asrTimeout = max(15, try c.decodeIfPresent(Int.self, forKey: .asrTimeout) ?? def.asrTimeout)

        vlmEnabled = try c.decodeIfPresent(Bool.self, forKey: .vlmEnabled) ?? def.vlmEnabled
        vlmApiBase = try c.decodeIfPresent(String.self, forKey: .vlmApiBase) ?? def.vlmApiBase
        vlmApiKey = try c.decodeIfPresent(String.self, forKey: .vlmApiKey) ?? def.vlmApiKey
        vlmModel = try c.decodeIfPresent(String.self, forKey: .vlmModel) ?? def.vlmModel
        vlmTimeout = max(15, try c.decodeIfPresent(Int.self, forKey: .vlmTimeout) ?? def.vlmTimeout)

        egoSpaceName = try c.decodeIfPresent(String.self, forKey: .egoSpaceName) ?? def.egoSpaceName
        egoBin = try c.decodeIfPresent(String.self, forKey: .egoBin) ?? def.egoBin
        bridgeEnabled = try c.decodeIfPresent(Bool.self, forKey: .bridgeEnabled) ?? def.bridgeEnabled
        bridgeHost = try c.decodeIfPresent(String.self, forKey: .bridgeHost) ?? def.bridgeHost
        bridgePort = max(1024, min(65535, try c.decodeIfPresent(Int.self, forKey: .bridgePort) ?? def.bridgePort))
        bridgeToken = try c.decodeIfPresent(String.self, forKey: .bridgeToken) ?? def.bridgeToken
        syncIntervalSeconds = max(60, try c.decodeIfPresent(Int.self, forKey: .syncIntervalSeconds) ?? def.syncIntervalSeconds)
        orcaBin = try c.decodeIfPresent(String.self, forKey: .orcaBin) ?? def.orcaBin
        orcaHealAutomationId = try c.decodeIfPresent(String.self, forKey: .orcaHealAutomationId) ?? def.orcaHealAutomationId
        healCooldownSeconds = max(300, try c.decodeIfPresent(Int.self, forKey: .healCooldownSeconds) ?? def.healCooldownSeconds)
    }

    public var hasKoofrWebdav: Bool {
        !koofrWebdavURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !koofrEmail.trimmingCharacters(in: .whitespaces).isEmpty
            && !koofrAppPassword.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var hasOpenAIAsr: Bool {
        !asrApiBase.trimmingCharacters(in: .whitespaces).isEmpty
            && !asrApiKey.trimmingCharacters(in: .whitespaces).isEmpty
            && !asrModel.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var hasVLM: Bool {
        vlmEnabled
            && !vlmApiBase.trimmingCharacters(in: .whitespaces).isEmpty
            && !vlmApiKey.trimmingCharacters(in: .whitespaces).isEmpty
            && !vlmModel.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var enabledDefaultPlatforms: [String] {
        var list: [String] = []
        if xBookmarksEnabled { list.append("x_bookmarks") }
        if douyinEnabled { list.append("douyin") }
        if xMonitorEnabled { list.append("x_monitor") }
        return list
    }

    public mutating func normalize() {
        remotePushURL = remotePushURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingTrailingSlashes()
        remoteIngestToken = remoteIngestToken.trimmingCharacters(in: .whitespacesAndNewlines)
        koofrWebdavURL = koofrWebdavURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingTrailingSlashes()
        koofrEmail = koofrEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        koofrAppPassword = koofrAppPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let sub = koofrSubdir.trimmingCharacters(in: CharacterSet(charactersIn: " /\t\n\r"))
        koofrSubdir = sub.isEmpty ? "bo-distiller" : sub
        instaboxAsrBox = instaboxAsrBox.trimmingCharacters(in: .whitespacesAndNewlines)
        instaboxAsrService = instaboxAsrService.trimmingCharacters(in: .whitespacesAndNewlines)
        if instaboxAsrService.isEmpty { instaboxAsrService = "bo-distiller-asr.service" }
        asrApiBase = asrApiBase.trimmingCharacters(in: .whitespacesAndNewlines).trimmingTrailingSlashes()
        asrApiKey = asrApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        asrModel = asrModel.trimmingCharacters(in: .whitespacesAndNewlines)
        vlmApiBase = vlmApiBase.trimmingCharacters(in: .whitespacesAndNewlines).trimmingTrailingSlashes()
        vlmApiKey = vlmApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        vlmModel = vlmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        egoSpaceName = egoSpaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if egoSpaceName.isEmpty { egoSpaceName = "bo-collector" }
        orcaBin = orcaBin.trimmingCharacters(in: .whitespacesAndNewlines)
        if orcaBin.isEmpty { orcaBin = "orca" }
        orcaHealAutomationId = orcaHealAutomationId.trimmingCharacters(in: .whitespacesAndNewlines)
        syncMaxItemsX = max(1, syncMaxItemsX)
        syncMaxItemsDouyin = max(1, syncMaxItemsDouyin)
        xMonitorMaxItemsPerUser = max(1, xMonitorMaxItemsPerUser)
        rssRefetchMaxPerRun = max(1, min(100, rssRefetchMaxPerRun))
        maxVideoMB = max(5, maxVideoMB)
        maxDurationMin = max(1, maxDurationMin)
        syncIntervalSeconds = max(60, syncIntervalSeconds)
        healCooldownSeconds = max(300, healCooldownSeconds)
    }

    public func save() throws {
        var copy = self
        copy.normalize()
        try SecureFileStore.atomicWriteCodable(copy, to: copy.configPath)
    }

    /// Load config.json, seamlessly auto-migrating legacy config.env if config.json does not exist yet.
    public static func load(
        configPath: URL? = nil,
        stateDir: URL? = nil,
        cacheDir: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CollectorConfig {
        let resolvedConfigPath = (configPath ?? CollectorPaths.defaultConfigJSONPath(env: environment)).standardizedFileURL
        let resolvedStateDir = (stateDir ?? CollectorPaths.defaultStateDir(env: environment)).standardizedFileURL
        let resolvedCacheDir = (cacheDir ?? CollectorPaths.defaultCacheDir(env: environment)).standardizedFileURL

        var cfg = CollectorConfig()
        let fm = FileManager.default

        if resolvedConfigPath.pathExtension.lowercased() == "env" && fm.fileExists(atPath: resolvedConfigPath.path) {
            if let text = try? String(contentsOf: resolvedConfigPath, encoding: .utf8) {
                cfg.applyEnvDictionary(EnvFileParser.parse(text))
            }
        } else if fm.fileExists(atPath: resolvedConfigPath.path),
                  let data = try? Data(contentsOf: resolvedConfigPath),
                  let decoded = try? JSONDecoder().decode(CollectorConfig.self, from: data) {
            cfg = decoded
        } else {
            // Auto-migrate from sibling config.env (or default config.env when using default configPath)
            let legacyEnvURL = resolvedConfigPath.deletingLastPathComponent().appendingPathComponent("config.env")
            let envCandidate: URL?
            if fm.fileExists(atPath: legacyEnvURL.path) {
                envCandidate = legacyEnvURL
            } else if configPath == nil && environment["BO_COLLECTOR_CONFIG"] == nil {
                let fallback = CollectorPaths.defaultLegacyEnvPath()
                envCandidate = fm.fileExists(atPath: fallback.path) ? fallback : nil
            } else {
                envCandidate = nil
            }
            if let envURL = envCandidate,
               let raw = try? String(contentsOf: envURL, encoding: .utf8) {
                cfg.applyEnvDictionary(EnvFileParser.parse(raw))
                cfg.configPath = resolvedConfigPath
                try? cfg.save()
            }
        }

        cfg.applyEnvOverrides(environment)
        cfg.configPath = resolvedConfigPath
        cfg.stateDir = resolvedStateDir
        cfg.cacheDir = resolvedCacheDir
        cfg.normalize()
        return cfg
    }

    public mutating func applyEnvDictionary(_ vars: [String: String]) {
        func pick(_ key: String) -> String? {
            guard let v = vars[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return v
        }
        if let v = pick("REMOTE_PUSH_URL") { remotePushURL = v }
        if let v = pick("REMOTE_INGEST_TOKEN") ?? pick("INGEST_TOKEN") { remoteIngestToken = v }
        if let v = pick("KOOFR_WEBDAV_URL") { koofrWebdavURL = v }
        if let v = pick("KOOFR_EMAIL") ?? pick("KOOFR_USER") { koofrEmail = v }
        if let v = pick("KOOFR_APP_PASSWORD") { koofrAppPassword = v }
        if let v = pick("KOOFR_SUBDIR") { koofrSubdir = v }
        if let v = pick("MAX_VIDEO_MB"), let n = Int(v) { maxVideoMB = max(5, n) }
        if let v = pick("INSTABOX_ASR_BOX") { instaboxAsrBox = v }
        if let v = pick("INSTABOX_ASR_SERVICE") { instaboxAsrService = v }
        if let v = pick("ASR_API_BASE") { asrApiBase = v }
        if let v = pick("ASR_API_KEY") { asrApiKey = v }
        if let v = pick("ASR_MODEL") { asrModel = v }
        if let v = pick("VLM_ENABLED") { vlmEnabled = EnvFileParser.asBool(v, default: true) }
        if let v = pick("VLM_API_BASE") { vlmApiBase = v }
        if let v = pick("VLM_API_KEY") { vlmApiKey = v }
        if let v = pick("VLM_MODEL") { vlmModel = v }
        if let v = pick("VLM_TIMEOUT"), let n = Int(v) { vlmTimeout = max(15, n) }
        if let v = pick("SYNC_MAX_ITEMS_X"), let n = Int(v) { syncMaxItemsX = max(1, n) }
        if let v = pick("SYNC_MAX_ITEMS_DOUYIN"), let n = Int(v) { syncMaxItemsDouyin = max(1, n) }
        if let v = pick("RSS_REFETCH_ENABLED") { rssRefetchEnabled = EnvFileParser.asBool(v, default: true) }
        if let v = pick("RSS_REFETCH_MAX_PER_RUN"), let n = Int(v) { rssRefetchMaxPerRun = max(1, min(100, n)) }
        if let v = pick("RSS_REFETCH_USE_BROWSER_FALLBACK") { rssRefetchUseBrowserFallback = EnvFileParser.asBool(v, default: true) }
        if let v = pick("EGO_SPACE_NAME") { egoSpaceName = v }
        if let v = pick("ORCA_BIN") { orcaBin = v }
        if let v = pick("ORCA_HEAL_AUTOMATION_ID") { orcaHealAutomationId = v }
        if let v = pick("HEAL_COOLDOWN_SECONDS"), let n = Int(v) { healCooldownSeconds = max(300, n) }
    }

    public mutating func applyEnvOverrides(_ env: [String: String]) {
        // Only apply explicit non-empty process environment overrides
        applyEnvDictionary(env)
    }

    /// Pure-Swift importer reading `.env`, `config.yaml`, `sources.yaml`, and Orca metadata from legacy `bo-distiller` without starting MySQL/Python.
    @discardableResult
    public mutating func importFromBoDistiller(directory: URL) throws -> [String] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            throw NSError(domain: "BoCollector", code: 404, userInfo: [NSLocalizedDescriptionKey: "未找到目录: \(directory.path)"])
        }

        var envVars: [String: String] = [:]
        let dotEnv = directory.appendingPathComponent(".env")
        if let rawEnv = try? String(contentsOf: dotEnv, encoding: .utf8) {
            envVars = EnvFileParser.parse(rawEnv)
            applyEnvDictionary(envVars)
        }

        // Lightweight line-based YAML key extraction for multimodal & provider fallback in config.yaml
        let configYaml = directory.appendingPathComponent("config.yaml")
        if let yamlText = try? String(contentsOf: configYaml, encoding: .utf8) {
            let flat = SimpleYAMLScanner.scanKeyValues(yamlText, env: envVars)
            if let v = flat["multimodal.remote_push_url"], !v.isEmpty { remotePushURL = v }
            if let v = flat["multimodal.remote_ingest_token"], !v.isEmpty { remoteIngestToken = v }
            else if remoteIngestToken.isEmpty, let v = flat["multimodal.ingest_token"], !v.isEmpty { remoteIngestToken = v }
            if let v = flat["multimodal.koofr_webdav_url"], !v.isEmpty { koofrWebdavURL = v }
            if let v = flat["multimodal.koofr_email"], !v.isEmpty { koofrEmail = v }
            if let v = flat["multimodal.koofr_app_password"], !v.isEmpty { koofrAppPassword = v }
            if let v = flat["multimodal.instabox_asr_box"], !v.isEmpty { instaboxAsrBox = v }
            if let v = flat["multimodal.asr_enabled"] { asrEnabled = EnvFileParser.asBool(v, default: asrEnabled) }
            if let v = flat["multimodal.asr_provider"], let mode = AsrProviderMode(rawValue: v) { asrProvider = mode }
            if let v = flat["multimodal.asr_api_base"], !v.isEmpty { asrApiBase = v }
            if let v = flat["multimodal.asr_api_key"], !v.isEmpty { asrApiKey = v }
            if let v = flat["multimodal.asr_model"], !v.isEmpty { asrModel = v }
            if let v = flat["multimodal.vlm_enabled"] { vlmEnabled = EnvFileParser.asBool(v, default: vlmEnabled) }
            if let v = flat["multimodal.vlm_api_base"], !v.isEmpty { vlmApiBase = v }
            if let v = flat["multimodal.vlm_api_key"], !v.isEmpty { vlmApiKey = v }
            if let v = flat["multimodal.vlm_model"], !v.isEmpty { vlmModel = v }

            // Fallback to llm.default_provider if VLM fields were inherited in bo-distiller
            let defProv = flat["multimodal.vlm_fallback_provider"]?.nonEmpty ?? flat["llm.default_provider"]?.nonEmpty
            if let prov = defProv {
                if vlmApiBase.isEmpty, let b = flat["llm.providers.\(prov).api_base"], !b.isEmpty { vlmApiBase = b }
                if vlmApiKey.isEmpty, let k = flat["llm.providers.\(prov).api_key"], !k.isEmpty { vlmApiKey = k }
                if vlmModel.isEmpty, let m = flat["llm.providers.\(prov).model"], !m.isEmpty { vlmModel = m }
            }
        }

        let legacyAuto = directory.appendingPathComponent(".cache/paced-collection/monitor-automation.json")
        if let data = try? Data(contentsOf: legacyAuto),
           let json = try? JSONValue.parse(data: data),
           let orcaPath = json["orca_path"]?.stringValue, !orcaPath.isEmpty {
            orcaBin = orcaPath
        }

        normalize()
        var populated: [String] = []
        if !remotePushURL.isEmpty { populated.append("remote_push_url") }
        if !remoteIngestToken.isEmpty { populated.append("remote_ingest_token") }
        if hasKoofrWebdav { populated.append("koofr_webdav") }
        if hasVLM { populated.append("vlm(\(vlmModel))") }
        if !orcaHealAutomationId.isEmpty { populated.append("orca_heal_automation_id") }
        return populated
    }
}

public enum CollectorPaths {
    public static func defaultConfigJSONPath(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = env["BO_COLLECTOR_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/bo-collector/config.json")
            .standardizedFileURL
    }

    public static func defaultLegacyEnvPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/bo-collector/config.env")
            .standardizedFileURL
    }

    public static func defaultStateDir(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = env["BO_COLLECTOR_STATE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/bo-collector")
            .standardizedFileURL
    }

    public static func defaultCacheDir(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = env["BO_COLLECTOR_CACHE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/bo-collector")
            .standardizedFileURL
    }
}

public enum EnvFileParser {
    public static func parse(_ raw: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in raw.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
            guard let eqIdx = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eqIdx]).trimmingCharacters(in: .whitespaces)
            var val = String(line[line.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            if val.count >= 2, let first = val.first, let last = val.last, first == last, (first == "'" || first == "\"") {
                var inner = String(val.dropFirst().dropLast())
                if first == "'" {
                    inner = inner.replacingOccurrences(of: "'\"'\"'", with: "'")
                        .replacingOccurrences(of: "\\'", with: "'")
                } else {
                    inner = inner.replacingOccurrences(of: "\\\"", with: "\"")
                        .replacingOccurrences(of: "\\\\", with: "\\")
                }
                val = inner
            } else if let commentRange = val.range(of: " #") {
                val = String(val[..<commentRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            values[key] = val
        }
        return values
    }

    public static func asBool(_ val: String?, default defaultVal: Bool = false) -> Bool {
        guard let v = val?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else {
            return defaultVal
        }
        return ["1", "true", "yes", "on"].contains(v.lowercased())
    }
}

enum SimpleYAMLScanner {
    static func scanKeyValues(_ text: String, env: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        var stack: [(indent: Int, key: String)] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("-") { continue }
            let indent = rawLine.prefix(while: { $0 == " " }).count
            guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespaces)
            var rest = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)

            while let last = stack.last, last.indent >= indent {
                stack.removeLast()
            }

            if rest.isEmpty || rest.hasPrefix("#") {
                stack.append((indent, key))
                continue
            }

            if rest.count >= 2, let f = rest.first, let l = rest.last, f == l, (f == "\"" || f == "'") {
                rest = String(rest.dropFirst().dropLast())
            } else if let cRange = rest.range(of: " #") {
                rest = String(rest[..<cRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            }

            let resolved = substituteEnv(rest, env: env)
            let fullKey = (stack.map(\.key) + [key]).joined(separator: ".")
            out[fullKey] = resolved
        }
        return out
    }

    private static func substituteEnv(_ raw: String, env: [String: String]) -> String {
        guard raw.hasPrefix("${") && raw.hasSuffix("}") else { return raw }
        let inner = String(raw.dropFirst(2).dropLast())
        if let range = inner.range(of: ":-") {
            let name = String(inner[..<range.lowerBound])
            let defVal = String(inner[range.upperBound...])
            return env[name]?.nonEmpty ?? ProcessInfo.processInfo.environment[name]?.nonEmpty ?? defVal
        }
        return env[inner] ?? ProcessInfo.processInfo.environment[inner] ?? ""
    }
}

public enum SecureFileStore {
    public static func ensureSecureDirectory(_ dir: URL) throws {
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        chmod(dir.path, 0o700)
    }

    public static func atomicWriteData(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try ensureSecureDirectory(dir)
        let tmp = url.appendingPathExtension("tmp.\(UUID().uuidString.prefix(6))")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Failed to open temp file \(tmp.path)"])
        }
        fchmod(fd, 0o600)
        let writeResult = data.withUnsafeBytes { rawBuf -> Int in
            guard let base = rawBuf.baseAddress else { return 0 }
            return write(fd, base, rawBuf.count)
        }
        fsync(fd)
        close(fd)
        if writeResult < 0 {
            unlink(tmp.path)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Failed to write \(tmp.path)"])
        }
        if rename(tmp.path, url.path) != 0 {
            unlink(tmp.path)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Failed to rename temp file to \(url.path)"])
        }
        chmod(url.path, 0o600)
    }

    public static func atomicWriteCodable<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try atomicWriteData(data, to: url)
    }
}

public func rotateLogFile(at url: URL, maxBytes: Int = 2 * 1024 * 1024) {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else { return }
    chmod(url.path, 0o600)
    guard let attrs = try? fm.attributesOfItem(atPath: url.path),
          let size = (attrs[.size] as? NSNumber)?.intValue,
          size >= maxBytes else {
        return
    }
    let rotated = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).1")
    try? fm.removeItem(at: rotated)
    try? fm.moveItem(at: url, to: rotated)
    chmod(rotated.path, 0o600)
}

public final class SafeLogger: @unchecked Sendable {
    public let logPath: URL
    public let maxBytes: Int
    public let echo: Bool
    private let lock = NSLock()

    public init(logPath: URL, maxBytes: Int = 2 * 1024 * 1024, echo: Bool? = nil) {
        self.logPath = logPath
        self.maxBytes = maxBytes
        if let explicitEcho = echo {
            self.echo = explicitEcho
        } else {
            let quiet = ProcessInfo.processInfo.environment["BO_COLLECTOR_QUIET"] ?? ""
            self.echo = !EnvFileParser.asBool(quiet, default: false)
        }
        let dir = logPath.deletingLastPathComponent()
        try? SecureFileStore.ensureSecureDirectory(dir)
        rotateLogFile(at: dir.appendingPathComponent("launchd.log"), maxBytes: maxBytes)
    }

    public func info(_ message: String) { write(level: "INFO", message: message) }
    public func warn(_ message: String) { write(level: "WARN", message: message) }
    public func error(_ message: String) { write(level: "ERROR", message: message) }

    private func write(level: String, message: String) {
        let cleanMsg = message
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let ts = DateFormatting.localTimestamp()
        let line = "\(ts) [\(level)] \(cleanMsg)"

        lock.lock()
        defer { lock.unlock() }

        if echo {
            print(line)
            fflush(stdout)
        }
        rotateLogFile(at: logPath, maxBytes: maxBytes)
        let fd = open(logPath.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        if fd >= 0 {
            fchmod(fd, 0o600)
            if let data = (line + "\n").data(using: .utf8) {
                data.withUnsafeBytes { rawBuf in
                    if let base = rawBuf.baseAddress {
                        _ = Darwin.write(fd, base, rawBuf.count)
                    }
                }
            }
            close(fd)
        }
    }

    public func tail(lines count: Int = 40) -> [String] {
        guard let text = try? String(contentsOf: logPath, encoding: .utf8) else { return [] }
        let all = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return Array(all.suffix(count))
    }
}

public enum DateFormatting {
    public static func localTimestamp(_ date: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fmt.string(from: date)
    }

    public static func isoTimestamp(_ date: Date = Date()) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.string(from: date)
    }
}

extension String {
    func trimmingTrailingSlashes() -> String {
        var s = self
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
