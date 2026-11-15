import Foundation

/// Edge full-text recovery engine for cloud `rss` summary articles (`refetch_status == "pending_edge"`).
/// Stage A: Native macOS URLSession HTTP fetch (inheriting system / Surge / Clash residential proxy) -> clean Markdown.
/// Stage B: Headless/isolated `ego-browser` TaskSpace DOM extraction fallback for JS-rendered or datacenter-blocked pages.
/// Strictly respects anti-bot / CAPTCHA boundaries: never clicks, solves, waits out, or bypasses verification interstitials.
public final class ArticleRefetchEngine: @unchecked Sendable {
    public static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    public static let minReadableChars = 120
    public static let defaultMaxAttempts = 3

    private static let scriptStyleStripRegex = try! NSRegularExpression(
        pattern: #"<(script|style|noscript|svg|iframe)\b[^>]*>[\s\S]*?</\1>"#,
        options: [.caseInsensitive]
    )
    private static let htmlCommentStripRegex = try! NSRegularExpression(
        pattern: #"<!--[\s\S]*?-->"#,
        options: []
    )
    private static let html5OpenTagRegex = try! NSRegularExpression(
        pattern: #"<(article|main|section|nav|header|footer|aside|figure|figcaption)\b([^>]*)>"#,
        options: [.caseInsensitive]
    )
    private static let html5CloseTagRegex = try! NSRegularExpression(
        pattern: #"</(article|main|section|nav|header|footer|aside|figure|figcaption)\s*>"#,
        options: [.caseInsensitive]
    )
    private static let multiNewlineRegex = try! NSRegularExpression(
        pattern: #"\n{3,}"#,
        options: []
    )
    private static let wsCollapseRegex = try! NSRegularExpression(
        pattern: #"[ \t\r\f\v]+"#,
        options: []
    )
    private static let mdImageRegex = try! NSRegularExpression(
        pattern: #"!\[([^\]]*)\]\([^)]+\)"#,
        options: []
    )
    private static let mdLinkRegex = try! NSRegularExpression(
        pattern: #"\[([^\]]+)\]\([^)]+\)"#,
        options: []
    )
    private static let langClassRegex = try! NSRegularExpression(
        pattern: #"(?:language|lang)-([A-Za-z0-9_+-]+)"#,
        options: [.caseInsensitive]
    )

    private static let skipTagNames: Set<String> = [
        "script", "style", "noscript", "svg", "nav", "header", "footer",
        "aside", "form", "iframe", "button", "canvas", "dialog",
    ]

    private static let blockTagNames: Set<String> = [
        "div", "section", "article", "main", "p", "pre", "ul", "ol", "li",
        "blockquote", "h1", "h2", "h3", "h4", "h5", "h6", "figure", "table", "tr",
    ]

    private static let preferredContentIDs: [String] = [
        "js_content",
        "cnblogs_post_body",
        "article_content",
        "post-content",
        "content",
    ]

    private static let preferredContentClasses: [String] = [
        "rich_media_content",
        "post-content",
        "entry-content",
        "article-content",
        "article-body",
        "markdown-body",
        "gh-content",
        "available-content",
        "post-body",
        "prose",
    ]

    public let config: CollectorConfig
    public let http: HTTPTransport
    public let browser: BrowserCollecting
    public let logger: SafeLogger

    public init(
        config: CollectorConfig,
        http: HTTPTransport,
        browser: BrowserCollecting,
        logger: SafeLogger
    ) {
        self.config = config
        self.http = http
        self.browser = browser
        self.logger = logger
    }

    // MARK: - Anti-Bot / Interstitial Boundary Detection

    public static func isAntiBotInterstitial(html: String, plainText: String) -> Bool {
        let trimmedPlain = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        let plainCount = trimmedPlain.count
        if plainCount >= 1200 {
            return false
        }

        let lowerHTML = html.lowercased()
        let lowerPlain = trimmedPlain.lowercased()

        let hasCaptchaWidget =
            lowerHTML.contains("cf-turnstile")
            || lowerHTML.contains("challenges.cloudflare.com/turnstile")
            || lowerHTML.contains("g-recaptcha")
            || lowerHTML.contains("hcaptcha")
            || lowerHTML.contains("_cf_chl_opt")

        if hasCaptchaWidget && plainCount < 900 {
            return true
        }

        if plainCount < 1000 {
            if trimmedPlain.contains("环境异常") && (trimmedPlain.contains("验证") || trimmedPlain.contains("继续访问")) {
                return true
            }
            if trimmedPlain.contains("完成验证后即可继续访问") {
                return true
            }
            let textMarkers = [
                "just a moment...",
                "enable javascript and cookies to continue",
                "verify you are human",
                "checking your browser before accessing",
                "attention required! | cloudflare",
                "access denied",
            ]
            for marker in textMarkers where lowerPlain.contains(marker) || lowerHTML.contains("<title>\(marker)") {
                return true
            }
        }

        return false
    }

