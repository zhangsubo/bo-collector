import Foundation

public struct HTTPRequestSpec: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var uploadFileURL: URL?
    public var basicAuth: (username: String, password: String)?
    public var timeout: TimeInterval

    public init(
        method: String = "GET",
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        uploadFileURL: URL? = nil,
        basicAuth: (username: String, password: String)? = nil,
        timeout: TimeInterval = 30.0
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.uploadFileURL = uploadFileURL
        self.basicAuth = basicAuth
        self.timeout = timeout
    }
}

public struct HTTPResponseData: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let data: Data

    public init(statusCode: Int, headers: [String: String] = [:], data: Data = Data()) {
        self.statusCode = statusCode
        var lowered: [String: String] = [:]
        for (k, v) in headers {
            lowered[k.lowercased()] = v
        }
        self.headers = lowered
        self.data = data
    }

    public var text: String {
        String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    public func json() throws -> JSONValue {
        guard !data.isEmpty else { return .object([:]) }
        return try JSONValue.parse(data: data)
    }
}

public struct HTTPTransportError: LocalizedError, Sendable {
    public let code: URLError.Code?
    public let message: String
    public let isTimeout: Bool

    public init(code: URLError.Code? = nil, message: String, isTimeout: Bool = false) {
        self.code = code
        self.message = message
        self.isTimeout = isTimeout
    }

    public var errorDescription: String? { message }
}

public protocol HTTPTransport: Sendable {
    func send(_ spec: HTTPRequestSpec) throws -> HTTPResponseData
    func close()
}

extension HTTPTransport {
    public func close() {}

    public static func makeURL(_ base: String, query: [String: String] = [:]) throws -> URL {
        guard var comps = URLComponents(string: base) else {
            throw HTTPTransportError(message: "Invalid URL: \(base)")
        }
        if !query.isEmpty {
            var items = comps.queryItems ?? []
            for (k, v) in query.sorted(by: { $0.key < $1.key }) {
                items.append(URLQueryItem(name: k, value: v))
            }
            comps.queryItems = items
        }
        guard let url = comps.url else {
            throw HTTPTransportError(message: "Failed to build URL: \(base)")
        }
        return url
    }
}

/// Pooled native URLSession HTTP client supporting macOS system proxy (Surge/Clash), custom HTTP proxy, or direct connection, plus zero-RAM file streaming uploads.
public final class URLSessionHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let delegateQueue: OperationQueue

    public init(config: CollectorConfig) {
        let sessionCfg = URLSessionConfiguration.ephemeral
        sessionCfg.httpShouldSetCookies = false
        sessionCfg.urlCache = nil
        sessionCfg.httpMaximumConnectionsPerHost = 6
        sessionCfg.waitsForConnectivity = false

        switch config.proxyMode {
        case .system:
            // nil inherits macOS system proxy (scutil --proxy) automatically
            sessionCfg.connectionProxyDictionary = nil
        case .custom:
            let host = config.customProxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
            let port = config.customProxyPort
            if !host.isEmpty && port > 0 {
                sessionCfg.connectionProxyDictionary = [
                    "HTTPEnable": 1,
                    "HTTPProxy": host,
                    "HTTPPort": port,
                    "HTTPSEnable": 1,
                    "HTTPSProxy": host,
                    "HTTPSPort": port,
                ]
            }
        case .direct:
            sessionCfg.connectionProxyDictionary = [:]
        }

        let queue = OperationQueue()
        queue.name = "com.bo.collector.http"
        queue.maxConcurrentOperationCount = 8
        self.delegateQueue = queue
        self.session = URLSession(configuration: sessionCfg, delegate: nil, delegateQueue: queue)
    }

    public func close() {
        session.finishTasksAndInvalidate()
    }

    public func send(_ spec: HTTPRequestSpec) throws -> HTTPResponseData {
        var req = URLRequest(url: spec.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: spec.timeout)
        req.httpMethod = spec.method
        for (k, v) in spec.headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        if let auth = spec.basicAuth {
            let raw = "\(auth.username):\(auth.password)"
            let b64 = Data(raw.utf8).base64EncodedString()
            req.setValue("Basic \(b64)", forHTTPHeaderField: "Authorization")
        }
        if spec.uploadFileURL == nil, let body = spec.body {
            req.httpBody = body
        }

        let box = ResultBox<Result<HTTPResponseData, Error>>()
        let sem = DispatchSemaphore(value: 0)

        let completion: @Sendable (Data?, URLResponse?, Error?) -> Void = { data, response, error in
            defer { sem.signal() }
            if let err = error {
                if let urlErr = err as? URLError {
                    box.value = .failure(
                        HTTPTransportError(
                            code: urlErr.code,
                            message: "URLError(\(urlErr.code.rawValue)): \(urlErr.localizedDescription)",
                            isTimeout: urlErr.code == .timedOut
                        )
                    )
                } else {
                    box.value = .failure(HTTPTransportError(message: err.localizedDescription))
                }
                return
            }
            guard let httpResp = response as? HTTPURLResponse else {
                box.value = .failure(HTTPTransportError(message: "Non-HTTP URLResponse"))
                return
            }
            var headers: [String: String] = [:]
            for (k, v) in httpResp.allHeaderFields {
                headers[String(describing: k).lowercased()] = String(describing: v)
            }
            box.value = .success(HTTPResponseData(statusCode: httpResp.statusCode, headers: headers, data: data ?? Data()))
        }

        let task: URLSessionTask
        if let uploadFile = spec.uploadFileURL {
            if req.value(forHTTPHeaderField: "Content-Length") == nil,
               let attrs = try? FileManager.default.attributesOfItem(atPath: uploadFile.path),
               let size = (attrs[.size] as? NSNumber)?.int64Value {
                req.setValue(String(size), forHTTPHeaderField: "Content-Length")
            }
            task = session.uploadTask(with: req, fromFile: uploadFile, completionHandler: completion)
        } else {
            task = session.dataTask(with: req, completionHandler: completion)
        }
        task.resume()

        let waitResult = sem.wait(timeout: .now() + spec.timeout + 5.0)
        if waitResult == .timedOut {
            task.cancel()
            throw HTTPTransportError(code: .timedOut, message: "HTTP request timed out after \(Int(spec.timeout))s", isTimeout: true)
        }
        guard let final = box.value else {
            throw HTTPTransportError(message: "Empty HTTP completion result")
        }
        return try final.get()
    }

    public func downloadToFile(_ spec: HTTPRequestSpec, destination: URL) throws -> Bool {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var req = URLRequest(url: spec.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: spec.timeout)
        req.httpMethod = spec.method
        for (k, v) in spec.headers {
            req.setValue(v, forHTTPHeaderField: k)
        }

        let box = ResultBox<Bool>()
        let sem = DispatchSemaphore(value: 0)
        let task = session.downloadTask(with: req) { tempURL, response, error in
            defer { sem.signal() }
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let tempURL else {
                box.value = false
                return
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: tempURL, to: destination)
                let size = ((try? FileManager.default.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber)?.int64Value ?? 0
                box.value = size > 0
            } catch {
                box.value = false
            }
        }
        task.resume()
        if sem.wait(timeout: .now() + spec.timeout + 5.0) == .timedOut {
            task.cancel()
            return false
        }
        return box.value ?? false
    }
}

