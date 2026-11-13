import Darwin
import Foundation

public struct RemotePipelineBusyError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String = "HTTP 422 pipeline busy") {
        self.message = message
    }
    public var errorDescription: String? { message }
}

public struct AuthRequiredError: LocalizedError, Sendable {
    public let platform: String
    public let message: String

    public init(platform: String, message: String) {
        self.platform = platform
        self.message = message
    }

    public var errorDescription: String? { message }
}

public struct CloudHTTPError: LocalizedError, Sendable {
    public let statusCode: Int
    public let message: String

    public init(statusCode: Int, message: String) {
        self.statusCode = statusCode
        self.message = message
    }

    public var errorDescription: String? { message }
}

public enum ErrorSanitizer {
    private static let urlUserInfoRegex = try! NSRegularExpression(pattern: #"(https?://)([^/\s@]+)@"#)
    private static let urlQueryRegex = try! NSRegularExpression(pattern: #"(https?://[^\s?#'"]+)\?[^\s#'"]*"#)
    private static let secretKVRegex = try! NSRegularExpression(
        pattern: #"\b(authorization\s*[:=]\s*(?:(?:bearer|basic|token)\s+)?|bearer\s+|(?:api[_-]?key|token|password|passwd|secret)\s*[:=]\s*)([^\s,;'"]+)"#,
        options: [.caseInsensitive]
    )
    private static let httpCodeRegex = try! NSRegularExpression(pattern: #"HTTP (\d{3})"#)

    public static func sanitizeDetail(_ raw: String, maxLength: Int = 180) -> String {
        var text = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !text.isEmpty else { return "" }

        text = urlUserInfoRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1***@")
        text = urlQueryRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1?...")

        let ns = text as NSString
        let matches = secretKVRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed()
        for m in matches where m.numberOfRanges >= 3 {
            let prefix = ns.substring(with: m.range(at: 1))
            text = (text as NSString).replacingCharacters(in: m.range, with: "\(prefix)***")
        }

        if text.count > maxLength {
            return String(text.prefix(maxLength - 3)).trimmingCharacters(in: .whitespaces) + "..."
        }
        return text
    }

    public static func summarize(_ error: Error) -> (label: String, isTransient: Bool) {
        let rawMsg = error.localizedDescription
        var code: Int? = nil
        if let cloudErr = error as? CloudHTTPError {
            code = cloudErr.statusCode
        } else {
            let nsErr = error as NSError
            if (100...599).contains(nsErr.code) && (nsErr.domain.contains("HTTP") || nsErr.domain.contains("WebDAV")) {
                code = nsErr.code
            }
        }
        if code == nil {
            let ns = rawMsg as NSString
            if let m = httpCodeRegex.firstMatch(in: rawMsg, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges >= 2 {
                code = Int(ns.substring(with: m.range(at: 1)))
            }
        }

        let typeName: String
        if error is RemotePipelineBusyError {
            typeName = "RemotePipelineBusyError"
        } else if error is HTTPTransportError {
            typeName = "HTTPTransportError"
        } else {
            typeName = String(describing: type(of: error))
        }

        let head = typeName + (code != nil ? " HTTP \(code!)" : "")
        let detail = sanitizeDetail(rawMsg)
        let label: String
        if !detail.isEmpty && detail != head && detail != "HTTP \(code ?? 0)" {
            label = "\(head): \(detail)"
        } else {
            label = head
        }

        let lowerRaw = rawMsg.lowercased()
        let isNetworkTimeoutOrReset = lowerRaw.contains("err_timed_out")
            || lowerRaw.contains("err_connection")
            || lowerRaw.contains("err_network")
            || lowerRaw.contains("err_internet_disconnected")
            || lowerRaw.contains("err_proxy")
            || lowerRaw.contains("err_ssl")
            || lowerRaw.contains("err_quic")
            || lowerRaw.contains("timed out")
            || lowerRaw.contains("timeout")

        let transient = (error is HTTPTransportError)
            || (error is RemotePipelineBusyError)
            || (code != nil && code! >= 500)
            || isNetworkTimeoutOrReset
        return (label, transient)
    }
}

public final class IncidentHealer: @unchecked Sendable {
    public let config: CollectorConfig
    public let logger: SafeLogger
    public let projectRoot: URL
    private let runner: CommandRunner

    public init(
        config: CollectorConfig,
        logger: SafeLogger,
        projectRoot: URL? = nil,
        runner: CommandRunner = DefaultCommandRunner()
    ) {
        self.config = config
        self.logger = logger
        self.projectRoot = (projectRoot ?? Self.resolveDefaultProjectRoot(fallback: config.stateDir)).standardizedFileURL
        self.runner = runner
    }

    public static func resolveDefaultProjectRoot(fallback: URL) -> URL {
        let fm = FileManager.default
        func findRepoRoot(startingAt start: URL) -> URL? {
            var dir = start.resolvingSymlinksInPath().standardizedFileURL
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.path, isDirectory: &isDir), !isDir.boolValue {
                dir = dir.deletingLastPathComponent()
            }
            for _ in 0..<8 {
                let pkg = dir.appendingPathComponent("Package.swift").path
                let git = dir.appendingPathComponent(".git").path
                if fm.fileExists(atPath: pkg) || fm.fileExists(atPath: git) {
                    return dir
                }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
            return nil
        }

        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        if let hit = findRepoRoot(startingAt: cwd) {
            return hit
        }
        if let exe = Bundle.main.executableURL, let hit = findRepoRoot(startingAt: exe) {
            return hit
        }
        let defaultRepo = fm.homeDirectoryForCurrentUser.appendingPathComponent("Code/bo-collector")
        if fm.fileExists(atPath: defaultRepo.appendingPathComponent("Package.swift").path) {
            return defaultRepo
        }
        return fallback
    }

    public var incidentPath: URL {
        config.stateDir.appendingPathComponent("incident.json")
    }

    public static func findOrcaBinary(preferred: String = "orca") -> String? {
        ExecutableLocator.find(
            preferred: preferred,
            binaryName: "orca",
            extraCandidates: [
                "~/.local/bin/orca",
                "/opt/homebrew/bin/orca",
                "/usr/local/bin/orca",
                "/Applications/Orca.app/Contents/Resources/bin/orca",
            ]
        )
    }

    @discardableResult
    public static func sendMacOSNotification(
        title: String,
        message: String,
        runner: CommandRunner = DefaultCommandRunner()
    ) -> Bool {
        guard let osa = ExecutableLocator.find(binaryName: "osascript") else { return false }
        let script = "on run argv\ndisplay notification (item 2 of argv) with title (item 1 of argv)\nend run"
        do {
            let res = try runner.run(
                executable: osa,
                arguments: ["-e", script, "--", String(title.prefix(80)), String(message.prefix(220))],
                currentDirectory: nil,
                environment: nil,
                timeout: 8
            )
            return res.exitCode == 0
        } catch {
            return false
        }
    }

    public func handleAuthPause(state: inout CollectorState, platform: String, reason: String) {
        let now = Date().timeIntervalSince1970
        var healMeta = state.healer ?? HealerState()
        healMeta.authPaused = true
        healMeta.authPlatform = platform
        healMeta.authReason = String(reason.prefix(200))

        let lastNotified = healMeta.lastAuthNotifyAt ?? 0
        if now - lastNotified >= 7200 {
            Self.sendMacOSNotification(
                title: "BoCollector 需要人工验证",
                message: "\(SourceNames.displayName(for: platform)) 需登录或完成验证，已在 ego-lite 交还窗口；完成后点击恢复采集。",
                runner: runner
            )
            healMeta.lastAuthNotifyAt = now
        }
        state.healer = healMeta
        logger.warn("[\(platform)] 等待人工登录/验证: \(reason.prefix(160))")
    }

    public func recordSuccess(state: inout CollectorState) {
        var healMeta = state.healer ?? HealerState()
        healMeta.consecutiveFailures = 0
        healMeta.lastCodeError = nil
        state.healer = healMeta
    }

    public func handleUnexpectedFailure(
        state: inout CollectorState,
        errorLabel: String,
        stage: String,
        instaboxState: String = "unknown"
    ) -> [String: JSONValue] {
        let now = Date().timeIntervalSince1970
        var healMeta = state.healer ?? HealerState()
        let count = healMeta.consecutiveFailures + 1
        healMeta.consecutiveFailures = count
        healMeta.lastCodeError = String(errorLabel.prefix(200))
        healMeta.lastErrorAt = DateFormatting.localTimestamp()
        state.healer = healMeta

        if count < 2 {
            logger.warn("采集异常 (\(count)/2，下轮重试前暂不唤醒 Agent): [\(stage)] \(errorLabel)")
            return [
                "triggered": .bool(false),
                "reason": .string("below_threshold"),
                "consecutive_failures": .int(count),
            ]
        }

        var sourcesSummary: [String: JSONValue] = [:]
        for (k, v) in state.sources {
            sourcesSummary[k] = .object([
                "saved": .int(v.saved),
                "known_count": .int(v.known.count),
                "outbox_count": .int(v.outbox?.count ?? 0),
                "status": .string(v.status),
            ])
        }
        let incident: JSONValue = .object([
            "created_at": .string(DateFormatting.localTimestamp()),
            "project_root": .string(projectRoot.path),
            "stage": .string(stage),
            "error_label": .string(String(errorLabel.prefix(240))),
            "consecutive_failures": .int(count),
            "instabox_state": .string(instaboxState),
            "sources_summary": .object(sourcesSummary),
            "recent_logs": .array(logger.tail(lines: 40).map(JSONValue.string)),
        ])
        if let data = try? incident.toData(pretty: true) {
            try? SecureFileStore.atomicWriteData(data, to: incidentPath)
        }

        let lastHeal = healMeta.lastHealAt ?? 0
        if now - lastHeal < Double(config.healCooldownSeconds) {
            logger.warn("连续异常已记录 incident.json，但处于自愈冷却期内，跳过重复唤醒 Agent")
            return [
                "triggered": .bool(false),
                "reason": .string("cooldown"),
                "incident_path": .string(incidentPath.path),
            ]
        }

        let (triggered, detail) = triggerOrcaAutomation()
        healMeta.lastHealAt = now
        healMeta.lastHealResult = detail
        state.healer = healMeta

        if triggered {
            logger.info("已唤醒 Orca 自愈 Agent 诊断修复 (\(detail))")
            Self.sendMacOSNotification(
                title: "BoCollector 已启动自动自愈",
                message: "连续 \(count) 次异常 (\(errorLabel.prefix(60)))，已唤醒 Agent 诊断。",
                runner: runner
            )
        } else {
            logger.warn("已生成故障快照 \(incidentPath.path)（未配置自动唤醒或触发跳过: \(detail)）")
            Self.sendMacOSNotification(
                title: "BoCollector 连续采集异常",
                message: "连续 \(count) 次失败: \(errorLabel.prefix(80))，请打开控制台检查。",
                runner: runner
            )
        }
        return [
            "triggered": .bool(triggered),
            "detail": .string(detail),
            "incident_path": .string(incidentPath.path),
        ]
    }

    private func triggerOrcaAutomation() -> (Bool, String) {
        let autoId = config.orcaHealAutomationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !autoId.isEmpty else { return (false, "no_automation_id") }
        guard let orcaBin = Self.findOrcaBinary(preferred: config.orcaBin) else {
            return (false, "orca_cli_not_found")
        }

        do {
            let runsRes = try runner.run(
                executable: orcaBin,
                arguments: ["automations", "runs", "--id", autoId, "--json"],
                currentDirectory: projectRoot,
                environment: nil,
                timeout: 30
            )
            if runsRes.exitCode == 0,
               let body = try? JSONValue.parse(string: runsRes.stdout),
               body["ok"]?.boolValue == true,
               let runs = body["result"]?["runs"]?.arrayValue {
                let active = runs.contains { r in
                    let st = (r["status"]?.stringValue ?? "").lowercased()
                    return ["running", "pending", "queued", "starting"].contains(st)
                }
                if active {
                    return (false, "agent_already_running")
                }
            }

            let runRes = try runner.run(
                executable: orcaBin,
                arguments: ["automations", "run", autoId, "--json"],
                currentDirectory: projectRoot,
                environment: nil,
                timeout: 30
            )
            if runRes.exitCode == 0,
               let resp = try? JSONValue.parse(string: runRes.stdout),
               resp["ok"]?.boolValue == true {
                return (true, "automation:\(autoId)")
            }
            return (false, "orca_exit_\(runRes.exitCode)")
        } catch {
            return (false, "orca_error")
        }
    }
}

// MARK: - macOS LaunchAgent Manager

public struct LaunchAgentStatus: Sendable, Equatable {
    public var installed: Bool
    public var loaded: Bool
    public var plistPath: String
    public var binaryPath: String
    public var intervalSeconds: Int
    public var detailLines: [String]

    public init(
        installed: Bool = false,
        loaded: Bool = false,
        plistPath: String = "",
        binaryPath: String = "",
        intervalSeconds: Int = 1800,
        detailLines: [String] = []
    ) {
        self.installed = installed
        self.loaded = loaded
        self.plistPath = plistPath
        self.binaryPath = binaryPath
        self.intervalSeconds = intervalSeconds
        self.detailLines = detailLines
    }
}

public enum LaunchAgentManager {
    public static let label = "com.bo.collector"

    public static func plistURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    public static func resolveCLIBinary() -> String? {
        let fm = FileManager.default
        if let exeURL = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            if exeURL.lastPathComponent == "bo-collect" && fm.isExecutableFile(atPath: exeURL.path) {
                return exeURL.path
            }
            let sibling = exeURL.deletingLastPathComponent().appendingPathComponent("bo-collect")
            if fm.isExecutableFile(atPath: sibling.path) {
                return sibling.path
            }
        }
        let arg0 = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        if arg0.lastPathComponent == "bo-collect" && fm.isExecutableFile(atPath: arg0.path) {
            return arg0.path
        }
        let argSibling = arg0.deletingLastPathComponent().appendingPathComponent("bo-collect")
        if fm.isExecutableFile(atPath: argSibling.path) {
            return argSibling.path
        }
        return ExecutableLocator.find(
            binaryName: "bo-collect",
            extraCandidates: [
                "~/.local/bin/bo-collect",
                "~/Applications/BoCollector.app/Contents/MacOS/bo-collect",
                "/Applications/BoCollector.app/Contents/MacOS/bo-collect",
            ]
        )
    }

    public static func status(runner: CommandRunner = DefaultCommandRunner()) -> LaunchAgentStatus {
        let plist = plistURL()
        let fm = FileManager.default
        let installed = fm.fileExists(atPath: plist.path)
        var binPath = ""
        var interval = 1800

        if installed,
           let data = try? Data(contentsOf: plist),
           let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
            if let args = dict["ProgramArguments"] as? [String], let first = args.first {
                binPath = first
            }
            if let iv = dict["StartInterval"] as? Int {
                interval = iv
            }
        }

        let uid = getuid()
        let domainTarget = "gui/\(uid)/\(label)"
        var loaded = false
        var lines: [String] = []
        if let res = try? runner.run(executable: "/bin/launchctl", arguments: ["print", domainTarget], currentDirectory: nil, environment: nil, timeout: 10),
           res.exitCode == 0 {
            loaded = true
            for ln in res.stdout.components(separatedBy: .newlines) {
                let t = ln.trimmingCharacters(in: .whitespaces)
                if t.contains("state =") || t.contains("runs =") || t.contains("last exit code =") || t.contains("run interval =") {
                    lines.append(t)
                }
            }
        }
        return LaunchAgentStatus(
            installed: installed,
            loaded: loaded,
            plistPath: plist.path,
            binaryPath: binPath,
            intervalSeconds: interval,
            detailLines: lines
        )
    }

    public static func install(
        config: CollectorConfig,
        interval: Int,
        cliBinaryOverride: String? = nil,
        runner: CommandRunner = DefaultCommandRunner()
    ) throws -> LaunchAgentStatus {
        let cleanInterval = max(60, interval)
        guard let cliBin = cliBinaryOverride ?? resolveCLIBinary() else {
            throw NSError(domain: "LaunchAgent", code: 404, userInfo: [NSLocalizedDescriptionKey: "未找到 bo-collect 可执行文件"])
        }

        let logDir = config.stateDir.appendingPathComponent("logs")
        try SecureFileStore.ensureSecureDirectory(logDir)
        let launchdLog = logDir.appendingPathComponent("launchd.log")
        if FileManager.default.fileExists(atPath: launchdLog.path) {
            chmod(launchdLog.path, 0o600)
        }

        let homeLocal = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
        let workingDir = IncidentHealer.resolveDefaultProjectRoot(fallback: config.stateDir).path
        let plistDict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [
                cliBin,
                "--config", config.configPath.path,
                "--state-dir", config.stateDir.path,
                "--quiet",
                "sync",
            ],
            "WorkingDirectory": workingDir,
            "RunAtLoad": true,
            "StartInterval": cleanInterval,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "StandardOutPath": launchdLog.path,
            "StandardErrorPath": launchdLog.path,
            "EnvironmentVariables": [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:\(homeLocal):/usr/bin:/bin:/usr/sbin:/sbin",
                "BO_COLLECTOR_QUIET": "1",
            ],
        ]

        let plistData = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
        let plist = plistURL()
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plistData.write(to: plist, options: .atomic)
        chmod(plist.path, 0o600)

        let uid = getuid()
        _ = try? runner.run(executable: "/bin/launchctl", arguments: ["bootout", "gui/\(uid)/\(label)"], currentDirectory: nil, environment: nil, timeout: 10)
        let boot = try runner.run(executable: "/bin/launchctl", arguments: ["bootstrap", "gui/\(uid)", plist.path], currentDirectory: nil, environment: nil, timeout: 15)
        if boot.exitCode != 0 {
            let errText = (boot.stderr.isEmpty ? boot.stdout : boot.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "LaunchAgent", code: Int(boot.exitCode), userInfo: [NSLocalizedDescriptionKey: "launchctl bootstrap 失败: \(errText)"])
        }
        return status(runner: runner)
    }

    public static func uninstall(runner: CommandRunner = DefaultCommandRunner()) {
        let uid = getuid()
        _ = try? runner.run(executable: "/bin/launchctl", arguments: ["bootout", "gui/\(uid)/\(label)"], currentDirectory: nil, environment: nil, timeout: 10)
        try? FileManager.default.removeItem(at: plistURL())
    }
}
