import BoCollectorCore
import Darwin
import Foundation

private func printHelp() {
    let text = """
    BoCollector 原生边缘采集命令行工具 (bo-collect)

    用法:
      bo-collect [--config <path>] [--state-dir <dir>] [--quiet] <command> [options]

    命令:
      sync [--source all|x_bookmarks|douyin|x_monitor] [--limit N] [--force]
          执行一轮增量采集（回收已完成 ASR + 抓新收藏/监控 + 推云端，传完即退）
      backfill [--source all|x_bookmarks|douyin] [--max-items N] [--until-end]
          低频慢速补采历史存量收藏
      stop
          请求当前运行中的 backfill 在本批结束后安全停止
      harvest [--cloud]
          检查 Koofr 网盘回收已完成转写文稿并删除网盘原视频（--cloud 触发云端自助回收）
      status
          查看当前同步进度、待传队列、ASR、LaunchAgent 与异常自愈状态
      resume [--sync-now]
          人工完成登录/验证码后解除暂停态
      doctor
          一键检查配置文件权限、ego-browser、云端 API、Koofr WebDAV 与 Instabox 状态
      bridge [--port 18765]
          前台启动 L2 油猴伴随采集本地桥接 HTTP 服务 (127.0.0.1:18765)
      import-config [bo_distiller_dir]
          纯原生解析旧 bo-distiller 目录 (.env / config.yaml) 无损导入配置至 config.json (0600)
      import-state [legacy_state_json]
          从旧 state.json 无损合并已采集 ID 水位线与待发队列
      service <install|uninstall|status> [--interval 1800]
          管理 macOS 开机自启与定时采集 LaunchAgent (com.bo.collector)
    """
    print(text)
}

private func resolvePlatforms(_ sourceArg: String, config: CollectorConfig) -> [String] {
    if sourceArg == "all" {
        let enabled = config.enabledDefaultPlatforms
        return enabled.isEmpty ? ["x_bookmarks", "douyin"] : enabled
    }
    return [sourceArg]
}

private var activeEngineForSignal: SyncEngine?

