import Foundation

public struct BrowserCollectResult: Sendable {
    public var status: String // "ok" | "handoff_required" | "login_required" | "unavailable" | "error"
    public var payloads: [JSONValue]
    public var domItems: [[String: JSONValue]]
    public var pageURL: String
    public var spaceId: Int?
    public var stoppedOnKnown: Bool
    public var message: String

    public init(
        status: String,
        payloads: [JSONValue] = [],
        domItems: [[String: JSONValue]] = [],
        pageURL: String = "",
        spaceId: Int? = nil,
        stoppedOnKnown: Bool = false,
        message: String = ""
    ) {
        self.status = status
        self.payloads = payloads
        self.domItems = domItems
        self.pageURL = pageURL
        self.spaceId = spaceId
        self.stoppedOnKnown = stoppedOnKnown
        self.message = message
    }
}

public struct BrowserDownloadItem: Codable, Sendable {
    public var id: String
    public var url: String
    public var dest: String

    public init(id: String, url: String, dest: String) {
        self.id = id
        self.url = url
        self.dest = dest
    }
}

public struct BrowserArticleExtractResult: Equatable, Sendable {
    public var status: String // "ok" | "interstitial_blocked" | "unavailable" | "error"
    public var title: String
    public var markdown: String
    public var finalURL: String
    public var message: String

    public init(
        status: String,
        title: String = "",
        markdown: String = "",
        finalURL: String = "",
        message: String = ""
    ) {
        self.status = status
        self.title = title
        self.markdown = markdown
        self.finalURL = finalURL
        self.message = message
    }
}

public protocol BrowserCollecting: Sendable {
    func isAvailable() -> Bool
    func checkVersion() -> (ok: Bool, detail: String)
    func ensureSpace(spaceId: Int?) -> BrowserCollectResult
    func finishSpace(spaceId: Int?)
    func collectFeed(
        platform: String,
        knownIds: [String],
        maxItems: Int,
        handoff: Bool,
        keepOpen: Bool,
        backfill: Bool,
        spaceId: Int?,
        collectsId: String
    ) -> BrowserCollectResult
    func collectXMonitor(
        handles: [String],
        knownIdsByHandle: [String: [String]],
        listURL: String,
        maxItemsPerUser: Int,
        handoff: Bool,
        keepOpen: Bool
    ) -> BrowserCollectResult
    func downloadMediaBatch(
        downloads: [BrowserDownloadItem],
        referer: String,
        spaceId: Int?,
        finishWhenDone: Bool
    ) -> [String: String]
    func extractReadableArticle(url: String, handoff: Bool) -> BrowserArticleExtractResult
}

public extension BrowserCollecting {
    func extractReadableArticle(url: String, handoff: Bool = false) -> BrowserArticleExtractResult {
        BrowserArticleExtractResult(status: "unavailable", message: "Browser article extractor not implemented")
    }
}

public final class EgoBrowserClient: BrowserCollecting, @unchecked Sendable {
    public static let incrementalKnownLimit = 5000

    public let cacheDir: URL
    public let workDir: URL
    public let spaceName: String
    public let preferredBin: String
    private let runner: CommandRunner

    public init(
        cacheDir: URL,
        spaceName: String = "bo-collector",
        preferredBin: String = "",
        runner: CommandRunner = DefaultCommandRunner()
    ) {
        self.cacheDir = cacheDir.standardizedFileURL
        self.workDir = self.cacheDir.appendingPathComponent("ego_runs")
        self.spaceName = spaceName.isEmpty ? "bo-collector" : spaceName
        self.preferredBin = preferredBin
        self.runner = runner
    }

    public static func findBinary(preferred: String = "") -> String? {
        ExecutableLocator.find(
            preferred: preferred,
            binaryName: "ego-browser",
            extraCandidates: [
                "~/.local/bin/ego-browser",
                "/opt/homebrew/bin/ego-browser",
                "/usr/local/bin/ego-browser",
                "/Applications/Ego Lite.app/Contents/Resources/bin/ego-browser",
            ]
        )
    }

    public func isAvailable() -> Bool {
        Self.findBinary(preferred: preferredBin) != nil
    }

