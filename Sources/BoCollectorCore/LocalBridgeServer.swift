import Foundation
import Network

/// Native lightweight HTTP/1.1 bridge server on 127.0.0.1:18765 for L2 Tampermonkey companion capture.
public final class LocalBridgeServer: @unchecked Sendable {
    public static let allowedOrigins: Set<String> = [
        "https://x.com",
        "https://twitter.com",
        "https://www.douyin.com",
        "http://localhost:5173",
        "http://127.0.0.1:5173",
    ]
    public static let maxRequestBytes = 25 * 1024 * 1024 // 25 MB

    private let queue = DispatchQueue(label: "com.bo.collector.bridge", qos: .userInitiated)
    private let configProvider: @Sendable () -> CollectorConfig
    private let logger: SafeLogger
    private let ingestHandler: (@Sendable (String, [JSONValue], [[String: JSONValue]]?, String, Bool) throws -> [String: JSONValue])?

    private var listener: NWListener?
    private let stateLock = NSLock()
    private var _isRunning = false
    private var _listeningPort: UInt16 = 0
    private var _lastError: String?

    public var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isRunning
    }

    public var listeningPort: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Int(_listeningPort)
    }

    public var lastError: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _lastError
    }

    public init(
        configProvider: @escaping @Sendable () -> CollectorConfig,
        logger: SafeLogger,
        ingestHandler: (@Sendable (String, [JSONValue], [[String: JSONValue]]?, String, Bool) throws -> [String: JSONValue])? = nil
    ) {
        self.configProvider = configProvider
        self.logger = logger
        self.ingestHandler = ingestHandler
    }

    public func start(portOverride: UInt16? = nil) throws {
        stop()
        let cfg = configProvider()
        let rawPort = portOverride ?? UInt16(clamping: cfg.bridgePort)
        let nwPort: NWEndpoint.Port = rawPort == 0 ? .any : NWEndpoint.Port(rawValue: rawPort)!

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let host = cfg.bridgeHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if host == "127.0.0.1" || host == "localhost" {
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        }

        let newListener = try NWListener(using: params)
        let readySem = DispatchSemaphore(value: 0)
        let errBox = ResultBox<Error>()

        newListener.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.stateLock.lock()
                self._isRunning = true
                self._listeningPort = newListener.port?.rawValue ?? rawPort
                self._lastError = nil
                self.stateLock.unlock()
                readySem.signal()
            case .failed(let error):
                self.stateLock.lock()
                self._isRunning = false
                self._lastError = error.localizedDescription
                self.stateLock.unlock()
                errBox.value = error
                readySem.signal()
            case .cancelled:
                self.stateLock.lock()
                self._isRunning = false
                self.stateLock.unlock()
            default:
                break
            }
        }

        newListener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }

        self.listener = newListener
        newListener.start(queue: queue)
        _ = readySem.wait(timeout: .now() + 5.0)
        if let err = errBox.value {
            stop()
            throw err
        }
        logger.info("L2 油猴本地桥接已启动: http://127.0.0.1:\(listeningPort)")
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        stateLock.lock()
        _isRunning = false
        _listeningPort = 0
        stateLock.unlock()
    }

    // MARK: - HTTP/1.1 Connection & Routing

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        var buffer = Data()

        func receiveLoop() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self else {
                    conn.cancel()
                    return
                }
                if let data, !data.isEmpty {
                    buffer.append(data)
                }
                if buffer.count > Self.maxRequestBytes {
                    self.sendResponse(conn: conn, statusCode: 413, contentType: "application/json; charset=utf-8", origin: nil, body: Data("{\"detail\":\"Payload too large\"}".utf8))
                    return
                }
                if let parsed = Self.tryParseHTTPRequest(from: buffer) {
                    DispatchQueue.global(qos: .userInitiated).async {
                        let resp = self.routeRequest(parsed)
                        self.sendResponse(
                            conn: conn,
                            statusCode: resp.statusCode,
                            contentType: resp.contentType,
                            origin: parsed.headers["origin"],
                            body: resp.body
                        )
                    }
                    return
                }
                if isComplete || error != nil {
                    conn.cancel()
                    return
                }
                receiveLoop()
            }
        }
        receiveLoop()
    }

    public struct ParsedHTTPRequest: Sendable {
        public let method: String
        public let path: String
        public let headers: [String: String]
        public let body: Data
    }

    public struct BridgeHTTPResponse: Sendable {
        public let statusCode: Int
        public let contentType: String
        public let body: Data
    }

    public static func tryParseHTTPRequest(from buffer: Data) -> ParsedHTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEndRange = buffer.range(of: separator) else {
            return nil
        }
        let headerData = buffer.subdata(in: 0..<headerEndRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return nil
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let reqParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard reqParts.count >= 2 else { return nil }

        let method = reqParts[0].uppercased()
        let rawTarget = reqParts[1]
        let pathOnly = rawTarget.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawTarget

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[k] = v
        }

        let bodyStart = headerEndRange.upperBound
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        if buffer.count - bodyStart < contentLength {
            return nil
        }
        let body = contentLength > 0 ? buffer.subdata(in: bodyStart..<(bodyStart + contentLength)) : Data()
        return ParsedHTTPRequest(method: method, path: pathOnly, headers: headers, body: body)
    }

    public func routeRequest(_ req: ParsedHTTPRequest) -> BridgeHTTPResponse {
        if req.method == "OPTIONS" {
            return BridgeHTTPResponse(statusCode: 204, contentType: "text/plain; charset=utf-8", body: Data())
        }

        let cfg = configProvider()
        if req.method == "GET" && (req.path == "/healthz" || req.path == "/") {
            let payload: JSONValue = .object([
                "status": .string("ok"),
                "mode": .string("local_bridge"),
                "app": .string("BoCollector"),
            ])
            return BridgeHTTPResponse(statusCode: 200, contentType: "application/json; charset=utf-8", body: (try? payload.toData()) ?? Data())
        }

        if req.method == "GET" && req.path == "/api/ingest/userscript.user.js" {
            let port = listeningPort > 0 ? listeningPort : cfg.bridgePort
            let script = Self.userscriptSource(defaultPort: port)
            return BridgeHTTPResponse(statusCode: 200, contentType: "application/javascript; charset=utf-8", body: Data(script.utf8))
        }

        if req.method == "POST" && req.path == "/api/ingest/raw" {
            let expectedToken = cfg.bridgeToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !expectedToken.isEmpty {
                let authHeader = req.headers["authorization"] ?? ""
                if authHeader != "Bearer \(expectedToken)" {
                    let err = Data("{\"detail\":\"Invalid bridge Bearer token\"}".utf8)
                    return BridgeHTTPResponse(statusCode: 401, contentType: "application/json; charset=utf-8", body: err)
                }
            }

            do {
                let json = try JSONValue.parse(data: req.body)
                let sourceType = (json["source_type"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard let payloads = json["payloads"]?.arrayValue else {
                    let err = Data("{\"detail\":\"payloads 必须为数组\"}".utf8)
                    return BridgeHTTPResponse(statusCode: 422, contentType: "application/json; charset=utf-8", body: err)
                }
                let domItems = json["dom_items"]?.arrayValue?.compactMap(\.objectValue)
                let sourceName = json["source_name"]?.stringValue ?? ""
                let clean = json["clean"]?.boolValue ?? true

                let resultObj: [String: JSONValue]
                if let customHandler = ingestHandler {
                    resultObj = try customHandler(sourceType, payloads, domItems, sourceName, clean)
                } else {
                    let engine = SyncEngine(config: cfg, logger: logger)
                    defer { engine.close() }
                    resultObj = try engine.ingestRawPayloads(
                        sourceType: sourceType,
                        payloads: payloads,
                        domItems: domItems,
                        sourceName: sourceName,
                        clean: clean
                    )
                }
                let outData = try JSONValue.object(resultObj).toData()
                return BridgeHTTPResponse(statusCode: 200, contentType: "application/json; charset=utf-8", body: outData)
            } catch {
                let detail = ErrorSanitizer.sanitizeDetail(error.localizedDescription)
                let errJSON: JSONValue = .object(["detail": .string(detail)])
                return BridgeHTTPResponse(statusCode: 500, contentType: "application/json; charset=utf-8", body: (try? errJSON.toData()) ?? Data())
            }
        }

        return BridgeHTTPResponse(statusCode: 404, contentType: "application/json; charset=utf-8", body: Data("{\"detail\":\"Not Found\"}".utf8))
    }

    private func sendResponse(conn: NWConnection, statusCode: Int, contentType: String, origin: String?, body: Data) {
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 204: statusText = "No Content"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        case 413: statusText = "Payload Too Large"
        case 422: statusText = "Unprocessable Entity"
        default: statusText = "Internal Server Error"
        }

        var headerLines = [
            "HTTP/1.1 \(statusCode) \(statusText)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Connection: close",
        ]
        if let orig = origin, Self.allowedOrigins.contains(orig) {
            headerLines.append("Access-Control-Allow-Origin: \(orig)")
            headerLines.append("Access-Control-Allow-Methods: GET, POST, OPTIONS")
            headerLines.append("Access-Control-Allow-Headers: Content-Type, Authorization")
            headerLines.append("Access-Control-Allow-Private-Network: true")
            headerLines.append("Vary: Origin")
        } else {
            headerLines.append("Access-Control-Allow-Origin: *")
            headerLines.append("Access-Control-Allow-Methods: GET, POST, OPTIONS")
            headerLines.append("Access-Control-Allow-Headers: Content-Type, Authorization")
        }

        var packet = Data((headerLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        packet.append(body)
        conn.send(content: packet, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    public static func userscriptSource(defaultPort: Int = 18765) -> String {
        return #"""
        // ==UserScript==
        // @name         BoCollector 原生伴随采集助手 (X 书签 / X 监控 / 抖音收藏 L2)
        // @namespace    https://github.com/bo-collector
        // @version      2.0.0
        // @description  日常浏览 X 书签、监控博主主页/列表或抖音收藏夹时被动捕获原始接口响应，一键或自动推送至本机 BoCollector 原生桥接服务
        // @author       BoCollector
        // @match        https://x.com/*
        // @match        https://twitter.com/*
        // @match        https://www.douyin.com/*
        // @run-at       document-start
        // @grant        unsafeWindow
        // @grant        GM_xmlhttpRequest
        // @grant        GM_getValue
        // @grant        GM_setValue
        // @grant        GM_registerMenuCommand
        // @connect      127.0.0.1
        // @connect      localhost
        // @connect      *
        // ==/UserScript==

        (function () {
          "use strict";

          const DEFAULT_BRIDGE_URL = "http://127.0.0.1:\#(defaultPort)";
          const pageWin = typeof unsafeWindow !== "undefined" ? unsafeWindow : window;
          const isX = location.hostname === "x.com" || location.hostname === "twitter.com";

          const buffer = [];
          let pushing = false;
          let badgeEl = null;

          function getBridgeUrl() {
            return (GM_getValue("bo_bridge_url", DEFAULT_BRIDGE_URL) || DEFAULT_BRIDGE_URL).replace(/\/+$/, "");
          }

          function getIngestToken() {
            return (GM_getValue("bo_ingest_token", "") || "").trim();
          }

          function isAutoPush() {
            return Boolean(GM_getValue("bo_auto_push", false));
          }

          function detectCaptureSourceType(url) {
            if (!url || typeof url !== "string") return "";
            if (isX) {
              if (url.includes("/Bookmarks") || url.includes("BookmarkTimeline")) return "x_bookmarks";
              if (url.includes("/UserTweets") || url.includes("ListLatestTweetsTimeline")) return "x_monitor";
              return "";
            }
            if (url.includes("/aweme/v1/web/aweme/listcollection") || url.includes("/aweme/v1/web/collects/video/list")) {
              return "douyin";
            }
            return "";
          }

          function enqueuePayload(matchedType, rawText) {
            if (!matchedType || !rawText || typeof rawText !== "string") return;
            try {
              const parsed = JSON.parse(rawText);
              buffer.push({ sourceType: matchedType, data: parsed });
              renderBadge();
              if (isAutoPush() && !pushing) {
                setTimeout(pushNow, 1200);
              }
            } catch (_e) {}
          }

          const origFetch = pageWin.fetch;
          if (typeof origFetch === "function") {
            pageWin.fetch = async function (...args) {
              const resp = await origFetch.apply(this, args);
              try {
                const reqUrl = typeof args[0] === "string" ? args[0] : (args[0] && args[0].url) || "";
                const matchedType = detectCaptureSourceType(reqUrl) || detectCaptureSourceType(resp.url);
                if (matchedType) {
                  resp.clone().text().then((txt) => enqueuePayload(matchedType, txt)).catch(() => {});
                }
              } catch (_e) {}
              return resp;
            };
          }

          const origOpen = pageWin.XMLHttpRequest.prototype.open;
          const origSend = pageWin.XMLHttpRequest.prototype.send;
          pageWin.XMLHttpRequest.prototype.open = function (method, url, ...rest) {
            this.__boUrl = typeof url === "string" ? url : String(url || "");
            return origOpen.call(this, method, url, ...rest);
          };
          pageWin.XMLHttpRequest.prototype.send = function (...args) {
            this.addEventListener("load", function () {
              try {
                const matchedType = detectCaptureSourceType(this.__boUrl) || detectCaptureSourceType(this.responseURL);
                if (matchedType && typeof this.responseText === "string") {
                  enqueuePayload(matchedType, this.responseText);
                }
              } catch (_e) {}
            });
            return origSend.apply(this, args);
          };

          function pushNow() {
            if (pushing || buffer.length === 0) return;
            pushing = true;
            const firstType = buffer[0].sourceType;
            const batchItems = [];
            const remaining = [];
            for (const item of buffer) {
              if (item.sourceType === firstType) batchItems.push(item);
              else remaining.push(item);
            }
            buffer.length = 0;
            buffer.push(...remaining);
            renderBadge("BoCollector 处理推送中...");

            const headers = { "Content-Type": "application/json" };
            const token = getIngestToken();
            if (token) headers["Authorization"] = `Bearer ${token}`;

            GM_xmlhttpRequest({
              method: "POST",
              url: `${getBridgeUrl()}/api/ingest/raw`,
              headers,
              data: JSON.stringify({
                source_type: firstType,
                payloads: batchItems.map((x) => x.data),
                clean: true,
              }),
              timeout: 180000,
              onload: function (res) {
                pushing = false;
                if (res.status >= 200 && res.status < 300) {
                  try {
                    const data = JSON.parse(res.responseText || "{}");
                    renderBadge(`✓ 已入库 ${data.saved ?? 0} 条`);
                  } catch (_e) {
                    renderBadge("✓ 推送成功");
                  }
                  if (buffer.length > 0) setTimeout(pushNow, 400);
                } else {
                  buffer.unshift(...batchItems);
                  renderBadge(`✗ 失败 HTTP ${res.status} (点击重试)`);
                }
              },
              onerror: function () {
                pushing = false;
                buffer.unshift(...batchItems);
                renderBadge("✗ 未连接 BoCollector 桥接 (点击重试)");
              },
              ontimeout: function () {
                pushing = false;
                renderBadge("⚠ 处理超时，后台可能仍在继续");
              },
            });
          }

          function renderBadge(customText) {
            if (!document.body) {
              window.addEventListener("DOMContentLoaded", () => renderBadge(customText), { once: true });
              return;
            }
            if (!badgeEl) {
              badgeEl = document.createElement("div");
              badgeEl.style.cssText = [
                "position:fixed",
                "right:18px",
                "bottom:22px",
                "z-index:999999",
                "padding:8px 14px",
                "border-radius:999px",
                "background:rgba(15,23,42,0.92)",
                "color:#f8fafc",
                "font:12px/1.4 -apple-system,BlinkMacSystemFont,sans-serif",
                "box-shadow:0 6px 20px rgba(0,0,0,0.28)",
                "cursor:pointer",
                "user-select:none",
                "backdrop-filter:blur(8px)",
                "border:1px solid rgba(148,163,184,0.25)",
              ].join(";");
              badgeEl.title = "点击立即推送捕获的收藏数据至 BoCollector";
              badgeEl.addEventListener("click", pushNow);
              document.body.appendChild(badgeEl);
            }
            badgeEl.textContent = customText || `BoCollector 待推送 (${buffer.length} 批) · 点击同步`;
          }

          GM_registerMenuCommand("设置 BoCollector 本地桥接地址", () => {
            const val = prompt("请输入本地桥接地址：", getBridgeUrl());
            if (val !== null && val.trim()) {
              GM_setValue("bo_bridge_url", val.trim());
              alert("已保存地址：" + val.trim());
            }
          });

          GM_registerMenuCommand("设置桥接 Bearer Token（可选）", () => {
            const val = prompt("请输入桥接 Token（无密码模式留空）：", getIngestToken());
            if (val !== null) {
              GM_setValue("bo_ingest_token", val.trim());
              alert("已更新桥接 Token");
            }
          });

          GM_registerMenuCommand("切换捕获后自动推送开关", () => {
            const next = !isAutoPush();
            GM_setValue("bo_auto_push", next);
            alert(`自动推送已${next ? "开启" : "关闭"}`);
          });
        })();
        """#
    }
}