private func runCLI() -> Int32 {
    var args = Array(CommandLine.arguments.dropFirst())
    var customConfigPath: URL? = nil
    var customStateDir: URL? = nil
    var quiet = false

    while let first = args.first, first.hasPrefix("-") {
        if first == "-h" || first == "--help" {
            printHelp()
            return 0
        } else if first == "--quiet" {
            quiet = true
            args.removeFirst()
        } else if first == "--config" {
            args.removeFirst()
            guard let val = args.first else {
                fputs("缺少 --config 参数值\n", stderr)
                return 2
            }
            customConfigPath = URL(fileURLWithPath: (val as NSString).expandingTildeInPath)
            args.removeFirst()
        } else if first == "--state-dir" {
            args.removeFirst()
            guard let val = args.first else {
                fputs("缺少 --state-dir 参数值\n", stderr)
                return 2
            }
            customStateDir = URL(fileURLWithPath: (val as NSString).expandingTildeInPath)
            args.removeFirst()
        } else {
            break
        }
    }

    guard let command = args.first else {
        printHelp()
        return 0
    }
    args.removeFirst()

    var cfg = CollectorConfig.load(configPath: customConfigPath, stateDir: customStateDir)

    switch command {
    case "help", "--help", "-h":
        printHelp()
        return 0

    case "doctor":
        let checks = SyncEngine.runDoctor(config: cfg)
        for item in checks {
            let mark = item.ok ? "OK  " : "WARN"
            let padded = item.check.padding(toLength: 19, withPad: " ", startingAt: 0)
            print("[\(mark)] \(padded) \(item.detail)")
        }
        let criticalOK = checks.filter(\.critical).allSatisfy(\.ok)
        return criticalOK ? 0 : 1

    case "import-config":
        let dirStr = args.first ?? "~/Code/bo-distiller"
        let dirURL = URL(fileURLWithPath: (dirStr as NSString).expandingTildeInPath)
        do {
            let fields = try cfg.importFromBoDistiller(directory: dirURL)
            try cfg.save()
            print("已写入安全配置文件: \(cfg.configPath.path) (权限 0600)")
            print("已导入关键配置项: \(fields.joined(separator: ", "))")
            return 0
        } catch {
            fputs("导入配置失败: \(error.localizedDescription)\n", stderr)
            return 1
        }

    case "service":
        guard let action = args.first else {
            fputs("用法: bo-collect service <install|uninstall|status> [--interval 1800]\n", stderr)
            return 2
        }
        args.removeFirst()
        var interval = cfg.syncIntervalSeconds
        var idx = 0
        while idx < args.count {
            if args[idx] == "--interval", idx + 1 < args.count, let v = Int(args[idx + 1]) {
                interval = v
                idx += 2
            } else {
                idx += 1
            }
        }
        switch action {
        case "uninstall":
            LaunchAgentManager.uninstall()
            print("已卸载定时采集服务: \(LaunchAgentManager.label)")
            return 0
        case "status":
            let st = LaunchAgentManager.status()
            if !st.loaded {
                print("\(LaunchAgentManager.label): 未加载 (plist=\(st.installed ? "存在" : "不存在"))")
                return 1
            }
            print("\(LaunchAgentManager.label): 已加载 (binary=\(st.binaryPath), interval=\(st.intervalSeconds)s)")
            for ln in st.detailLines { print("  \(ln)") }
            return 0
        case "install":
            if interval < 60 {
                fputs("--interval 至少为 60 秒\n", stderr)
                return 1
            }
            do {
                cfg.syncIntervalSeconds = interval
                try? cfg.save()
                let st = try LaunchAgentManager.install(config: cfg, interval: interval)
                print("已注册并启动原生 Swift LaunchAgent: \(LaunchAgentManager.label)")
                print("  配置文件 : \(st.plistPath)")
                print("  执行程序 : \(st.binaryPath)")
                print("  运行策略 : 开机登录后自动跑一轮 + 每 \(interval) 秒增量巡检（跑完即退，平时 0 内存）")
                print("  运行日志 : \(cfg.stateDir.appendingPathComponent("logs/collector.log").path)")
                return 0
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                return 1
            }
        default:
            fputs("未知 service 子命令: \(action)\n", stderr)
            return 2
        }

    case "stop":
        try? SecureFileStore.ensureSecureDirectory(cfg.stateDir)
        let stopURL = cfg.stateDir.appendingPathComponent("STOP")
        FileManager.default.createFile(atPath: stopURL.path, contents: Data())
        print("已写入安全停止标记：当前批次完成后自动退出并保留进度。")
        return 0

    case "bridge":
        var portOverride: UInt16? = nil
        var i = 0
        while i < args.count {
            if args[i] == "--port", i + 1 < args.count, let p = UInt16(args[i + 1]) {
                portOverride = p
                i += 2
            } else {
                i += 1
            }
        }
        let logger = SafeLogger(logPath: cfg.stateDir.appendingPathComponent("logs/collector.log"), echo: !quiet)
        let configPath = cfg.configPath
        let stateDir = cfg.stateDir
        let server = LocalBridgeServer(
            configProvider: { CollectorConfig.load(configPath: configPath, stateDir: stateDir) },
            logger: logger
        )
        do {
            try server.start(portOverride: portOverride)
            print("L2 油猴本地桥接运行中: http://127.0.0.1:\(server.listeningPort) (按 Ctrl+C 停止)")
            print("油猴脚本安装地址: http://127.0.0.1:\(server.listeningPort)/api/ingest/userscript.user.js")
            dispatchMain()
        } catch {
            fputs("启动本地桥接失败: \(error.localizedDescription)\n", stderr)
            return 1
        }

    default:
        break
    }

    let logger = SafeLogger(
        logPath: cfg.stateDir.appendingPathComponent("logs/collector.log"),
        echo: quiet ? false : nil
    )
    let engine = SyncEngine(config: cfg, logger: logger)
    defer { engine.close() }

    switch command {
    case "import-state":
        let rawPath = args.first ?? "~/Code/bo-distiller/.cache/paced-collection/state.json"
        let url = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath)
        do {
            let added = try engine.importLegacyState(from: url)
            let jsonObj = JSONValue.object(added.mapValues(JSONValue.int))
            print("已合并历史已采集水位线至 \(engine.statePath.path): \(jsonObj.toJSONString())")
            return 0
        } catch {
            fputs("导入状态失败: \(error.localizedDescription)\n", stderr)
            return 1
        }

    case "status":
        let st = engine.state
        var srcSummary: [String: JSONValue] = [:]
        for (k, v) in st.sources {
            srcSummary[k] = .object([
                "saved": .int(v.saved),
                "known": .int(v.known.count),
                "outbox": .int(v.outbox?.count ?? 0),
                "status": .string(v.status),
            ])
        }
        let svc = LaunchAgentManager.status()
        let encoder = JSONEncoder()
        let asrVal = (try? st.asr.map { try JSONValue.parse(data: encoder.encode($0)) }) ?? .null
        let healerVal = (try? st.healer.map { try JSONValue.parse(data: encoder.encode($0)) }) ?? .null
        let summary: JSONValue = .object([
            "status": .string(st.status),
            "updated_at": st.updatedAt.map(JSONValue.string) ?? .null,
            "config_path": .string(cfg.configPath.path),
            "launch_agent": .object([
                "loaded": .bool(svc.loaded),
                "interval_seconds": .int(svc.intervalSeconds),
                "binary": .string(svc.binaryPath),
            ]),
            "asr": asrVal,
            "healer": healerVal,
            "sources": .object(srcSummary),
        ])
        print(summary.toJSONString(pretty: true))
        return 0

    case "resume":
        let syncNow = args.contains("--sync-now")
        var hm = engine.state.healer ?? HealerState()
        hm.authPaused = false
        hm.consecutiveFailures = 0
        engine.state.healer = hm
        engine.state.status = "idle"
        try? engine.saveState()
        print("已解除暂停标记。")
        if syncNow {
            let res = engine.syncOnce(ignoreAuthPause: true)
            print(JSONValue.object(res).toJSONString())
            let st = res["status"]?.stringValue ?? ""
            return (st == "ok" || st == "already_running") ? 0 : 1
        }
        return 0

    case "harvest":
        if args.contains("--cloud") {
            do {
                let res = try engine.triggerCloudHarvestAsr()
                print(res.toJSONString())
                return 0
            } catch {
                fputs("云端 harvest-asr 失败: \(error.localizedDescription)\n", stderr)
                return 1
            }
        }
        do {
            let res = try engine.harvestAsr()
            let out: JSONValue = .object([
                "checked": .int(res.checked),
                "completed": .int(res.completed),
                "still_pending": .int(res.stillPending),
            ])
            print(out.toJSONString())
            return 0
        } catch {
            fputs("回收 ASR 失败: \(error.localizedDescription)\n", stderr)
            return 1
        }

    case "sync":
        var source = "all"
        var limit: Int? = nil
        var force = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--source":
                if i + 1 < args.count { source = args[i + 1]; i += 2 } else { i += 1 }
            case "--limit":
                if i + 1 < args.count { limit = Int(args[i + 1]); i += 2 } else { i += 1 }
            case "--force":
                force = true
                i += 1
            default:
                i += 1
            }
        }
        let platforms = resolvePlatforms(source, config: cfg)
        let res = engine.syncOnce(platforms: platforms, limitOverride: limit, ignoreAuthPause: force)
        if !quiet {
            print(JSONValue.object(res).toJSONString())
        }
        let st = res["status"]?.stringValue ?? ""
        return ["ok", "already_running", "retry_wait", "auth_paused"].contains(st) ? 0 : 1

    case "backfill":
        var source = "all"
        var maxItems = 2000
        var untilEnd = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--source":
                if i + 1 < args.count { source = args[i + 1]; i += 2 } else { i += 1 }
            case "--max-items":
                if i + 1 < args.count, let v = Int(args[i + 1]) { maxItems = v; i += 2 } else { i += 1 }
            case "--until-end":
                untilEnd = true
                i += 1
            default:
                i += 1
            }
        }
        activeEngineForSignal = engine
        signal(SIGINT) { _ in activeEngineForSignal?.stopping = true }
        signal(SIGTERM) { _ in activeEngineForSignal?.stopping = true }
        let platforms = source == "all" ? ["x_bookmarks", "douyin"] : [source]
        do {
            let res = try engine.runBackfillLoop(platforms: platforms, maxTotal: untilEnd ? nil : maxItems)
            print(JSONValue.object(res).toJSONString())
            return 0
        } catch {
            fputs("Backfill 失败: \(error.localizedDescription)\n", stderr)
            return 1
        }

    default:
        fputs("未知命令: \(command)\n", stderr)
        printHelp()
        return 2
    }
}

exit(runCLI())