    public func checkVersion() -> (ok: Bool, detail: String) {
        guard let bin = Self.findBinary(preferred: preferredBin) else {
            return (false, "ego-browser CLI not found")
        }
        do {
            let res = try runner.run(executable: bin, arguments: ["--version"], currentDirectory: nil, environment: nil, timeout: 10)
            let combined = (res.stdout.isEmpty ? res.stderr : res.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            let first = combined.components(separatedBy: .newlines).first ?? bin
            return (res.exitCode == 0, first.isEmpty ? bin : first)
        } catch {
            return (false, "ego-browser check failed: \(error.localizedDescription)")
        }
    }

    private func runMJS(_ scriptBody: String, prefix: String, timeout: TimeInterval = 240) throws -> SubprocessResult {
        guard let bin = Self.findBinary(preferred: preferredBin) else {
            throw NSError(domain: "EgoBrowser", code: 1, userInfo: [NSLocalizedDescriptionKey: "ego-browser CLI not installed"])
        }
        let runDir = workDir.appendingPathComponent("\(prefix)-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runDir) }

        let scriptURL = runDir.appendingPathComponent("task.mjs")
        try scriptBody.write(to: scriptURL, atomically: true, encoding: .utf8)
        let importExpr = "await import('\(scriptURL.absoluteString)')"
        return try runner.run(
            executable: bin,
            arguments: ["nodejs", "-e", importExpr],
            currentDirectory: nil,
            environment: nil,
            timeout: timeout
        )
    }

    public func ensureSpace(spaceId: Int? = nil) -> BrowserCollectResult {
        guard isAvailable() else {
            return BrowserCollectResult(status: "unavailable", message: "ego-browser CLI not found")
        }
        let outDir = workDir.appendingPathComponent("space-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }

        let resultFile = outDir.appendingPathComponent("result.json")
        let cfgObj: JSONValue = .object([
            "spaceId": spaceId.map(JSONValue.int) ?? .null,
            "spaceName": .string(spaceName),
            "resultPath": .string(resultFile.path),
        ])
        let script = """
        const fs = await import("node:fs/promises");
        const cfg = \(cfgObj.toJSONString());
        try {
          const spaces = await listTaskSpaces();
          const existing = cfg.spaceId !== null ? spaces.find(s => s.id === cfg.spaceId) : null;
          if (existing && ["user", "inactive", "unassigned"].includes(existing.ownership)) {
            throw new Error("Existing space is under user control; awaiting manual resume");
          }
          const task = await taskSpace(existing ? cfg.spaceId : cfg.spaceName);
          await fs.writeFile(cfg.resultPath, JSON.stringify({ status: "ok", spaceId: task.spaceId }));
        } catch (error) {
          await fs.writeFile(cfg.resultPath, JSON.stringify({ status: "error", message: error.message || String(error) }));
        }
        """
        do {
            let res = try runMJS(script, prefix: "space", timeout: 35)
            return Self.parseResult(resultFile: resultFile, proc: res)
        } catch {
            return BrowserCollectResult(status: "error", message: error.localizedDescription)
        }
    }

    public func finishSpace(spaceId: Int? = nil) {
        guard isAvailable() else { return }
        let targetExpr: String
        if let sid = spaceId {
            targetExpr = String(sid)
        } else {
            targetExpr = JSONValue.string(spaceName).toJSONString()
        }
        let script = """
        try {
          const task = await taskSpace(\(targetExpr));
          await task.finish({ keep: [] });
        } catch (_err) {}
        """
        _ = try? runMJS(script, prefix: "finish", timeout: 30)
    }

    public func collectFeed(
        platform: String,
        knownIds: [String] = [],
        maxItems: Int = 30,
        handoff: Bool = true,
        keepOpen: Bool = false,
        backfill: Bool = false,
        spaceId: Int? = nil,
        collectsId: String = ""
    ) -> BrowserCollectResult {
        guard platform == "x_bookmarks" || platform == "douyin" else {
            return BrowserCollectResult(status: "error", message: "Unsupported platform: \(platform)")
        }
        guard isAvailable() else {
            return BrowserCollectResult(status: "unavailable", message: "ego-browser CLI not found")
        }

        let targetURL = platform == "x_bookmarks"
            ? "https://x.com/i/bookmarks"
            : "https://www.douyin.com/user/self?showTab=favorite_collection"

        let cleanKnown = knownIds.filter { !$0.isEmpty }
        let knownSlice = backfill ? cleanKnown : Array(cleanKnown.suffix(Self.incrementalKnownLimit))

        let outDir = workDir.appendingPathComponent("feed-\(platform)-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }

        let resultFile = outDir.appendingPathComponent("result.json")
        let cfgObj: JSONValue = .object([
            "spaceName": spaceId.map(JSONValue.int) ?? .string(spaceName),
            "targetUrl": .string(targetURL),
            "collectsId": .string(collectsId.trimmingCharacters(in: .whitespacesAndNewlines)),
            "knownIds": .array(knownSlice.map(JSONValue.string)),
            "maxItems": .int(max(1, maxItems)),
            "handoff": .bool(handoff),
            "keepOpen": .bool(keepOpen),
            "backfill": .bool(backfill),
        ])

        let script = Self.buildCollectionMJS(platform: platform, configJSON: cfgObj.toJSONString(), resultPath: resultFile.path)
        do {
            let res = try runMJS(script, prefix: "\(platform)-feed", timeout: 240)
            return Self.parseResult(resultFile: resultFile, proc: res)
        } catch {
            return BrowserCollectResult(status: "error", message: "\(platform) browser collection failed: \(error.localizedDescription)")
        }
    }

    public func collectXMonitor(
        handles: [String],
        knownIdsByHandle: [String: [String]],
        listURL: String = "",
        maxItemsPerUser: Int = 20,
        handoff: Bool = true,
        keepOpen: Bool = false
    ) -> BrowserCollectResult {
        guard isAvailable() else {
            return BrowserCollectResult(status: "unavailable", message: "ego-browser CLI not found")
        }
        let cleanHandles = handles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "@")).lowercased() }
            .filter { !$0.isEmpty }
        let cleanList = listURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanHandles.isEmpty && cleanList.isEmpty {
            return BrowserCollectResult(status: "ok", message: "无待采集的监控目标")
        }

        var normalizedKnown: [String: [String]] = [:]
        for (k, v) in knownIdsByHandle {
            let key = k.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "@")).lowercased()
            normalizedKnown[key] = Array(v.filter { !$0.isEmpty }.prefix(200))
        }

        let pagesPlan: [JSONValue]
        if !cleanList.isEmpty {
            var merged: [String] = []
            var seen = Set<String>()
            for ids in normalizedKnown.values {
                for id in ids where !seen.contains(id) {
                    seen.insert(id)
                    merged.append(id)
                }
            }
            let effectiveMultiplier = cleanHandles.isEmpty ? 2 : max(1, min(cleanHandles.count, 5))
            pagesPlan = [
                .object([
                    "label": .string("list"),
                    "url": .string(cleanList),
                    "knownIds": .array(Array(merged.prefix(500)).map(JSONValue.string)),
                    "maxItems": .int(max(25, maxItemsPerUser * effectiveMultiplier)),
                ])
            ]
        } else {
            pagesPlan = cleanHandles.map { h in
                .object([
                    "label": .string(h),
                    "url": .string("https://x.com/\(h)"),
                    "knownIds": .array((normalizedKnown[h] ?? []).map(JSONValue.string)),
                    "maxItems": .int(max(5, maxItemsPerUser)),
                ])
            }
        }

        let outDir = workDir.appendingPathComponent("xm-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }
        let resultFile = outDir.appendingPathComponent("result.json")

        let cfgObj: JSONValue = .object([
            "spaceName": .string(spaceName),
            "pagesPlan": .array(pagesPlan),
            "handoff": .bool(handoff),
            "keepOpen": .bool(keepOpen),
        ])
        let script = Self.buildXMonitorMJS(configJSON: cfgObj.toJSONString(), resultPath: resultFile.path)
        let timeoutSec = TimeInterval(max(180, min(600, 90 * max(1, pagesPlan.count))))
        do {
            let res = try runMJS(script, prefix: "xm-collect", timeout: timeoutSec)
            return Self.parseResult(resultFile: resultFile, proc: res)
        } catch {
            return BrowserCollectResult(status: "error", message: "X 监控浏览器采集失败: \(error.localizedDescription)")
        }
    }

