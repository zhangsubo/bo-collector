import AppKit
import BoCollectorCore
import Foundation
import Observation

@MainActor
@Observable
public final class AppModel {
    public var config: CollectorConfig
    public var savedConfig: CollectorConfig
    public var state: CollectorState
    public var launchAgent: LaunchAgentStatus
    public var doctorChecks: [DoctorCheckItem] = []
    public var cloudMonitoredUsers: [XMonitorUser] = []
    public var logLines: [String] = []
    public var incidentJSON: String = ""

    public var isBusy: Bool = false
    public var busyLabel: String = ""
    public var bannerMessage: String? = nil
    public var bannerIsError: Bool = false

    public var cloudTestStatus: String? = nil
    public var koofrTestStatus: String? = nil
    public var vlmTestStatus: String? = nil

    public var bridgeRunning: Bool = false
    public var bridgePort: Int = 18765

    private var bridgeServer: LocalBridgeServer?
    private var refreshTimer: Timer?

    public init() {
        let loaded = CollectorConfig.load()
        self.config = loaded
        self.savedConfig = loaded
        self.state = SyncEngine.loadState(from: loaded.stateDir.appendingPathComponent("state.json"))
        self.launchAgent = LaunchAgentManager.status()
        self.bridgePort = loaded.bridgePort
        reloadDiskSnapshots()

        if loaded.bridgeEnabled {
            startBridgeServer()
        }

        self.refreshTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reloadDiskSnapshots()
            }
        }
    }

    public var hasUnsavedChanges: Bool {
        config != savedConfig
    }

    public var isAuthPaused: Bool {
        state.healer?.authPaused == true || state.status == "auth_paused"
    }

    public var statusSymbolName: String {
        if isBusy { return "arrow.triangle.2.circlepath.circle.fill" }
        if isAuthPaused { return "exclamationmark.shield.fill" }
        if state.status == "error" { return "xmark.octagon.fill" }
        return "tray.and.arrow.down.fill"
    }

    public var statusHeadline: String {
        if isBusy { return busyLabel.isEmpty ? "正在执行任务…" : busyLabel }
        if isAuthPaused {
            let plat = SourceNames.displayName(for: state.healer?.authPlatform ?? "平台")
            return "需人工验证 (\(plat))"
        }
        switch state.status {
        case "idle": return "就绪（空闲 0 驻留后台采集）"
        case "running_backfill": return "正在低速补采历史收藏…"
        case "retry_wait": return "等待网络/队列恢复自动续传"
        case "error": return "最近一次采集异常"
        default: return state.status
        }
    }

    public func reloadDiskSnapshots() {
        let stPath = savedConfig.stateDir.appendingPathComponent("state.json")
        state = SyncEngine.loadState(from: stPath)
        launchAgent = LaunchAgentManager.status()

        let logURL = savedConfig.stateDir.appendingPathComponent("logs/collector.log")
        if let raw = try? String(contentsOf: logURL, encoding: .utf8) {
            let lines = raw.components(separatedBy: .newlines).filter { !$0.isEmpty }
            logLines = Array(lines.suffix(120))
        } else {
            logLines = []
        }

        let incURL = savedConfig.stateDir.appendingPathComponent("incident.json")
        if let raw = try? String(contentsOf: incURL, encoding: .utf8) {
            incidentJSON = raw
        } else {
            incidentJSON = ""
        }

        if let srv = bridgeServer {
            bridgeRunning = srv.isRunning
            if srv.listeningPort > 0 { bridgePort = srv.listeningPort }
        }
    }

    public func saveConfiguration() {
        do {
            config.normalize()
            try config.save()
            savedConfig = config

            if config.bridgeEnabled {
                startBridgeServer()
            } else {
                stopBridgeServer()
            }

            if launchAgent.installed && launchAgent.intervalSeconds != config.syncIntervalSeconds {
                launchAgent = try LaunchAgentManager.install(config: config, interval: config.syncIntervalSeconds)
            }

            showBanner("配置已安全保存至 \(config.configPath.path) (权限 0600)", isError: false)
        } catch {
            showBanner("保存配置失败: \(error.localizedDescription)", isError: true)
        }
    }

    public func revertChanges() {
        config = savedConfig
        showBanner("已放弃未保存的修改", isError: false)
    }

    // MARK: - Bridge Server Control

    public func startBridgeServer() {
        stopBridgeServer()
        let cfgPath = savedConfig.configPath
        let stDir = savedConfig.stateDir
        let logger = SafeLogger(logPath: stDir.appendingPathComponent("logs/collector.log"), echo: false)
        let srv = LocalBridgeServer(
            configProvider: { CollectorConfig.load(configPath: cfgPath, stateDir: stDir) },
            logger: logger
        )
        do {
            try srv.start(portOverride: UInt16(clamping: savedConfig.bridgePort))
            bridgeServer = srv
            bridgeRunning = srv.isRunning
            bridgePort = srv.listeningPort
        } catch {
            bridgeRunning = false
            showBanner("L2 桥接服务启动失败: \(error.localizedDescription)", isError: true)
        }
    }

    public func stopBridgeServer() {
        bridgeServer?.stop()
        bridgeServer = nil
        bridgeRunning = false
    }

    public func toggleBridge(_ enabled: Bool) {
        config.bridgeEnabled = enabled
        saveConfiguration()
    }

    public func openUserscriptURL() {
        if !bridgeRunning {
            startBridgeServer()
        }
        if let url = URL(string: "http://127.0.0.1:\(bridgePort)/api/ingest/userscript.user.js") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - LaunchAgent Service Control

    public func toggleLaunchAgent(_ install: Bool) {
        do {
            if install {
                if hasUnsavedChanges { saveConfiguration() }
                launchAgent = try LaunchAgentManager.install(config: savedConfig, interval: savedConfig.syncIntervalSeconds)
                showBanner("已开启开机自启与每 \(savedConfig.syncIntervalSeconds / 60) 分钟增量采集", isError: false)
            } else {
                LaunchAgentManager.uninstall()
                launchAgent = LaunchAgentManager.status()
                showBanner("已卸载后台定时采集 LaunchAgent", isError: false)
            }
        } catch {
            showBanner("切换定时任务失败: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Async Collection & Diagnostic Actions

    public func syncNow(source: String = "all", force: Bool = false) {
        guard !isBusy else { return }
        if hasUnsavedChanges { saveConfiguration() }
        let snapCfg = savedConfig
        let platforms: [String]? = source == "all"
            ? ((!snapCfg.enabledDefaultPlatforms.isEmpty || snapCfg.rssRefetchEnabled) ? nil : ["x_bookmarks", "douyin"])
            : [source]

        isBusy = true
        busyLabel = "正在增量同步 (\(source == "all" ? "全部启用源" : SourceNames.displayName(for: source)))…"
        Task {
            let res = await Task.detached(priority: .userInitiated) { () -> [String: JSONValue] in
                let logger = SafeLogger(logPath: snapCfg.stateDir.appendingPathComponent("logs/collector.log"), echo: false)
                let engine = SyncEngine(config: snapCfg, logger: logger)
                defer { engine.close() }
                return engine.syncOnce(platforms: platforms, ignoreAuthPause: force)
            }.value

            isBusy = false
            busyLabel = ""
            reloadDiskSnapshots()
            let st = res["status"]?.stringValue ?? "unknown"
            if st == "ok" {
                showBanner("增量同步完成", isError: false)
            } else if st == "auth_paused" {
                showBanner("平台需要人工登录或滑块验证，已在 ego-lite 打开窗口", isError: true)
            } else if st == "retry_wait", let err = res["error"]?.stringValue {
                showBanner("部分源遇瞬时网络超时已自动延后重试，其余源已完成: \(err)", isError: true)
            } else if let err = res["error"]?.stringValue {
                showBanner("同步未完成 (\(st)): \(err)", isError: true)
            } else {
                showBanner("同步返回状态: \(st)", isError: st != "already_running")
            }
        }
    }

    public func resumeAndSync() {
        let snapCfg = savedConfig
        Task {
            await Task.detached(priority: .userInitiated) {
                let logger = SafeLogger(logPath: snapCfg.stateDir.appendingPathComponent("logs/collector.log"), echo: false)
                let engine = SyncEngine(config: snapCfg, logger: logger)
                defer { engine.close() }
                var hm = engine.state.healer ?? HealerState()
                hm.authPaused = false
                hm.consecutiveFailures = 0
                engine.state.healer = hm
                engine.state.status = "idle"
                try? engine.saveState()
            }.value
            reloadDiskSnapshots()
            syncNow(source: "all", force: true)
        }
    }

    public func harvestNow(cloudMode: Bool = false) {
        guard !isBusy else { return }
        if hasUnsavedChanges { saveConfiguration() }
        let snapCfg = savedConfig
        isBusy = true
        busyLabel = cloudMode ? "触发云端回收 ASR 文稿…" : "正在从 Koofr 回收 ASR 文稿…"

        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                let logger = SafeLogger(logPath: snapCfg.stateDir.appendingPathComponent("logs/collector.log"), echo: false)
                let engine = SyncEngine(config: snapCfg, logger: logger)
                defer { engine.close() }
                do {
                    if cloudMode {
                        let json = try engine.triggerCloudHarvestAsr()
                        return .success("云端 ASR 回收完成: \(json.toJSONString())")
                    } else {
                        let res = try engine.harvestAsr()
                        return .success("检查 \(res.checked) 篇 · 补齐 \(res.completed) 篇 · 仍待转写 \(res.stillPending) 篇")
                    }
                } catch {
                    return .failure(error)
                }
            }.value

            isBusy = false
            busyLabel = ""
            reloadDiskSnapshots()
            switch outcome {
            case .success(let msg): showBanner(msg, isError: false)
            case .failure(let err): showBanner("ASR 回收失败: \(ErrorSanitizer.sanitizeDetail(err.localizedDescription))", isError: true)
            }
        }
    }

    public func refetchRssNow() {
        guard !isBusy else { return }
        if hasUnsavedChanges { saveConfiguration() }
        let snapCfg = savedConfig
        isBusy = true
        busyLabel = "正在边缘补抓云端 RSS 待处理全文…"

        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                let logger = SafeLogger(logPath: snapCfg.stateDir.appendingPathComponent("logs/collector.log"), echo: false)
                let engine = SyncEngine(config: snapCfg, logger: logger)
                defer { engine.close() }
                do {
                    let res = try engine.harvestPendingRefetches()
                    return .success(
                        "RSS 边缘补抓：检查 \(res.checked) 篇 · 补齐 \(res.totalSucceeded) 篇 (HTTP \(res.succeededHTTP) / 浏览器 \(res.succeededBrowser)) · 仍待补抓 \(res.stillPending) 篇"
                        + (res.exhausted > 0 ? " · 达上限放弃 \(res.exhausted) 篇" : "")
                    )
                } catch {
                    return .failure(error)
                }
            }.value

            isBusy = false
            busyLabel = ""
            reloadDiskSnapshots()
            switch outcome {
            case .success(let msg): showBanner(msg, isError: false)
            case .failure(let err): showBanner("RSS 边缘补抓失败: \(ErrorSanitizer.sanitizeDetail(err.localizedDescription))", isError: true)
            }
        }
    }

    public func startBackfill(source: String = "all", maxItems: Int = 500) {
        guard !isBusy else { return }
        if hasUnsavedChanges { saveConfiguration() }
        let snapCfg = savedConfig
        isBusy = true
        busyLabel = "历史存量慢速补采运行中…"

        Task {
            let outcome = await Task.detached(priority: .utility) { () -> Result<String, Error> in
                let logger = SafeLogger(logPath: snapCfg.stateDir.appendingPathComponent("logs/collector.log"), echo: false)
                let engine = SyncEngine(config: snapCfg, logger: logger)
                defer { engine.close() }
                let plats = source == "all" ? ["x_bookmarks", "douyin"] : [source]
                do {
                    let res = try engine.runBackfillLoop(platforms: plats, maxTotal: maxItems)
                    return .success("历史补采结束: \(res["status"]?.stringValue ?? "done")")
                } catch {
                    return .failure(error)
                }
            }.value

            isBusy = false
            busyLabel = ""
            reloadDiskSnapshots()
            switch outcome {
            case .success(let msg): showBanner(msg, isError: false)
            case .failure(let err): showBanner("历史补采中断: \(ErrorSanitizer.sanitizeDetail(err.localizedDescription))", isError: true)
            }
        }
    }

    public func requestStopBackfill() {
        let stopURL = savedConfig.stateDir.appendingPathComponent("STOP")
        FileManager.default.createFile(atPath: stopURL.path, contents: Data())
        showBanner("已发送安全停止信号，当前小批次完成后将自动退出", isError: false)
    }

    public func runDoctorChecks() {
        guard !isBusy else { return }
        let draftCfg = config
        isBusy = true
        busyLabel = "正在执行全链路健康体检…"

        Task {
            let items = await Task.detached(priority: .userInitiated) {
                SyncEngine.runDoctor(config: draftCfg)
            }.value
            isBusy = false
            busyLabel = ""
            doctorChecks = items
            let allOK = items.filter(\.critical).allSatisfy(\.ok)
            showBanner(allOK ? "全链路核心检查全部通过" : "部分检查项需要注意，请查看诊断详情", isError: !allOK)
        }
    }

    // MARK: - Individual Connectivity Tests & Cloud X-Monitor Sync

    public func testCloudConnection() {
        var draft = config
        draft.normalize()
        cloudTestStatus = "测试中…"
        Task {
            let msg = await Task.detached(priority: .userInitiated) { () -> (Bool, String, [XMonitorUser]) in
                let logger = SafeLogger(logPath: draft.stateDir.appendingPathComponent("logs/collector.log"), echo: false)
                let engine = SyncEngine(config: draft, logger: logger)
                defer { engine.close() }
                do {
                    let xState = try engine.fetchRemoteState(platform: "x_bookmarks")
                    let dyState = try engine.fetchRemoteState(platform: "douyin")
                    let xmState = try? engine.fetchRemoteState(platform: "x_monitor")
                    let rssState = try? engine.fetchRemoteState(platform: "rss", sourceName: "")
                    let detail = "✓ 连通成功 · 云端近期水位 X=\(xState.recentIds.count) / 抖音=\(dyState.recentIds.count) / 待转写=\(dyState.pendingAsrArticles.count) / 待补抓RSS=\(rssState?.pendingRefetchArticles.count ?? 0)"
                    return (true, detail, xmState?.monitoredUsers ?? [])
                } catch {
                    return (false, "✗ \(ErrorSanitizer.summarize(error).label)", [])
                }
            }.value
            cloudTestStatus = msg.1
            if !msg.2.isEmpty {
                cloudMonitoredUsers = msg.2
            }
        }
    }

    public func refreshCloudMonitoredUsers() {
        var draft = config
        draft.normalize()
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<RemoteStatePayload, Error> in
                let logger = SafeLogger(logPath: draft.stateDir.appendingPathComponent("logs/collector.log"), echo: false)
                let engine = SyncEngine(config: draft, logger: logger)
                defer { engine.close() }
                do {
                    return .success(try engine.fetchRemoteState(platform: "x_monitor"))
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success(let payload):
                cloudMonitoredUsers = payload.monitoredUsers
                showBanner("已从云端同步 \(payload.monitoredUsers.count) 位监控博主", isError: false)
            case .failure(let err):
                showBanner("拉取云端监控列表失败: \(ErrorSanitizer.summarize(err).label)", isError: true)
            }
        }
    }

    public func testKoofrConnection() {
        var draft = config
        draft.normalize()
        koofrTestStatus = "正在检测 Koofr WebDAV 与 Instabox…"
        Task {
            let status = await Task.detached(priority: .userInitiated) { () -> String in
                let client = KoofrAsrClient(config: draft)
                defer { client.close() }
                do {
                    try client.ensureRemoteDirs()
                    let (ibOk, ibState) = client.getInstaboxState()
                    let ibPart = ibOk ? "Instabox(\(draft.instaboxAsrBox))=\(ibState)" : "Instabox CLI 状态=\(ibState)"
                    return "✓ Koofr WebDAV 读写就绪 (ASR/inbox/\(draft.koofrSubdir)) · \(ibPart)"
                } catch {
                    return "✗ \(ErrorSanitizer.summarize(error).label)"
                }
            }.value
            koofrTestStatus = status
        }
    }

    public func testVLMConnection() {
        var draft = config
        draft.normalize()
        vlmTestStatus = "正在请求视觉模型…"
        Task {
            let status = await Task.detached(priority: .userInitiated) { () -> String in
                let http = URLSessionHTTPTransport(config: draft)
                defer { http.close() }
                let (ok, detail) = VLMClient.testConnection(config: draft, http: http)
                return ok ? "✓ \(detail)" : "✗ \(detail)"
            }.value
            vlmTestStatus = status
        }
    }

    public func importFromBoDistiller(directory: URL) {
        do {
            let fields = try config.importFromBoDistiller(directory: directory)
            saveConfiguration()
            showBanner("已从 \(directory.lastPathComponent) 导入: \(fields.joined(separator: ", "))", isError: false)
        } catch {
            showBanner("导入失败: \(error.localizedDescription)", isError: true)
        }
    }

    private func showBanner(_ text: String, isError: Bool) {
        bannerMessage = text
        bannerIsError = isError
    }
}