    // MARK: - Native HTML -> Structured Markdown Extraction

    public static func plainTextLength(_ markdownOrText: String) -> Int {
        var s = markdownOrText
        s = mdImageRegex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
        s = mdLinkRegex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
        let stripped = s.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet(charactersIn: "#*`>_~-|").contains(scalar)
        }
        return stripped.count
    }

    public static func extractMarkdownFromHTML(_ html: String, baseURL: URL?) -> (title: String, markdown: String)? {
        let sanitized = sanitizeRawHTML(html)
        guard !sanitized.isEmpty else { return nil }

        if isAntiBotInterstitial(html: html, plainText: stripAllTags(sanitized)) {
            return nil
        }

        guard let doc = parseHTMLDocument(sanitized),
              let rootEl = doc.rootElement() else {
            return nil
        }

        pruneIgnoredElements(in: rootEl)

        let docPlain = (rootEl.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if isAntiBotInterstitial(html: html, plainText: docPlain) {
            return nil
        }

        let title = extractBestTitle(from: rootEl)
        let contentRoot = selectContentRoot(from: rootEl)

        var blocks: [String] = []
        walkBlock(node: contentRoot, baseURL: baseURL, into: &blocks)

        var markdown = blocks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        markdown = multiNewlineRegex.stringByReplacingMatches(
            in: markdown,
            range: NSRange(markdown.startIndex..., in: markdown),
            withTemplate: "\n\n"
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let usefulChars = plainTextLength(markdown)
        guard usefulChars >= minReadableChars else {
            return nil
        }
        return (title: title, markdown: markdown)
    }

    // MARK: - Article Metadata State Transitions

    public static func applyRefetchedBody(
        to article: ArticlePayload,
        markdown: String,
        channel: String
    ) -> ArticlePayload {
        let cleanMarkdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = article
        updated.content = cleanMarkdown
        updated.metadata["has_full_content"] = .bool(true)
        updated.metadata["refetch_status"] = .string("succeeded_edge")
        updated.metadata["refetch_channel"] = .string(channel)
        updated.metadata["refetched_at"] = .string(DateFormatting.isoTimestamp())
        updated.metadata["pipeline_raw"] = .object([
            "content": .string(cleanMarkdown),
            "title": .string(updated.title),
        ])
        return updated
    }

    public static func applyFailedAttempt(
        to article: ArticlePayload,
        maxAttempts: Int = defaultMaxAttempts
    ) -> (article: ArticlePayload, exhausted: Bool) {
        var updated = article
        let prev = updated.metadata["refetch_attempts"]?.intValue ?? 0
        let next = prev + 1
        let isExhausted = next >= max(1, maxAttempts)
        updated.metadata["refetch_attempts"] = .int(next)
        updated.metadata["last_refetch_attempt_at"] = .string(DateFormatting.isoTimestamp())
        if isExhausted {
            updated.metadata["refetch_status"] = .string("exhausted")
        }
        return (updated, isExhausted)
    }

    // MARK: - Batch Execution (Stage A HTTP -> Stage B ego-browser Fallback)

    public func refetchPending(
        articles: [ArticlePayload],
        limitOverride: Int? = nil,
        pushHandler: (ArticlePayload, Bool) throws -> [String: JSONValue]
    ) throws -> RssRefetchSummary {
        guard !articles.isEmpty else {
            return RssRefetchSummary()
        }
        let maxBatch = max(1, limitOverride ?? config.rssRefetchMaxPerRun)
        let batch = Array(articles.prefix(maxBatch))

        var succeededHTTP = 0
        var succeededBrowser = 0
        var stillPending = max(0, articles.count - batch.count)
        var exhausted = 0

        for article in batch {
            guard let rawURL = article.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawURL.isEmpty,
                  let targetURL = URL(string: rawURL) else {
                let (failedArt, isEx) = Self.applyFailedAttempt(to: article)
                _ = try? pushHandler(failedArt, false)
                if isEx { exhausted += 1 } else { stillPending += 1 }
                continue
            }

            let fetchMode = (article.metadata["fetch_mode"]?.stringValue ?? "auto").lowercased()
            let existingPlain = Self.plainTextLength(article.content)

            var recoveredMarkdown: String? = nil
            var channel = ""

            // Stage A: Native URLSession HTTP GET (uses configured residential / system proxy)
            if let httpBody = fetchViaHTTP(url: targetURL),
               Self.isAcceptableUpgrade(
                   candidateMarkdown: httpBody,
                   existingContent: article.content,
                   existingPlain: existingPlain,
                   fetchMode: fetchMode
               ) {
                recoveredMarkdown = httpBody
                channel = "edge_http"
            }

            // Stage B: Isolated ego-browser TaskSpace DOM extraction fallback
            if recoveredMarkdown == nil,
               config.rssRefetchUseBrowserFallback,
               browser.isAvailable() {
                let bRes = browser.extractReadableArticle(url: rawURL, handoff: false)
                if bRes.status == "ok",
                   Self.isAcceptableUpgrade(
                       candidateMarkdown: bRes.markdown,
                       existingContent: article.content,
                       existingPlain: existingPlain,
                       fetchMode: fetchMode
                   ) {
                    recoveredMarkdown = bRes.markdown
                    channel = "edge_browser"
                } else if bRes.status == "interstitial_blocked" {
                    logger.warn("[RSS 边缘补抓] 目标页触发验证拦截页，按安全边界放弃自动绕过: \(article.title)")
                }
            }

            if let markdown = recoveredMarkdown {
                let upgraded = Self.applyRefetchedBody(to: article, markdown: markdown, channel: channel)
                let res = try pushHandler(upgraded, true)
                let saveFailed = res["save_failed"]?.intValue ?? 0
                let saved = res["saved"]?.intValue ?? 0
                let dup = res["duplicates"]?.intValue ?? 0
                if saveFailed == 0 && (saved + dup) >= 1 {
                    if channel == "edge_http" {
                        succeededHTTP += 1
                    } else {
                        succeededBrowser += 1
                    }
                } else {
                    stillPending += 1
                }
            } else {
                let (failedArt, isEx) = Self.applyFailedAttempt(to: article)
                _ = try pushHandler(failedArt, false)
                if isEx {
                    exhausted += 1
                } else {
                    stillPending += 1
                }
            }
        }

        return RssRefetchSummary(
            checked: batch.count,
            succeededHTTP: succeededHTTP,
            succeededBrowser: succeededBrowser,
            stillPending: stillPending,
            exhausted: exhausted
        )
    }

    private func fetchViaHTTP(url: URL) -> String? {
        let headers: [String: String] = [
            "User-Agent": Self.desktopUserAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        ]
        let spec = HTTPRequestSpec(method: "GET", url: url, headers: headers, timeout: 25.0)
        guard let resp = try? http.send(spec),
              (200..<300).contains(resp.statusCode),
              !resp.data.isEmpty else {
            return nil
        }
        if let ctype = resp.header("content-type")?.lowercased() {
            if ctype.contains("application/pdf")
                || ctype.contains("image/")
                || ctype.contains("video/")
                || ctype.contains("audio/")
                || ctype.contains("application/octet-stream") {
                return nil
            }
        }
        let html = resp.text
        return Self.extractMarkdownFromHTML(html, baseURL: url)?.markdown
    }

    private static func isAcceptableUpgrade(
        candidateMarkdown: String,
        existingContent: String,
        existingPlain: Int,
        fetchMode: String
    ) -> Bool {
        let candPlain = plainTextLength(candidateMarkdown)
        guard candPlain >= minReadableChars else { return false }
        if fetchMode == "always" {
            // Even in "always" mode, never replace a substantial feed body with a much shorter stub
            return existingPlain == 0 || candPlain >= max(minReadableChars, existingPlain / 2)
        }
        return candPlain > existingPlain + 20 || candidateMarkdown.count > existingContent.count + 40
    }

    // MARK: - Private DOM Helpers

    private static func effectiveTagName(_ element: XMLElement) -> String {
        if let h5 = element.attribute(forName: "data-h5")?.stringValue?.lowercased(), !h5.isEmpty {
            return h5
        }
        return (element.name ?? "").lowercased()
    }

    private static func sanitizeRawHTML(_ raw: String) -> String {
        var cleaned = raw.replacingOccurrences(of: "\0", with: "")
        cleaned = scriptStyleStripRegex.stringByReplacingMatches(
            in: cleaned,
            range: NSRange(cleaned.startIndex..., in: cleaned),
            withTemplate: ""
        )
        cleaned = htmlCommentStripRegex.stringByReplacingMatches(
            in: cleaned,
            range: NSRange(cleaned.startIndex..., in: cleaned),
            withTemplate: ""
        )
        // Preserve HTML5 semantic containers across libxml2's HTML4 documentTidyHTML pass
        cleaned = html5OpenTagRegex.stringByReplacingMatches(
            in: cleaned,
            range: NSRange(cleaned.startIndex..., in: cleaned),
            withTemplate: "<div data-h5=\"$1\"$2>"
        )
        cleaned = html5CloseTagRegex.stringByReplacingMatches(
            in: cleaned,
            range: NSRange(cleaned.startIndex..., in: cleaned),
            withTemplate: "</div>"
        )
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripAllTags(_ html: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"<[^>]+>"#, options: []) else {
            return html
        }
        return re.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: " ")
    }

    private static func parseHTMLDocument(_ html: String) -> XMLDocument? {
        if let doc = try? XMLDocument(xmlString: html, options: [.documentTidyHTML]) {
            return doc
        }
        let wrapped = "<html><body>\(html)</body></html>"
        return try? XMLDocument(xmlString: wrapped, options: [.documentTidyHTML])
    }

    private static func pruneIgnoredElements(in element: XMLElement, insideArticle: Bool = false) {
        let currentTag = effectiveTagName(element)
        let nowInsideArticle = insideArticle || currentTag == "article" || currentTag == "main"
        guard let children = element.children else { return }
        for child in children.reversed() {
            guard let childEl = child as? XMLElement else { continue }
            let tag = effectiveTagName(childEl)
            if tag == "header" && nowInsideArticle {
                pruneIgnoredElements(in: childEl, insideArticle: true)
                continue
            }
            if skipTagNames.contains(tag) {
                childEl.detach()
                continue
            }
            if let style = childEl.attribute(forName: "style")?.stringValue?.lowercased().replacingOccurrences(of: " ", with: ""),
               (style.contains("display:none") || style.contains("visibility:hidden")),
               childEl.attribute(forName: "id")?.stringValue != "js_content" {
                // Note: WeChat #js_content often sets visibility:hidden in raw HTML before JS runs! Never strip #js_content!
                childEl.detach()
                continue
            }
            pruneIgnoredElements(in: childEl, insideArticle: nowInsideArticle)
        }
    }

    private static func extractBestTitle(from root: XMLElement) -> String {
        if let wxTitle = findFirstElement(in: root, where: { $0.attribute(forName: "id")?.stringValue == "activity-name" }),
           let txt = wxTitle.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !txt.isEmpty {
            return collapseSpaces(txt)
        }
        if let h1 = findFirstElement(in: root, where: { effectiveTagName($0) == "h1" }),
           let txt = h1.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !txt.isEmpty {
            return collapseSpaces(txt)
        }
        if let titleEl = findFirstElement(in: root, where: { effectiveTagName($0) == "title" }),
           let txt = titleEl.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !txt.isEmpty {
            return collapseSpaces(txt)
        }
        return ""
    }

    private static func selectContentRoot(from root: XMLElement) -> XMLElement {
        for targetID in preferredContentIDs {
            if let match = findFirstElement(in: root, where: { el in
                el.attribute(forName: "id")?.stringValue == targetID
                    && plainTextLength(el.stringValue ?? "") >= minReadableChars
            }) {
                return match
            }
        }

        if let articleEl = findFirstElement(in: root, where: { el in
            effectiveTagName(el) == "article"
                && plainTextLength(el.stringValue ?? "") >= minReadableChars
        }) {
            return articleEl
        }

        if let roleMain = findFirstElement(in: root, where: { el in
            el.attribute(forName: "role")?.stringValue?.lowercased() == "main"
                && plainTextLength(el.stringValue ?? "") >= minReadableChars
        }) {
            return roleMain
        }

        if let mainEl = findFirstElement(in: root, where: { el in
            effectiveTagName(el) == "main"
                && plainTextLength(el.stringValue ?? "") >= minReadableChars
        }) {
            return mainEl
        }

        for cls in preferredContentClasses {
            if let match = findFirstElement(in: root, where: { el in
                guard let classAttr = el.attribute(forName: "class")?.stringValue?.lowercased() else { return false }
                let tokens = classAttr.split(whereSeparator: \.isWhitespace).map(String.init)
                let matched = tokens.contains(cls) || classAttr.contains(cls)
                return matched && plainTextLength(el.stringValue ?? "") >= minReadableChars
            }) {
                return match
            }
        }

        if let bodyEl = findFirstElement(in: root, where: { effectiveTagName($0) == "body" }) {
            return bodyEl
        }
        return root
    }

    private static func findFirstElement(in element: XMLElement, where predicate: (XMLElement) -> Bool) -> XMLElement? {
        if predicate(element) {
            return element
        }
        for child in element.children ?? [] {
            if let childEl = child as? XMLElement,
               let found = findFirstElement(in: childEl, where: predicate) {
                return found
            }
        }
        return nil
    }

    private static func collapseSpaces(_ s: String) -> String {
        wsCollapseRegex.stringByReplacingMatches(
            in: s,
            range: NSRange(s.startIndex..., in: s),
            withTemplate: " "
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolveURL(_ raw: String, baseURL: URL?) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("data:") || lower.hasPrefix("javascript:") || lower.hasPrefix("vbscript:") || lower.hasPrefix("about:") {
            return nil
        }
        if trimmed.hasPrefix("//"), let scheme = baseURL?.scheme {
            return "\(scheme):\(trimmed)"
        }
        if let resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL {
            return resolved.absoluteString
        }
        return trimmed
    }

    private static func extractCodeLanguage(from element: XMLElement) -> String {
        var candidates: [String] = []
        if let c = element.attribute(forName: "class")?.stringValue { candidates.append(c) }
        if let dataLang = element.attribute(forName: "data-lang")?.stringValue { return dataLang.trimmingCharacters(in: .whitespacesAndNewlines) }
        for child in element.children ?? [] {
            if let childEl = child as? XMLElement, (childEl.name ?? "").lowercased() == "code",
               let c = childEl.attribute(forName: "class")?.stringValue {
                candidates.append(c)
            }
        }
        for cls in candidates {
            let ns = cls as NSString
            if let match = langClassRegex.firstMatch(in: cls, range: NSRange(location: 0, length: ns.length)),
               match.numberOfRanges >= 2 {
                return ns.substring(with: match.range(at: 1))
            }
        }
        return ""
    }

    private static func walkInline(node: XMLNode, baseURL: URL?) -> String {
        if node.kind == .text {
            let val = node.stringValue ?? ""
            return wsCollapseRegex.stringByReplacingMatches(
                in: val.replacingOccurrences(of: "\n", with: " "),
                range: NSRange(val.startIndex..., in: val),
                withTemplate: " "
            )
        }
        guard let el = node as? XMLElement else { return "" }
        let tag = effectiveTagName(el)
        if skipTagNames.contains(tag) && tag != "header" { return "" }
        if tag == "br" { return "\n" }

        if tag == "img" {
            let w = el.attribute(forName: "width")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let h = el.attribute(forName: "height")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if w == "1" || h == "1" || w == "0" || h == "0" {
                return ""
            }
            let rawSrc =
                el.attribute(forName: "data-src")?.stringValue?.nonEmpty
                ?? el.attribute(forName: "data-original")?.stringValue?.nonEmpty
                ?? el.attribute(forName: "data-actualsrc")?.stringValue?.nonEmpty
                ?? el.attribute(forName: "src")?.stringValue?.nonEmpty
                ?? ""
            guard let absSrc = resolveURL(rawSrc, baseURL: baseURL) else { return "" }
            let alt = collapseSpaces(el.attribute(forName: "alt")?.stringValue ?? "")
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
            return "![\(alt)](\(absSrc))"
        }

        let inner = (el.children ?? []).map { walkInline(node: $0, baseURL: baseURL) }.joined()
        let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)

        switch tag {
        case "code":
            return trimmed.isEmpty ? "" : "`\(trimmed)`"
        case "strong", "b":
            return trimmed.isEmpty ? "" : "**\(trimmed)**"
        case "em", "i":
            return trimmed.isEmpty ? "" : "*\(trimmed)*"
        case "a":
            let rawHref = el.attribute(forName: "href")?.stringValue ?? ""
            if rawHref.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") {
                return trimmed
            }
            if let absHref = resolveURL(rawHref, baseURL: baseURL) {
                let label = trimmed.isEmpty ? absHref : trimmed
                return "[\(label)](\(absHref))"
            }
            return trimmed
        default:
            return inner
        }
    }

    private static func extractRawPreText(_ node: XMLNode) -> String {
        if node.kind == .text {
            return node.stringValue ?? ""
        }
        guard let el = node as? XMLElement else { return "" }
        let tag = (el.name ?? "").lowercased()
        if tag == "br" { return "\n" }
        return (el.children ?? []).map(extractRawPreText).joined()
    }

    private static func walkBlock(node: XMLNode, baseURL: URL?, into blocks: inout [String]) {
        if node.kind == .text {
            let t = collapseSpaces(node.stringValue ?? "")
            if !t.isEmpty {
                blocks.append(t)
            }
            return
        }
        guard let el = node as? XMLElement else { return }
        let tag = effectiveTagName(el)
        if skipTagNames.contains(tag) && tag != "header" { return }

        if tag.count == 2, tag.first == "h", let lvl = Int(String(tag.last!)), (1...6).contains(lvl) {
            let heading = collapseSpaces(walkInline(node: el, baseURL: baseURL))
            if !heading.isEmpty {
                blocks.append("\(String(repeating: "#", count: lvl)) \(heading)")
            }
            return
        }

        if tag == "pre" {
            let lang = extractCodeLanguage(from: el)
            let code = extractRawPreText(el).trimmingCharacters(in: CharacterSet.newlines)
            if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append("```\(lang)\n\(code)\n```")
            }
            return
        }

        if tag == "blockquote" {
            var innerBlocks: [String] = []
            for child in el.children ?? [] {
                walkBlock(node: child, baseURL: baseURL, into: &innerBlocks)
            }
            let rawQuote = innerBlocks.isEmpty ? collapseSpaces(el.stringValue ?? "") : innerBlocks.joined(separator: "\n")
            if !rawQuote.isEmpty {
                let quoted = rawQuote
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? ">" : "> \($0)" }
                    .joined(separator: "\n")
                blocks.append(quoted)
            }
            return
        }

        if tag == "ul" || tag == "ol" {
            var lines: [String] = []
            var index = 1
            for child in el.children ?? [] {
                guard let li = child as? XMLElement, (li.name ?? "").lowercased() == "li" else { continue }
                let itemText = collapseSpaces(walkInline(node: li, baseURL: baseURL))
                if !itemText.isEmpty {
                    let prefix = tag == "ol" ? "\(index)." : "-"
                    lines.append("\(prefix) \(itemText)")
                    index += 1
                }
            }
            if !lines.isEmpty {
                blocks.append(lines.joined(separator: "\n"))
            }
            return
        }

        if tag == "img" {
            let imgMD = walkInline(node: el, baseURL: baseURL).trimmingCharacters(in: .whitespacesAndNewlines)
            if !imgMD.isEmpty {
                blocks.append(imgMD)
            }
            return
        }

        if tag == "p" {
            let pText = walkInline(node: el, baseURL: baseURL)
                .components(separatedBy: .newlines)
                .map { collapseSpaces($0) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            if !pText.isEmpty {
                blocks.append(pText)
            }
            return
        }

        let hasBlockChild = (el.children ?? []).contains { child in
            guard let childEl = child as? XMLElement else { return false }
            let childTag = effectiveTagName(childEl)
            return blockTagNames.contains(childTag) || childTag == "header"
        }

        if hasBlockChild {
            for child in el.children ?? [] {
                walkBlock(node: child, baseURL: baseURL, into: &blocks)
            }
        } else {
            let inlineText = walkInline(node: el, baseURL: baseURL)
                .components(separatedBy: .newlines)
                .map { collapseSpaces($0) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            if !inlineText.isEmpty {
                blocks.append(inlineText)
            }
        }
    }
}