    public func downloadMediaBatch(
        downloads: [BrowserDownloadItem],
        referer: String,
        spaceId: Int? = nil,
        finishWhenDone: Bool = false
    ) -> [String: String] {
        guard !downloads.isEmpty, isAvailable() else {
            if finishWhenDone, let sid = spaceId { finishSpace(spaceId: sid) }
            return [:]
        }

        var normalized: [JSONValue] = []
        for item in downloads {
            let u = item.url.trimmingCharacters(in: .whitespacesAndNewlines)
            let d = item.dest.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !u.isEmpty, !d.isEmpty else { continue }
            let destURL = URL(fileURLWithPath: d).standardizedFileURL
            try? FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            normalized.append(.object([
                "id": .string(item.id.isEmpty ? destURL.path : item.id),
                "url": .string(u),
                "dest": .string(destURL.path),
            ]))
        }
        guard !normalized.isEmpty else {
            if finishWhenDone, let sid = spaceId { finishSpace(spaceId: sid) }
            return [:]
        }

        let outDir = workDir.appendingPathComponent("dl-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }
        let resultFile = outDir.appendingPathComponent("downloads.json")

        let cfgObj: JSONValue = .object([
            "spaceId": spaceId.map(JSONValue.int) ?? .null,
            "spaceName": .string(spaceName),
            "referer": .string(referer),
            "downloads": .array(normalized),
            "finishWhenDone": .bool(finishWhenDone),
            "resultPath": .string(resultFile.path),
        ])

        let script = """
        const fs = await import("node:fs/promises");
        const CFG = \(cfgObj.toJSONString());

        const task = CFG.spaceId ? await taskSpace(CFG.spaceId) : await taskSpace(CFG.spaceName);
        const pages = await task.pages();
        let page = pages.length > 0 ? pages[0] : task.page("p1");
        for (const candidate of pages) {
          if ((await candidate.url()).includes(new URL(CFG.referer).hostname)) { page = candidate; break; }
        }

        const currentUrl = await page.url().catch(() => "");
        if (!currentUrl || currentUrl === "about:blank") {
          await page.goto(CFG.referer, { timeout: 30_000 }).catch(() => null);
        }

        const ua = await page.evaluate(() => navigator.userAgent).catch(() => "Mozilla/5.0");
        const succeeded = {};

        for (const item of CFG.downloads) {
          let ok = false;
          try {
            const res = await page.fetch(item.url, {
              saveAs: item.dest,
              timeout: 90_000,
            });
            if (res && res.ok) {
              const st = await fs.stat(item.dest).catch(() => null);
              if (st && st.size > 0) {
                succeeded[item.id] = item.dest;
                ok = true;
              }
            }
          } catch (_err) {
            ok = false;
          }

          if (!ok) {
            try {
              const cdpCookies = await page.cdp("Network.getCookies", {
                urls: [item.url, CFG.referer],
              }).catch(() => ({ cookies: [] }));
              const cookieHeader = (cdpCookies.cookies || [])
                .map((c) => `${c.name}=${c.value}`)
                .join("; ");
              const headers = { "User-Agent": ua, "Referer": CFG.referer };
              if (cookieHeader) headers["Cookie"] = cookieHeader;
              const resp = await fetch(item.url, { headers, redirect: "follow" });
              if (resp.ok) {
                const buf = Buffer.from(await resp.arrayBuffer());
                if (buf.length > 0) {
                  await fs.writeFile(item.dest, buf);
                  succeeded[item.id] = item.dest;
                }
              }
            } catch (_fallbackErr) {}
          }
        }

        if (CFG.finishWhenDone) {
          await task.finish({ keep: [] }).catch(() => null);
        }

        await fs.writeFile(CFG.resultPath, JSON.stringify({ succeeded }), "utf8");
        """

        do {
            _ = try runMJS(script, prefix: "dl", timeout: 360)
            if let data = try? Data(contentsOf: resultFile),
               let json = try? JSONValue.parse(data: data),
               let succ = json["succeeded"]?.objectValue {
                var out: [String: String] = [:]
                for (k, v) in succ {
                    if let s = v.stringValue, !s.isEmpty { out[k] = s }
                }
                return out
            }
        } catch {
            if finishWhenDone, let sid = spaceId { finishSpace(spaceId: sid) }
        }
        return [:]
    }

    private static func parseResult(resultFile: URL, proc: SubprocessResult) -> BrowserCollectResult {
        if FileManager.default.fileExists(atPath: resultFile.path) {
            do {
                let data = try Data(contentsOf: resultFile)
                let json = try JSONValue.parse(data: data)
                let domArr = (json["domItems"]?.arrayValue ?? []).compactMap { $0.objectValue }
                return BrowserCollectResult(
                    status: json["status"]?.stringValue ?? "ok",
                    payloads: json["payloads"]?.arrayValue ?? [],
                    domItems: domArr,
                    pageURL: json["pageUrl"]?.stringValue ?? "",
                    spaceId: json["spaceId"]?.intValue,
                    stoppedOnKnown: json["stoppedOnKnown"]?.boolValue ?? false,
                    message: json["message"]?.stringValue ?? ""
                )
            } catch {
                return BrowserCollectResult(status: "error", message: "Invalid ego-browser JSON output: \(error.localizedDescription)")
            }
        }
        let rawErr = (proc.stderr.isEmpty ? proc.stdout : proc.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        let msg = rawErr.isEmpty ? "exit code \(proc.exitCode)" : String(rawErr.prefix(260))
        return BrowserCollectResult(status: "error", message: "ego-browser produced no output: \(msg)")
    }

    private static func buildCollectionMJS(platform: String, configJSON: String, resultPath: String) -> String {
        let platLiteral = JSONValue.string(platform).toJSONString()
        let resLiteral = JSONValue.string(resultPath).toJSONString()
        return #"""
        const fs = await import("node:fs/promises");
        const CFG = \#(configJSON);
        const PLATFORM = \#(platLiteral);
        const RESULT_PATH = \#(resLiteral);

        const HOOK_SCRIPT = `
        (() => {
          if (window.__boCollectorInstalled) return;
          window.__boCollectorInstalled = true;
          window.__boPayloads = [];
          const shouldCapture = (url) => {
            if (!url || typeof url !== "string") return false;
            return (
              url.includes("/Bookmarks") ||
              url.includes("BookmarkTimeline") ||
              url.includes("/aweme/v1/web/aweme/listcollection") ||
              url.includes("/aweme/v1/web/collects/video/list") ||
              url.includes("/aweme/v1/web/collects/list")
            );
          };
          const recordPayload = (url, text) => {
            if (!text || typeof text !== "string") return;
            try {
              const parsed = JSON.parse(text);
              window.__boPayloads.push({ url, ts: Date.now(), data: parsed });
            } catch (_e) {}
          };

          const origFetch = window.fetch;
          if (typeof origFetch === "function") {
            window.fetch = async function(...args) {
              const resp = await origFetch.apply(this, args);
              try {
                const reqUrl = typeof args[0] === "string" ? args[0] : (args[0] && args[0].url) || "";
                if (shouldCapture(reqUrl) || shouldCapture(resp.url)) {
                  resp.clone().text().then((txt) => recordPayload(resp.url || reqUrl, txt)).catch(() => {});
                }
              } catch (_e) {}
              return resp;
            };
          }

          const origOpen = XMLHttpRequest.prototype.open;
          const origSend = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.open = function(method, url, ...rest) {
            this.__boUrl = typeof url === "string" ? url : String(url || "");
            return origOpen.call(this, method, url, ...rest);
          };
          XMLHttpRequest.prototype.send = function(...args) {
            this.addEventListener("load", function() {
              try {
                if (shouldCapture(this.__boUrl) || shouldCapture(this.responseURL)) {
                  const txt = typeof this.responseText === "string" ? this.responseText : "";
                  recordPayload(this.responseURL || this.__boUrl, txt);
                }
              } catch (_e) {}
            });
            return origSend.apply(this, args);
          };
        })();
        `;

        function extractIdsFromPayload(platform, body) {
          const ids = [];
          if (!body || typeof body !== "object") return ids;
          if (platform === "douyin") {
            const list = body.aweme_list || (body.data && body.data.aweme_list) || [];
            if (Array.isArray(list)) {
              for (const item of list) {
                if (item && item.aweme_id) ids.push(String(item.aweme_id));
              }
            }
            return ids;
          }
          const walk = (node) => {
            if (!node || typeof node !== "object") return;
            if (Array.isArray(node)) {
              for (const child of node) walk(child);
              return;
            }
            if (typeof node.entryId === "string" && node.entryId.startsWith("tweet-")) {
              ids.push(node.entryId.slice(6));
            } else if (!CFG.backfill && node.__typename === "Tweet" && node.rest_id && node.legacy) {
              ids.push(String(node.rest_id));
            }
            for (const val of Object.values(node)) {
              if (val && typeof val === "object") walk(val);
            }
          };
          walk(body);
          return [...new Set(ids)];
        }

        const sleepMs = (ms) => new Promise((r) => setTimeout(r, ms));
        const jitter = (min, max) => Math.floor(min + Math.random() * (max - min));
        const gotoWithRetry = async (page, url) => {
          try {
            await page.goto(url, { waitUntil: "domcontentloaded", timeout: 45_000 });
          } catch (firstErr) {
            const msg = (firstErr && firstErr.message) ? firstErr.message : String(firstErr);
            if (/ERR_TIMED_OUT|ERR_CONNECTION|ERR_NETWORK|ERR_PROXY|ERR_SSL|ERR_QUIC|Timeout/i.test(msg)) {
              await sleepMs(2500);
              await page.goto(url, { waitUntil: "domcontentloaded", timeout: 65_000 });
            } else {
              throw firstErr;
            }
          }
        };

        let task = null;
        try {
          task = await taskSpace(CFG.spaceName);
          const existingPages = await task.pages();
          let page = existingPages.length > 0 ? existingPages[0] : task.page("p1");
          if (CFG.backfill) {
            const host = new URL(CFG.targetUrl).hostname;
            let matched = null;
            for (const candidate of existingPages) {
              const url = await candidate.url();
              if (url.includes(host)) { matched = candidate; break; }
            }
            page = matched || (await page.url() === "about:blank" ? page : await task.newPage());
          }
          const resumed = CFG.backfill && (await page.url()).includes(new URL(CFG.targetUrl).hostname)
            && await page.evaluate(() => !!window.__boCollectorInstalled);

          await page.cdp("Network.enable", {}).catch(() => null);
          await page.cdp("Page.addScriptToEvaluateOnNewDocument", { source: HOOK_SCRIPT }).catch(() => null);

          if (!resumed) await page.events();
          if (!resumed) {
            await gotoWithRetry(page, CFG.targetUrl);
            await sleepMs(jitter(2800, 4200));
          }

          await page.evaluate(HOOK_SCRIPT).catch(() => null);

          const pageUrl = await page.url().catch(() => CFG.targetUrl);
          const loginCheck = await page.evaluate((plat) => {
            const href = location.href || "";
            const bodyText = (document.body && document.body.innerText) || "";
            if (plat === "x_bookmarks") {
              return href.includes("/i/flow/login") || href.includes("/login");
            }
            const hasCards = document.querySelectorAll("a[href*='/video/'], a[href*='/note/']").length > 0;
            if (!hasCards && (bodyText.includes("登录后即可查看") || bodyText.includes("验证码中间页") || bodyText.includes("完成安全验证"))) {
              return true;
            }
            return false;
          }, PLATFORM).catch(() => false);

          if (loginCheck) {
            if (CFG.handoff) {
              await task.handOff();
              await fs.writeFile(
                RESULT_PATH,
                JSON.stringify({
                  status: "handoff_required",
                  spaceId: task.spaceId,
                  pageUrl,
                  payloads: [],
                  domItems: [],
                  message: `检测到 ${PLATFORM} 需要登录或完成滑块验证，已将 ego-lite 窗口交还人工处理。`,
                }),
                "utf8"
              );
              process.exit(0);
            } else {
              await task.finish({ keep: [] }).catch(() => null);
              await fs.writeFile(
                RESULT_PATH,
                JSON.stringify({
                  status: "login_required",
                  spaceId: task.spaceId,
                  pageUrl,
                  payloads: [],
                  domItems: [],
                  message: `检测到 ${PLATFORM} 尚未在 ego-lite 登录或需要验证。`,
                }),
                "utf8"
              );
              process.exit(0);
            }
          }

          if (PLATFORM === "douyin" && !resumed) {
            await page.evaluate(() => {
              const tabs = [...document.querySelectorAll("[data-e2e*='collection'], [class*='tab'], span, div")];
              const favTab = tabs.find((el) => el.textContent && el.textContent.trim().startsWith("收藏") && el.children.length <= 2);
              if (favTab && typeof favTab.click === "function") favTab.click();
            }).catch(() => null);
            await sleepMs(jitter(1500, 2300));
            if (CFG.collectsId) {
              await page.evaluate((cid) => {
                const links = [...document.querySelectorAll("a, div, span")];
                const folder = links.find((el) => (el.getAttribute && (el.getAttribute("href") || "").includes(cid)) || (el.textContent && el.textContent.trim() === cid));
                if (folder && typeof folder.click === "function") folder.click();
              }, CFG.collectsId).catch(() => null);
              await sleepMs(jitter(1200, 1800));
            }
          }

          const knownSet = new Set(CFG.knownIds || []);
          const seenIds = new Set();
          const collectedPayloads = [];
          const seenReqIds = new Set();
          let stoppedOnKnown = false;

          const drainCaptured = async () => {
            const blocked = await page.evaluate(() => {
              const text = document.body?.innerText || "";
              return /验证码中间页|完成安全验证|拖动滑块|访问过于频繁|操作过于频繁|Rate limit exceeded|Verify you are human/.test(text)
                || /\/login|\/i\/flow\//.test(location.pathname);
            }).catch(() => false);
            if (blocked) {
              if (CFG.handoff) await task.handOff().catch(() => null);
              await fs.writeFile(
                RESULT_PATH,
                JSON.stringify({
                  status: "handoff_required",
                  spaceId: task.spaceId,
                  pageUrl: await page.url().catch(() => pageUrl),
                  payloads: [],
                  domItems: [],
                  message: `检测到 ${PLATFORM} 触发平台验证或限流，已暂停并交还窗口。`,
                }),
                "utf8"
              );
              process.exit(0);
            }

            const inPage = await page.evaluate(() => {
              return Array.isArray(window.__boPayloads) ? window.__boPayloads.splice(0) : [];
            }).catch(() => []);
            for (const item of inPage) {
              if (item && item.data) {
                collectedPayloads.push(item.data);
                for (const id of extractIdsFromPayload(PLATFORM, item.data)) {
                  if (knownSet.has(id) && !CFG.backfill) stoppedOnKnown = true;
                  if (!CFG.backfill || !knownSet.has(id)) seenIds.add(id);
                }
              }
            }

            const events = await page.events().catch(() => []);
            const pendingReqIds = [];
            for (const ev of events) {
              const method = ev && (ev.method || ev.name);
              const params = (ev && ev.params) || {};
              if (method === "Network.responseReceived") {
                const rUrl = (params.response && params.response.url) || "";
                const reqId = params.requestId;
                if (
                  reqId &&
                  !seenReqIds.has(reqId) &&
                  (rUrl.includes("/Bookmarks") ||
                    rUrl.includes("BookmarkTimeline") ||
                    rUrl.includes("/aweme/v1/web/aweme/listcollection") ||
                    rUrl.includes("/aweme/v1/web/collects/video/list"))
                ) {
                  if ([401, 403, 429].includes(params.response.status)) {
                    if (CFG.handoff) await task.handOff().catch(() => null);
                    await fs.writeFile(
                      RESULT_PATH,
                      JSON.stringify({
                        status: "handoff_required",
                        spaceId: task.spaceId,
                        pageUrl: await page.url().catch(() => pageUrl),
                        payloads: [],
                        domItems: [],
                        message: `平台接口返回 HTTP ${params.response.status}，已暂停采集等待人工检查。`,
                      }),
                      "utf8"
                    );
                    process.exit(0);
                  }
                  seenReqIds.add(reqId);
                  pendingReqIds.push(reqId);
                }
              }
            }
            for (const reqId of pendingReqIds) {
              const bodyRes = await page.cdp("Network.getResponseBody", { requestId: reqId }).catch(() => null);
              if (bodyRes && bodyRes.body) {
                try {
                  const rawStr = bodyRes.base64Encoded
                    ? Buffer.from(bodyRes.body, "base64").toString("utf8")
                    : bodyRes.body;
                  const parsed = JSON.parse(rawStr);
                  collectedPayloads.push(parsed);
                  for (const id of extractIdsFromPayload(PLATFORM, parsed)) {
                    if (knownSet.has(id) && !CFG.backfill) stoppedOnKnown = true;
                    if (!CFG.backfill || !knownSet.has(id)) seenIds.add(id);
                  }
                } catch (_e) {}
              }
            }
          };

          await drainCaptured();
          await page.mouse.move(540, 440, { label: "focus collection feed" }).catch(() => null);

          let idleRounds = 0;
          const maxScrollRounds = CFG.backfill ? 15 : Math.min(25, Math.max(4, Math.ceil(CFG.maxItems / 8) + 2));
          for (let round = 0; round < maxScrollRounds; round++) {
            if (stoppedOnKnown || seenIds.size >= CFG.maxItems) break;
            const prevCount = seenIds.size;
            await page.mouse.wheel(0, jitter(650, 950), { label: "scroll collection feed" }).catch(() => null);
            await sleepMs(jitter(1600, 2800));
            await drainCaptured();
            if (seenIds.size === prevCount) {
              idleRounds += 1;
              if (idleRounds >= (CFG.backfill ? 8 : 3)) break;
            } else {
              idleRounds = 0;
            }
          }

          const domItems = await page.evaluate((plat) => {
            if (plat === "x_bookmarks") {
              const articles = [...document.querySelectorAll('article[data-testid="tweet"]')];
              return articles.map((art) => {
                const statusLink = [...art.querySelectorAll('a[href*="/status/"]')].find((a) =>
                  /\/status\/\d+/.test(a.getAttribute("href") || "")
                );
                const href = statusLink ? statusLink.getAttribute("href") : "";
                const m = href ? href.match(/\/([^/]+)\/status\/(\d+)/) : null;
                const textNode = art.querySelector('[data-testid="tweetText"]');
                const timeNode = art.querySelector("time");
                const imgs = [...art.querySelectorAll('[data-testid="tweetPhoto"] img')]
                  .map((img) => img.src)
                  .filter(Boolean);
                return {
                  id: m ? m[2] : "",
                  handle: m ? m[1] : "",
                  url: href ? new URL(href, location.origin).href : "",
                  text: textNode ? textNode.innerText : art.innerText,
                  publishedAt: timeNode ? timeNode.getAttribute("datetime") : null,
                  images: imgs,
                };
              }).filter((x) => x.id);
            }
            const cards = [...document.querySelectorAll('a[href*="/video/"], a[href*="/note/"]')];
            const out = [];
            const seen = new Set();
            for (const a of cards) {
              const href = a.getAttribute("href") || "";
              const m = href.match(/\/(video|note)\/(\d+)/);
              if (!m || seen.has(m[2])) continue;
              seen.add(m[2]);
              out.push({
                id: m[2],
                kind: m[1],
                url: new URL(href, "https://www.douyin.com").href,
                title: (a.innerText || "").trim(),
              });
            }
            return out;
          }, PLATFORM).catch(() => []);

          const finalSpaceId = task.spaceId;
          if (!CFG.keepOpen) {
            await task.finish({ keep: [] }).catch(() => null);
          }

          await fs.writeFile(
            RESULT_PATH,
            JSON.stringify({
              status: "ok",
              spaceId: finalSpaceId,
              pageUrl,
              stoppedOnKnown,
              payloads: collectedPayloads,
              domItems,
              message: `captured ${collectedPayloads.length} payloads, ${seenIds.size || domItems.length} items`,
            }),
            "utf8"
          );
        } catch (err) {
          if (task && !CFG.keepOpen) {
            await task.finish({ keep: [] }).catch(() => null);
          }
          await fs.writeFile(
            RESULT_PATH,
            JSON.stringify({
              status: "error",
              spaceId: task ? task.spaceId : null,
              pageUrl: "",
              stoppedOnKnown: false,
              payloads: [],
              domItems: [],
              message: err && err.message ? err.message : String(err),
            }),
            "utf8"
          );
        }
        """#
    }

    private static func buildXMonitorMJS(configJSON: String, resultPath: String) -> String {
        let resLiteral = JSONValue.string(resultPath).toJSONString()
        return #"""
        const fs = await import("node:fs/promises");
        const CFG = \#(configJSON);
        const RESULT_PATH = \#(resLiteral);

        const HOOK_SCRIPT = `
        (() => {
          if (window.__boMonitorInstalled) return;
          window.__boMonitorInstalled = true;
          window.__boMonitorPayloads = [];
          const shouldCapture = (url) => {
            if (!url || typeof url !== "string") return false;
            return url.includes("/UserTweets") || url.includes("ListLatestTweetsTimeline");
          };
          const recordPayload = (url, text) => {
            if (!text || typeof text !== "string") return;
            try {
              const parsed = JSON.parse(text);
              window.__boMonitorPayloads.push({ url, ts: Date.now(), data: parsed });
            } catch (_e) {}
          };

          const origFetch = window.fetch;
          if (typeof origFetch === "function") {
            window.fetch = async function(...args) {
              const resp = await origFetch.apply(this, args);
              try {
                const reqUrl = typeof args[0] === "string" ? args[0] : (args[0] && args[0].url) || "";
                if (shouldCapture(reqUrl) || shouldCapture(resp.url)) {
                  resp.clone().text().then((txt) => recordPayload(resp.url || reqUrl, txt)).catch(() => {});
                }
              } catch (_e) {}
              return resp;
            };
          }

          const origOpen = XMLHttpRequest.prototype.open;
          const origSend = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.open = function(method, url, ...rest) {
            this.__boMonUrl = typeof url === "string" ? url : String(url || "");
            return origOpen.call(this, method, url, ...rest);
          };
          XMLHttpRequest.prototype.send = function(...args) {
            this.addEventListener("load", function() {
              try {
                if (shouldCapture(this.__boMonUrl) || shouldCapture(this.responseURL)) {
                  const txt = typeof this.responseText === "string" ? this.responseText : "";
                  recordPayload(this.responseURL || this.__boMonUrl, txt);
                }
              } catch (_e) {}
            });
            return origSend.apply(this, args);
          };
        })();
        `;

        function extractNonPinnedIds(body) {
          const ids = [];
          if (!body || typeof body !== "object") return ids;
          const walk = (node) => {
            if (!node || typeof node !== "object") return;
            if (Array.isArray(node)) {
              for (const child of node) walk(child);
              return;
            }
            if (node.type === "TimelinePinEntry") return;
            if (typeof node.entryId === "string") {
              if (node.entryId.startsWith("promoted-") || node.entryId.startsWith("who-to-follow-")) return;
              const itemContent = node.content && node.content.itemContent;
              if (itemContent && itemContent.promotedMetadata) return;
              if (node.entryId.startsWith("tweet-")) {
                ids.push(node.entryId.slice(6));
                return;
              }
            }
            for (const val of Object.values(node)) {
              if (val && typeof val === "object") walk(val);
            }
          };
          walk(body);
          return [...new Set(ids)];
        }

        const sleepMs = (ms) => new Promise((r) => setTimeout(r, ms));
        const jitter = (min, max) => Math.floor(min + Math.random() * (max - min));
        const gotoWithRetry = async (page, url) => {
          try {
            await page.goto(url, { waitUntil: "domcontentloaded", timeout: 45_000 });
          } catch (firstErr) {
            const msg = (firstErr && firstErr.message) ? firstErr.message : String(firstErr);
            if (/ERR_TIMED_OUT|ERR_CONNECTION|ERR_NETWORK|ERR_PROXY|ERR_SSL|ERR_QUIC|Timeout/i.test(msg)) {
              await sleepMs(2500);
              await page.goto(url, { waitUntil: "domcontentloaded", timeout: 65_000 });
            } else {
              throw firstErr;
            }
          }
        };

        let task = null;
        try {
          task = await taskSpace(CFG.spaceName);
          const existingPages = await task.pages();
          const page = existingPages.length > 0 ? existingPages[0] : task.page("p1");

          await page.cdp("Network.enable", {}).catch(() => null);
          await page.cdp("Page.addScriptToEvaluateOnNewDocument", { source: HOOK_SCRIPT }).catch(() => null);
          await page.events().catch(() => null);

          const allPayloads = [];
          const allDomItems = [];
          const seenReqIds = new Set();
          let anyStoppedOnKnown = false;
          let lastPageUrl = "";

          for (let idx = 0; idx < CFG.pagesPlan.length; idx++) {
            const target = CFG.pagesPlan[idx];
            await gotoWithRetry(page, target.url);
            await sleepMs(jitter(2800, 4200));
            await page.evaluate(HOOK_SCRIPT).catch(() => null);

            lastPageUrl = await page.url().catch(() => target.url);
            const loginNeeded = await page.evaluate(() => {
              const href = location.href || "";
              const text = document.body?.innerText || "";
              return href.includes("/i/flow/login") || href.includes("/login")
                || /Rate limit exceeded|Verify you are human/.test(text);
            }).catch(() => false);

            if (loginNeeded) {
              if (CFG.handoff) {
                await task.handOff();
                await fs.writeFile(
                  RESULT_PATH,
                  JSON.stringify({
                    status: "handoff_required",
                    spaceId: task.spaceId,
                    pageUrl: lastPageUrl,
                    payloads: [],
                    domItems: [],
                    message: "检测到需要登录 X 账号或限流验证，已将 ego-lite 窗口交还人工处理。",
                  }),
                  "utf8"
                );
                process.exit(0);
              } else {
                await task.finish({ keep: [] }).catch(() => null);
                await fs.writeFile(
                  RESULT_PATH,
                  JSON.stringify({
                    status: "login_required",
                    spaceId: task.spaceId,
                    pageUrl: lastPageUrl,
                    payloads: [],
                    domItems: [],
                    message: "检测到尚未在 ego-lite 登录 X 账号。",
                  }),
                  "utf8"
                );
                process.exit(0);
              }
            }

            const knownSet = new Set(target.knownIds || []);
            const targetSeenIds = new Set();
            let stoppedOnKnown = false;

            const drainTarget = async () => {
              const inPage = await page.evaluate(() => {
                return Array.isArray(window.__boMonitorPayloads) ? window.__boMonitorPayloads.splice(0) : [];
              }).catch(() => []);
              for (const item of inPage) {
                if (item && item.data) {
                  allPayloads.push(item.data);
                  for (const id of extractNonPinnedIds(item.data)) {
                    if (knownSet.has(id)) stoppedOnKnown = true;
                    targetSeenIds.add(id);
                  }
                }
              }

              const events = await page.events().catch(() => []);
              const pendingReqIds = [];
              for (const ev of events) {
                const method = ev && (ev.method || ev.name);
                const params = (ev && ev.params) || {};
                if (method === "Network.responseReceived") {
                  const rUrl = (params.response && params.response.url) || "";
                  const reqId = params.requestId;
                  if (reqId && !seenReqIds.has(reqId) && (rUrl.includes("/UserTweets") || rUrl.includes("ListLatestTweetsTimeline"))) {
                    seenReqIds.add(reqId);
                    pendingReqIds.push(reqId);
                  }
                }
              }
              for (const reqId of pendingReqIds) {
                const bodyRes = await page.cdp("Network.getResponseBody", { requestId: reqId }).catch(() => null);
                if (bodyRes && bodyRes.body) {
                  try {
                    const rawStr = bodyRes.base64Encoded
                      ? Buffer.from(bodyRes.body, "base64").toString("utf8")
                      : bodyRes.body;
                    const parsed = JSON.parse(rawStr);
                    allPayloads.push(parsed);
                    for (const id of extractNonPinnedIds(parsed)) {
                      if (knownSet.has(id)) stoppedOnKnown = true;
                      targetSeenIds.add(id);
                    }
                  } catch (_e) {}
                }
              }
            };

            await drainTarget();
            await page.mouse.move(540, 440, { label: "focus timeline feed" }).catch(() => null);

            let idleRounds = 0;
            const maxRounds = Math.min(18, Math.max(3, Math.ceil((target.maxItems || 20) / 8) + 2));
            for (let round = 0; round < maxRounds; round++) {
              if (stoppedOnKnown || targetSeenIds.size >= (target.maxItems || 20)) break;
              const prev = targetSeenIds.size;
              await page.mouse.wheel(0, jitter(650, 950), { label: "scroll x timeline" }).catch(() => null);
              await sleepMs(jitter(1600, 2800));
              await drainTarget();
              if (targetSeenIds.size === prev) {
                idleRounds += 1;
                if (idleRounds >= 2) break;
              } else {
                idleRounds = 0;
              }
            }

            if (stoppedOnKnown) anyStoppedOnKnown = true;

            const domOnPage = await page.evaluate(() => {
              const articles = [...document.querySelectorAll('article[data-testid="tweet"]')];
              return articles.map((art) => {
                const socialCtx = (art.querySelector('[data-testid="socialContext"]')?.innerText || "").trim();
                const isPinned = /pinned|置顶/i.test(socialCtx);
                const isRetweet = /reposted|转帖|转推/i.test(socialCtx);
                const statusLink = [...art.querySelectorAll('a[href*="/status/"]')].find((a) =>
                  /\/status\/\d+/.test(a.getAttribute("href") || "")
                );
                const href = statusLink ? statusLink.getAttribute("href") : "";
                const m = href ? href.match(/\/([^/]+)\/status\/(\d+)/) : null;
                const textNode = art.querySelector('[data-testid="tweetText"]');
                const timeNode = art.querySelector("time");
                const imgs = [...art.querySelectorAll('[data-testid="tweetPhoto"] img')]
                  .map((img) => img.src)
                  .filter(Boolean);
                return {
                  id: m ? m[2] : "",
                  handle: m ? m[1] : "",
                  url: href ? new URL(href, location.origin).href : "",
                  text: textNode ? textNode.innerText : "",
                  publishedAt: timeNode ? timeNode.getAttribute("datetime") : null,
                  images: imgs,
                  isPinned,
                  isRetweet,
                };
              }).filter((x) => x.id);
            }).catch(() => []);
            allDomItems.push(...domOnPage);

            if (idx + 1 < CFG.pagesPlan.length) {
              await sleepMs(jitter(1800, 3200));
            }
          }

          const finalSpaceId = task.spaceId;
          if (!CFG.keepOpen) {
            await task.finish({ keep: [] }).catch(() => null);
          }

          await fs.writeFile(
            RESULT_PATH,
            JSON.stringify({
              status: "ok",
              spaceId: finalSpaceId,
              pageUrl: lastPageUrl,
              stoppedOnKnown: anyStoppedOnKnown,
              payloads: allPayloads,
              domItems: allDomItems,
              message: `X 监控采集完成：捕获 ${allPayloads.length} 个数据包`,
            }),
            "utf8"
          );
        } catch (err) {
          if (task && !CFG.keepOpen) {
            await task.finish({ keep: [] }).catch(() => null);
          }
          await fs.writeFile(
            RESULT_PATH,
            JSON.stringify({
              status: "error",
              spaceId: task ? task.spaceId : null,
              pageUrl: "",
              stoppedOnKnown: false,
              payloads: [],
              domItems: [],
              message: err && err.message ? err.message : String(err),
            }),
            "utf8"
          );
        }
        """#
    }

    public func extractReadableArticle(url: String, handoff: Bool = false) -> BrowserArticleExtractResult {
        let targetURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetURL.isEmpty, targetURL.hasPrefix("http://") || targetURL.hasPrefix("https://") else {
            return BrowserArticleExtractResult(status: "error", message: "Invalid article URL")
        }
        guard isAvailable() else {
            return BrowserArticleExtractResult(status: "unavailable", message: "ego-browser CLI not found")
        }

        let outDir = workDir.appendingPathComponent("refetch-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }

        let resultFile = outDir.appendingPathComponent("article.json")
        let cfgObj: JSONValue = .object([
            "spaceName": .string("\(spaceName)-refetch"),
            "targetUrl": .string(targetURL),
            "handoff": .bool(handoff),
        ])
        let script = Self.buildReadableArticleMJS(configJSON: cfgObj.toJSONString(), resultPath: resultFile.path)

        do {
            let proc = try runMJS(script, prefix: "rss-refetch", timeout: 45)
            if FileManager.default.fileExists(atPath: resultFile.path),
               let data = try? Data(contentsOf: resultFile),
               let json = try? JSONValue.parse(data: data) {
                return BrowserArticleExtractResult(
                    status: json["status"]?.stringValue ?? "error",
                    title: json["title"]?.stringValue ?? "",
                    markdown: json["markdown"]?.stringValue ?? "",
                    finalURL: json["finalUrl"]?.stringValue ?? targetURL,
                    message: json["message"]?.stringValue ?? ""
                )
            }
            let errText = (proc.stderr.isEmpty ? proc.stdout : proc.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            return BrowserArticleExtractResult(status: "error", message: errText.isEmpty ? "ego-browser returned empty output" : errText)
        } catch {
            return BrowserArticleExtractResult(status: "error", message: error.localizedDescription)
        }
    }

    private static func buildReadableArticleMJS(configJSON: String, resultPath: String) -> String {
        let escapedResultPath = JSONValue.string(resultPath).toJSONString()
        return """
        const fs = await import("node:fs/promises");
        const CFG = \(configJSON);
        const RESULT_PATH = \(escapedResultPath);
        const sleepMs = (ms) => new Promise((r) => setTimeout(r, ms));
        let task = null;
        try {
          task = await taskSpace(CFG.spaceName);
          const page = await task.open(CFG.targetUrl);
          await sleepMs(2200);

          const extracted = await page.evaluate(() => {
            const rawHtml = document.documentElement ? document.documentElement.innerHTML : "";
            const bodyText = (document.body && document.body.innerText ? document.body.innerText : "").trim();
            const lowerHtml = rawHtml.toLowerCase();
            const lowerTxt = bodyText.toLowerCase();

            const hasCaptchaWidget =
              lowerHtml.includes("cf-turnstile") ||
              lowerHtml.includes("g-recaptcha") ||
              lowerHtml.includes("hcaptcha");
            const isInterstitial =
              (hasCaptchaWidget && bodyText.length < 800) ||
              (bodyText.length < 1000 && (
                (bodyText.includes("环境异常") && bodyText.includes("验证")) ||
                lowerTxt.includes("just a moment...") ||
                lowerTxt.includes("enable javascript and cookies to continue") ||
                lowerTxt.includes("verify you are human")
              ));

            if (isInterstitial) {
              return { blocked: true, title: document.title || "", markdown: "", finalUrl: location.href };
            }

            const selectors = [
              "#js_content",
              "article",
              "[role='main']",
              "main",
              ".rich_media_content",
              ".post-content",
              ".entry-content",
              ".article-content",
              ".markdown-body",
            ];
            let root = null;
            for (const sel of selectors) {
              const el = document.querySelector(sel);
              if (el && (el.innerText || "").trim().length >= 120) {
                root = el;
                break;
              }
            }
            if (!root) root = document.body || document.documentElement;

            const skipTags = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "SVG", "NAV", "HEADER", "FOOTER", "ASIDE", "FORM", "IFRAME"]);
            const toAbs = (raw) => {
              if (!raw) return "";
              try { return new URL(raw, location.href).href; } catch (_e) { return raw; }
            };

            const walkInline = (node) => {
              if (!node) return "";
              if (node.nodeType === Node.TEXT_NODE) {
                return (node.nodeValue || "").replace(/\\s+/g, " ");
              }
              if (node.nodeType !== Node.ELEMENT_NODE) return "";
              const tag = node.tagName.toUpperCase();
              if (skipTags.has(tag)) return "";
              if (tag === "BR") return "\\n";
              if (tag === "IMG") {
                const src = toAbs(node.getAttribute("data-src") || node.getAttribute("data-original") || node.getAttribute("src") || "");
                if (!src || src.startsWith("data:")) return "";
                const alt = (node.getAttribute("alt") || "").trim();
                return `![${alt}](${src})`;
              }
              const inner = [...node.childNodes].map(walkInline).join("");
              if (tag === "CODE") return inner.trim() ? `\\`${inner.trim()}\\`` : "";
              if (tag === "STRONG" || tag === "B") return inner.trim() ? `**${inner.trim()}**` : "";
              if (tag === "EM" || tag === "I") return inner.trim() ? `*${inner.trim()}*` : "";
              if (tag === "A") {
                const href = toAbs(node.getAttribute("href") || "");
                const label = inner.trim() || href;
                return href && !href.startsWith("javascript:") ? `[${label}](${href})` : label;
              }
              return inner;
            };

            const blocks = [];
            const walkBlock = (node) => {
              if (!node) return;
              if (node.nodeType === Node.TEXT_NODE) {
                const t = (node.nodeValue || "").trim();
                if (t) blocks.push(t);
                return;
              }
              if (node.nodeType !== Node.ELEMENT_NODE) return;
              const tag = node.tagName.toUpperCase();
              if (skipTags.has(tag)) return;

              if (/^H[1-6]$/.test(tag)) {
                const lvl = Number(tag.slice(1));
                const txt = walkInline(node).trim();
                if (txt) blocks.push(`${"#".repeat(lvl)} ${txt}`);
                return;
              }
              if (tag === "PRE") {
                const codeText = (node.innerText || "").replace(/\\n+$/, "");
                if (codeText.trim()) blocks.push("```\\n" + codeText + "\\n```");
                return;
              }
              if (tag === "BLOCKQUOTE") {
                const q = (node.innerText || "").trim();
                if (q) blocks.push(q.split("\\n").map((l) => `> ${l}`).join("\\n"));
                return;
              }
              if (tag === "UL" || tag === "OL") {
                const items = [...node.children].filter((c) => c.tagName && c.tagName.toUpperCase() === "LI");
                const lines = items.map((li, i) => {
                  const txt = walkInline(li).trim();
                  return txt ? `${tag === "OL" ? `${i + 1}.` : "-"} ${txt}` : "";
                }).filter(Boolean);
                if (lines.length) blocks.push(lines.join("\\n"));
                return;
              }
              if (tag === "IMG") {
                const mdImg = walkInline(node).trim();
                if (mdImg) blocks.push(mdImg);
                return;
              }
              if (tag === "P") {
                const txt = walkInline(node).trim();
                if (txt) blocks.push(txt);
                return;
              }
              const hasBlockChild = [...node.children].some((c) =>
                c.tagName && ["DIV", "SECTION", "ARTICLE", "MAIN", "P", "PRE", "UL", "OL", "BLOCKQUOTE", "H1", "H2", "H3", "H4", "H5", "H6", "FIGURE"].includes(c.tagName.toUpperCase())
              );
              if (hasBlockChild) {
                for (const child of node.childNodes) walkBlock(child);
              } else {
                const txt = walkInline(node).trim();
                if (txt) blocks.push(txt);
              }
            };

            walkBlock(root);
            const titleEl = document.querySelector("#activity-name, h1");
            const pageTitle = (titleEl && titleEl.innerText ? titleEl.innerText : document.title || "").trim();
            return {
              blocked: false,
              title: pageTitle,
              markdown: blocks.join("\\n\\n").replace(/\\n{3,}/g, "\\n\\n").trim(),
              finalUrl: location.href,
            };
          });

          await task.finish({ keep: [] }).catch(() => null);
          task = null;

          if (extracted && extracted.blocked) {
            await fs.writeFile(
              RESULT_PATH,
              JSON.stringify({
                status: "interstitial_blocked",
                title: extracted.title || "",
                markdown: "",
                finalUrl: extracted.finalUrl || CFG.targetUrl,
                message: "Origin page gated by verification interstitial",
              }),
              "utf8"
            );
          } else {
            await fs.writeFile(
              RESULT_PATH,
              JSON.stringify({
                status: "ok",
                title: (extracted && extracted.title) || "",
                markdown: (extracted && extracted.markdown) || "",
                finalUrl: (extracted && extracted.finalUrl) || CFG.targetUrl,
                message: "ok",
              }),
              "utf8"
            );
          }
        } catch (err) {
          if (task) {
            await task.finish({ keep: [] }).catch(() => null);
          }
          await fs.writeFile(
            RESULT_PATH,
            JSON.stringify({
              status: "error",
              title: "",
              markdown: "",
              finalUrl: CFG.targetUrl,
              message: err && err.message ? err.message : String(err),
            }),
            "utf8"
          );
        }
        """
    }
}