final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

// MARK: - Subprocess & Binary Discovery

public struct SubprocessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandRunner: Sendable {
    func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?,
        timeout: TimeInterval
    ) throws -> SubprocessResult
}

public struct DefaultCommandRunner: CommandRunner {
    public init() {}

    public func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 60
    ) throws -> SubprocessResult {
        let proc = Process()
        if executable.contains("/") {
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = arguments
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = [executable] + arguments
        }
        if let cwd = currentDirectory {
            proc.currentDirectoryURL = cwd
        }

        var mergedEnv = environment ?? ProcessInfo.processInfo.environment
        mergedEnv["PATH"] = ExecutableLocator.enrichedPATH(base: mergedEnv["PATH"])
        proc.environment = mergedEnv

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let outBox = ResultBox<Data>()
        let errBox = ResultBox<Data>()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outBox.value = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.value = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let termSem = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in
            termSem.signal()
        }

        try proc.run()
        if termSem.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            _ = termSem.wait(timeout: .now() + 2.0)
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
            throw HTTPTransportError(code: .timedOut, message: "Process timed out after \(Int(timeout))s: \(executable)", isTimeout: true)
        }
        _ = group.wait(timeout: .now() + 3.0)

        let stdoutStr = String(data: outBox.value ?? Data(), encoding: .utf8) ?? ""
        let stderrStr = String(data: errBox.value ?? Data(), encoding: .utf8) ?? ""
        return SubprocessResult(exitCode: proc.terminationStatus, stdout: stdoutStr, stderr: stderrStr)
    }
}

public enum ExecutableLocator {
    public static func enrichedPATH(base: String? = ProcessInfo.processInfo.environment["PATH"]) -> String {
        let homeLocal = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
        var parts = (base ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        for extra in ["/opt/homebrew/bin", "/usr/local/bin", homeLocal, "/usr/bin", "/bin", "/usr/sbin", "/sbin"] {
            if !parts.contains(extra) {
                parts.insert(extra, at: 0)
            }
        }
        return parts.joined(separator: ":")
    }

    public static func find(preferred: String = "", binaryName: String, extraCandidates: [String] = []) -> String? {
        let fm = FileManager.default
        let trimmed = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let expanded = (trimmed as NSString).expandingTildeInPath
            if expanded.contains("/") {
                return fm.isExecutableFile(atPath: expanded) ? expanded : nil
            }
            if let inPath = searchPATH(expanded) {
                return inPath
            }
        }
        if let inPath = searchPATH(binaryName) {
            return inPath
        }
        for raw in extraCandidates {
            let p = (raw as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: p) {
                return p
            }
        }
        return nil
    }

    private static func searchPATH(_ name: String) -> String? {
        let fm = FileManager.default
        for dir in enrichedPATH().split(separator: ":").map(String.init) {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
