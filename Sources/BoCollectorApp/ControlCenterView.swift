import AppKit
import BoCollectorCore
import SwiftUI

enum ControlTab: String, CaseIterable, Identifiable {
    case overview
    case cloud
    case sources
    case multimodal
    case runtime
    case logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "运行总览与体检"
        case .cloud: return "云端与网络代理"
        case .sources: return "采集源配置"
        case .multimodal: return "语音 ASR 与视觉 VLM"
        case .runtime: return "浏览器、桥接与定时"
        case .logs: return "运行日志与故障快照"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .cloud: return "icloud.and.arrow.up"
        case .sources: return "square.stack.3d.up"
        case .multimodal: return "waveform.and.magnifyingglass"
        case .runtime: return "gearshape.2"
        case .logs: return "doc.text.magnifyingglass"
        }
    }
}

struct ControlCenterView: View {
    @Bindable var model: AppModel
    @State private var selectedTab: ControlTab = .overview
    @State private var backfillSource: String = "all"
    @State private var backfillMaxItems: Int = 500
    @State private var revealCloudToken: Bool = false
    @State private var revealKoofrPass: Bool = false
    @State private var revealVlmKey: Bool = false
    @State private var revealAsrKey: Bool = false
    @State private var newHandleDraft: String = ""

    var body: some View {
        NavigationSplitView {
            List(ControlTab.allCases, selection: $selectedTab) { tab in
                Label(tab.title, systemImage: tab.icon)
                    .tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 195, ideal: 215, max: 240)
            .safeAreaInset(edge: .top) {
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("BoCollector")
                            .font(.subheadline.bold())
                        Text("macOS 原生边缘采集")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Divider()
                    Button {
                        pickBoDistillerFolder()
                    } label: {
                        Label("从旧 bo-distiller 导入配置…", systemImage: "square.and.arrow.down")
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
            }
        } detail: {
            VStack(spacing: 0) {
                if let msg = model.bannerMessage {
                    HStack(spacing: 8) {
                        Image(systemName: model.bannerIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(model.bannerIsError ? .orange : .green)
                        Text(msg)
                            .font(.callout)
                            .lineLimit(2)
                        Spacer()
                        Button {
                            model.bannerMessage = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(model.bannerIsError ? Color.orange.opacity(0.14) : Color.green.opacity(0.12))
                    Divider()
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch selectedTab {
                        case .overview:
                            overviewPane
                        case .cloud:
                            cloudPane
                        case .sources:
                            sourcesPane
                        case .multimodal:
                            multimodalPane
                        case .runtime:
                            runtimePane
                        case .logs:
                            logsPane
                        }
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()
                bottomSaveBar
            }
        }
    }

    // MARK: - Reusable Native macOS Form Controls (Explicit Rounded Borders + Placeholders)

    @ViewBuilder
    private func sectionCard<Content: View>(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                content()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title)
                .font(.headline)
        }
    }

    @ViewBuilder
    private func textSettingRow(
        title: String,
        hint: String? = nil,
        placeholder: String,
        text: Binding<String>,
        monospaced: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                if let hint, !hint.isEmpty {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("粘贴") {
                    if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !clip.isEmpty {
                        text.wrappedValue = clip
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
                if !text.wrappedValue.isEmpty {
                    Button("清空") {
                        text.wrappedValue = ""
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            TextField("", text: text, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
        }
    }

    @ViewBuilder
    private func secretSettingRow(
        title: String,
        hint: String? = nil,
        placeholder: String,
        text: Binding<String>,
        revealed: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                if let hint, !hint.isEmpty {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Group {
                    if revealed.wrappedValue {
                        TextField("", text: text, prompt: Text(placeholder))
                    } else {
                        SecureField("", text: text, prompt: Text(placeholder))
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

                Button("粘贴") {
                    if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !clip.isEmpty {
                        text.wrappedValue = clip
                    }
                }
                .controlSize(.small)

                Button(revealed.wrappedValue ? "隐藏" : "显示") {
                    revealed.wrappedValue.toggle()
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func intSettingRow(
        title: String,
        hint: String? = nil,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int = 1,
        unit: String
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                if let hint, !hint.isEmpty {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            TextField(
                "",
                value: Binding(
                    get: { value.wrappedValue },
                    set: { newVal in
                        value.wrappedValue = min(range.upperBound, max(range.lowerBound, newVal))
                    }
                ),
                format: .number
            )
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 72)

            Stepper("", value: value, in: range, step: step)
                .labelsHidden()

            Text(unit)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minWidth: 28, alignment: .leading)
        }
    }

    @ViewBuilder
    private func toggleSettingRow(
        title: String,
        hint: String? = nil,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                if let hint, !hint.isEmpty {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    // MARK: - Bottom Save Bar

    private var bottomSaveBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
            Text("配置文件: \(model.savedConfig.configPath.path) (0600 本机权限保护，无需本地 MySQL / Python)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if model.hasUnsavedChanges {
                Text("有未保存的修改")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                Button("放弃修改") {
                    model.revertChanges()
                }
            }

            Button("保存配置 (⌘S)") {
                model.saveConfiguration()
            }
            .keyboardShortcut("s", modifiers: [.command])
            .buttonStyle(.borderedProminent)
            .disabled(!model.hasUnsavedChanges)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - 1. Overview & Doctor

    private var overviewPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("原生边缘采集总览")
                        .font(.title2.bold())
                    Text(model.statusHeadline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isAuthPaused {
                    Button("已完成登录/滑块，立即恢复") {
                        model.resumeAndSync()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
                Button {
                    model.syncNow(source: "all")
                } label: {
                    Label("立即增量同步", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)

                Button {
                    model.runDoctorChecks()
                } label: {
                    Label("全链路体检", systemImage: "stethoscope")
                }
                .disabled(model.isBusy)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                overviewCard(platform: "x_bookmarks", subtitle: "ego-lite 被动拦截 + 长文/配图 VLM", enabled: model.config.xBookmarksEnabled)
                overviewCard(platform: "douyin", subtitle: "图文 VLM + 视频直传 Koofr 转写", enabled: model.config.douyinEnabled)
                overviewCard(platform: "x_monitor", subtitle: "ego-lite 博主监控 + 推送云端", enabled: model.config.xMonitorEnabled)
            }

            sectionCard("无字幕抖音视频异步转写回收 (Koofr WebDAV + Instabox)") {
                HStack {
                    let asr = model.state.asr ?? AsrStateSummary()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("待转写队列: \(asr.stillPending) 篇  ·  上次检查: \(asr.checked) 篇  ·  上次补齐: \(asr.completed) 篇")
                            .font(.subheadline)
                        Text("本地视频流式 PUT 到 Koofr 后即可合盖关机，下次巡检自动拉回 .md 文稿并删除网盘原视频。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("本机 WebDAV 回收") {
                        model.harvestNow(cloudMode: false)
                    }
                    .disabled(model.isBusy)
                    Button("触发云端自助回收") {
                        model.harvestNow(cloudMode: true)
                    }
                    .disabled(model.isBusy)
                }
            }

            sectionCard("历史收藏低速补采（防止风控封号，可随时安全停止）") {
                HStack(spacing: 14) {
                    Picker("补采目标", selection: $backfillSource) {
                        Text("X 书签 + 抖音收藏").tag("all")
                        Text("仅 X 书签").tag("x_bookmarks")
                        Text("仅 抖音收藏").tag("douyin")
                    }
                    .frame(width: 220)

                    HStack(spacing: 6) {
                        Text("上限")
                            .font(.subheadline)
                        TextField("", value: $backfillMaxItems, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 72)
                        Stepper("", value: $backfillMaxItems, in: 50...5000, step: 100)
                            .labelsHidden()
                        Text("条")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if model.state.status == "running_backfill" || model.isBusy {
                        Button("发送安全停止信号") {
                            model.requestStopBackfill()
                        }
                        .tint(.red)
                    }
                    Button("开始慢速补采") {
                        model.startBackfill(source: backfillSource, maxItems: backfillMaxItems)
                    }
                    .disabled(model.isBusy)
                }
            }

            sectionCard("环境与全链路诊断 (Doctor)") {
                if model.doctorChecks.isEmpty {
                    HStack {
                        Text("点击右上角「全链路体检」将逐项检查配置文件权限、ego-browser、云端 API、Koofr WebDAV 读写与 Instabox 状态。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.doctorChecks) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: item.ok ? "checkmark.circle.fill" : (item.critical ? "xmark.circle.fill" : "exclamationmark.circle.fill"))
                                    .foregroundStyle(item.ok ? .green : (item.critical ? .red : .orange))
                                Text(item.check)
                                    .font(.system(.subheadline, design: .monospaced).weight(.medium))
                                    .frame(width: 170, alignment: .leading)
                                Text(item.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Spacer()
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func overviewCard(platform: String, subtitle: String, enabled: Bool) -> some View {
        let src = model.state.sources[platform]
        let saved = src?.saved ?? 0
        let known = src?.known.count ?? 0
        let outbox = src?.outbox?.count ?? 0

        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(SourceNames.displayName(for: platform))
                        .font(.headline)
                    Spacer()
                    Button("同步") {
                        model.syncNow(source: platform)
                    }
                    .controlSize(.small)
                    .disabled(model.isBusy)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Divider()
                HStack {
                    metricPill(title: "累计入库", value: "\(saved)")
                    Spacer()
                    metricPill(title: "去重水位", value: "\(known)")
                    Spacer()
                    metricPill(title: "待重传", value: "\(outbox)", highlight: outbox > 0)
                }
            }
            .padding(4)
            .opacity(enabled ? 1.0 : 0.65)
        }
    }

    @ViewBuilder
    private func metricPill(title: String, value: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(highlight ? .orange : .primary)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 2. Cloud & Network Proxy

    private var cloudPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("云端接收端与网络代理")
                .font(.title2.bold())

            sectionCard(
                "云端 Bo-Distiller 接收服务",
                subtitle: "本机抓取到的推文、收藏与视频口播全文将通过 HTTPS Bearer 鉴权推送到此地址。"
            ) {
                textSettingRow(
                    title: "云端地址 (REMOTE_PUSH_URL)",
                    placeholder: "https://distiller.example.com",
                    text: $model.config.remotePushURL,
                    monospaced: true
                )

                secretSettingRow(
                    title: "Ingest Bearer Token",
                    hint: "(对应云端 INGEST_TOKEN)",
                    placeholder: "粘贴云端 Bearer 鉴权密钥",
                    text: $model.config.remoteIngestToken,
                    revealed: $revealCloudToken
                )

                HStack(spacing: 10) {
                    Button("测试云端 API 连通性") {
                        model.testCloudConnection()
                    }
                    if let url = URL(string: model.config.remotePushURL), !model.config.remotePushURL.isEmpty {
                        Button("在浏览器打开云端面板") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    if let status = model.cloudTestStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(status.hasPrefix("✓") ? .green : .orange)
                            .textSelection(.enabled)
                    }
                }
            }

            sectionCard(
                "网络代理策略",
                subtitle: "原生 URLSession 默认自动继承 macOS 系统代理（Surge / Clash），也可指定独立 HTTP 代理端口。"
            ) {
                HStack {
                    Text("代理模式")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Picker("", selection: $model.config.proxyMode) {
                        ForEach(NetworkProxyMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 320)
                }

                if model.config.proxyMode == .custom {
                    Divider()
                    HStack(spacing: 14) {
                        textSettingRow(
                            title: "HTTP 代理主机",
                            placeholder: "127.0.0.1",
                            text: $model.config.customProxyHost,
                            monospaced: true
                        )
                        intSettingRow(
                            title: "端口",
                            value: $model.config.customProxyPort,
                            range: 1...65535,
                            step: 1,
                            unit: ""
                        )
                        .frame(width: 210)
                    }
                }
            }
        }
    }

    // MARK: - 3. Edge Sources Configuration

    private var localMonitorHandlesList: [String] {
        XMonitorFilter.parseHandles(model.config.xMonitorLocalHandles)
    }

    private func appendLocalMonitorHandle() {
        let parsedNew = XMonitorFilter.parseHandles(newHandleDraft)
        guard !parsedNew.isEmpty else { return }
        var existing = localMonitorHandlesList
        for h in parsedNew where !existing.contains(h) {
            existing.append(h)
        }
        model.config.xMonitorLocalHandles = existing.map { "@\($0)" }.joined(separator: ", ")
        newHandleDraft = ""
    }

    private func removeLocalMonitorHandle(_ handle: String) {
        let remaining = localMonitorHandlesList.filter { $0 != handle }
        model.config.xMonitorLocalHandles = remaining.map { "@\($0)" }.joined(separator: ", ")
    }

    private var sourcesPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("边缘采集源配置")
                .font(.title2.bold())

            sectionCard("X (Twitter) 书签采集") {
                toggleSettingRow(
                    title: "启用定时采集 X 书签",
                    hint: "通过本机 ego-lite 被动捕获 Bookmarks GraphQL 流与长推文",
                    isOn: $model.config.xBookmarksEnabled
                )
                Divider()
                intSettingRow(
                    title: "单次增量最多抓取",
                    hint: "遇到已采集推文 ID 自动提前停机",
                    value: $model.config.syncMaxItemsX,
                    range: 5...200,
                    step: 5,
                    unit: "条"
                )
                Divider()
                toggleSettingRow(
                    title: "短推文或架构图/速查表自动调用视觉模型 (VLM) 提取文字",
                    isOn: $model.config.xExtractInfographics
                )
            }

            sectionCard("抖音收藏夹采集") {
                toggleSettingRow(
                    title: "启用定时采集抖音收藏",
                    hint: "图文笔记自动调用 VLM 提取卡片文字，无字幕视频直传 Koofr 转写",
                    isOn: $model.config.douyinEnabled
                )
                Divider()
                intSettingRow(
                    title: "单次增量最多抓取",
                    value: $model.config.syncMaxItemsDouyin,
                    range: 5...100,
                    step: 5,
                    unit: "条"
                )
                Divider()
                textSettingRow(
                    title: "指定收藏夹名称或 ID",
                    hint: "（选填，留空默认采集全部收藏）",
                    placeholder: "例如：AI 干货 或 7382910384719283（留空采集全部视频收藏）",
                    text: $model.config.douyinCollectsId
                )
                Divider()
                intSettingRow(
                    title: "无字幕视频最长允许转写时长",
                    value: $model.config.maxDurationMin,
                    range: 3...120,
                    step: 5,
                    unit: "分钟"
                )
                Divider()
                intSettingRow(
                    title: "单视频最大允许体积",
                    value: $model.config.maxVideoMB,
                    range: 20...500,
                    step: 10,
                    unit: "MB"
                )
            }

            sectionCard(
                "X 指定用户监控（本机 ego-lite 抓取 + 推送 bo-distiller）",
                subtitle: "云端 API 轮询保留在云端执行；本机仅通过 ego-lite 访问 X List 或博主主页抓取新推文并推送至 bo-distiller。"
            ) {
                toggleSettingRow(
                    title: "在本机启用 ego-lite 博主监控巡检",
                    isOn: $model.config.xMonitorEnabled
                )
                Divider()

                textSettingRow(
                    title: "绑定 X List 链接或数字 ID",
                    hint: "（选填，强烈推荐：把监控博主放进同一个私有 X List，ego-lite 打开一页即可扫完所有人）",
                    placeholder: "例如：https://x.com/i/lists/1829384756192837 或纯数字 ID（留空则逐个访问博主主页）",
                    text: $model.config.xMonitorListURL,
                    monospaced: true
                )

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    textSettingRow(
                        title: "本机额外监控博主",
                        hint: "（选填，支持 @handle 逗号/空格分隔，与云端已启用列表自动合并去重）",
                        placeholder: "例如：@karpathy, @sama, @elonmusk",
                        text: $model.config.xMonitorLocalHandles,
                        monospaced: true
                    )

                    HStack(spacing: 8) {
                        TextField("", text: $newHandleDraft, prompt: Text("快速添加单个或多个 @handle，回车即可加入"))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                appendLocalMonitorHandle()
                            }
                        Button("添加博主") {
                            appendLocalMonitorHandle()
                        }
                        .disabled(newHandleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if !localMonitorHandlesList.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(localMonitorHandlesList, id: \.self) { h in
                                    HStack(spacing: 4) {
                                        Text("@\(h)")
                                            .font(.system(.caption, design: .monospaced).weight(.medium))
                                        Button {
                                            removeLocalMonitorHandle(h)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                                }
                            }
                        }
                    }
                }

                Divider()
                intSettingRow(
                    title: "单博主每次最多捕获",
                    value: $model.config.xMonitorMaxItemsPerUser,
                    range: 5...100,
                    step: 5,
                    unit: "条"
                )
                Divider()
                intSettingRow(
                    title: "无附件纯文本最短保留字数",
                    hint: "自动过滤纯表情/寒暄/无外链无配图的超短碎碎念",
                    value: $model.config.xMonitorDefaultMinLength,
                    range: 0...200,
                    step: 5,
                    unit: "字"
                )
                Divider()
                toggleSettingRow(
                    title: "监控推文配图自动调用 VLM 提取信息图",
                    isOn: $model.config.xMonitorExtractInfographics
                )
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("云端已启用监控博主 (\(model.cloudMonitoredUsers.count) 位)")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Button("从云端刷新博主列表") {
                            model.refreshCloudMonitoredUsers()
                        }
                        .controlSize(.small)
                    }
                    if model.cloudMonitoredUsers.isEmpty {
                        Text("若云端尚未添加监控账号，可直接在上方「本机额外监控博主」填写 @handle，或在云端添加后点击右侧刷新。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.cloudMonitoredUsers) { u in
                            HStack {
                                Text("@\(u.handle)")
                                    .font(.system(.caption, design: .monospaced).bold())
                                if !u.displayName.isEmpty {
                                    Text(u.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if !u.tags.isEmpty {
                                    Text(u.tags.joined(separator: " · "))
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                                }
                                Spacer()
                                Text("累计 \(u.totalCaptured) 条 · 水位 \(u.lastTweetId.isEmpty ? "待初始化" : u.lastTweetId.suffix(6))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 4. ASR & VLM Multimodal

    private var multimodalPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("语音转写 (ASR) 与视觉提取 (VLM)")
                .font(.title2.bold())

            sectionCard("抖音无字幕视频口播转写 (ASR)") {
                toggleSettingRow(
                    title: "启用无字幕视频语音转写",
                    isOn: $model.config.asrEnabled
                )
                Divider()
                HStack {
                    Text("ASR 转写通道")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Picker("", selection: $model.config.asrProvider) {
                        ForEach(AsrProviderMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 360)
                }

                Divider()

                if model.config.asrProvider == .instaboxKoofr {
                    textSettingRow(
                        title: "Koofr WebDAV 根地址",
                        placeholder: "https://app.koofr.net/dav/Koofr",
                        text: $model.config.koofrWebdavURL,
                        monospaced: true
                    )
                    textSettingRow(
                        title: "Koofr 登录邮箱",
                        placeholder: "your-email@gmail.com",
                        text: $model.config.koofrEmail,
                        monospaced: true
                    )
                    secretSettingRow(
                        title: "Koofr 应用专用密码",
                        hint: "(Koofr 网页端 Preferences -> Password -> App Passwords 生成)",
                        placeholder: "16 位应用专用密码",
                        text: $model.config.koofrAppPassword,
                        revealed: $revealKoofrPass
                    )
                    HStack(spacing: 14) {
                        textSettingRow(
                            title: "网盘子目录 (ASR/inbox/<subdir>)",
                            placeholder: "bo-distiller",
                            text: $model.config.koofrSubdir,
                            monospaced: true
                        )
                        textSettingRow(
                            title: "Instabox 沙箱名",
                            placeholder: "box-xxxxxx",
                            text: $model.config.instaboxAsrBox,
                            monospaced: true
                        )
                    }
                    HStack(spacing: 14) {
                        textSettingRow(
                            title: "沙箱 systemd 服务名",
                            placeholder: "bo-distiller-asr.service",
                            text: $model.config.instaboxAsrService,
                            monospaced: true
                        )
                        textSettingRow(
                            title: "instabox CLI 路径",
                            hint: "(留空自动探测)",
                            placeholder: "默认自动探测 ~/.local/bin/instabox",
                            text: $model.config.instaboxBin,
                            monospaced: true
                        )
                    }

                    HStack(spacing: 10) {
                        Button("测试 Koofr WebDAV 与 Instabox 状态") {
                            model.testKoofrConnection()
                        }
                        if let status = model.koofrTestStatus {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(status.hasPrefix("✓") ? .green : .orange)
                                .textSelection(.enabled)
                        }
                    }
                } else {
                    Text("使用 macOS 原生 AVFoundation 在本机直接提取 .m4a 音轨（无需安装 ffmpeg），同步上传至 OpenAI 兼容语音转写接口。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    textSettingRow(
                        title: "ASR API Base",
                        placeholder: "https://api.siliconflow.cn/v1",
                        text: $model.config.asrApiBase,
                        monospaced: true
                    )
                    secretSettingRow(
                        title: "ASR API Key",
                        placeholder: "粘贴语音转写服务 API Key",
                        text: $model.config.asrApiKey,
                        revealed: $revealAsrKey
                    )
                    textSettingRow(
                        title: "ASR 模型名",
                        placeholder: "FunAudioLLM/SenseVoiceSmall",
                        text: $model.config.asrModel,
                        monospaced: true
                    )
                    intSettingRow(
                        title: "ASR 请求超时",
                        value: $model.config.asrTimeout,
                        range: 30...600,
                        step: 30,
                        unit: "秒"
                    )
                }
            }

            sectionCard("轻量视觉大模型 (VLM · 抖音图文卡片与 X 信息图)") {
                toggleSettingRow(
                    title: "启用多模态图片文字与结构提取",
                    isOn: $model.config.vlmEnabled
                )
                Divider()
                textSettingRow(
                    title: "VLM API Base (OpenAI 兼容)",
                    placeholder: "https://api.openai.com/v1",
                    text: $model.config.vlmApiBase,
                    monospaced: true
                )
                secretSettingRow(
                    title: "VLM API Key",
                    placeholder: "粘贴视觉模型 API Key",
                    text: $model.config.vlmApiKey,
                    revealed: $revealVlmKey
                )
                textSettingRow(
                    title: "VLM 模型名",
                    placeholder: "gpt-4o-mini / qwen-vl-max",
                    text: $model.config.vlmModel,
                    monospaced: true
                )
                intSettingRow(
                    title: "VLM 请求超时",
                    value: $model.config.vlmTimeout,
                    range: 20...300,
                    step: 10,
                    unit: "秒"
                )

                HStack(spacing: 10) {
                    Button("测试视觉模型连通性") {
                        model.testVLMConnection()
                    }
                    if let status = model.vlmTestStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(status.hasPrefix("✓") ? .green : .orange)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    // MARK: - 5. Browser, L2 Bridge, LaunchAgent & Self-Healing

    private var runtimePane: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("浏览器、油猴桥接、定时服务与异常自愈")
                .font(.title2.bold())

            sectionCard("ego-lite (ego-browser) 独立工作区") {
                textSettingRow(
                    title: "专属 TaskSpace 名称",
                    hint: "(后台自动复用同一工作区，避免污染日常浏览标签页)",
                    placeholder: "bo-collector",
                    text: $model.config.egoSpaceName,
                    monospaced: true
                )
                textSettingRow(
                    title: "ego-browser 可执行路径",
                    hint: "(留空自动查找 ~/.local/bin/ego-browser)",
                    placeholder: "默认自动探测",
                    text: $model.config.egoBin,
                    monospaced: true
                )
            }

            sectionCard(
                "L2 油猴脚本本地伴随桥接",
                subtitle: "日常在浏览器刷 X 或抖音时，油猴脚本可直接把网络流推给本机 127.0.0.1 桥接端口自动入库，无需启动本地 bo-distiller。"
            ) {
                toggleSettingRow(
                    title: "在菜单栏运行时开启本地 HTTP 桥接服务",
                    isOn: $model.config.bridgeEnabled
                )
                Divider()
                HStack(spacing: 14) {
                    textSettingRow(
                        title: "绑定地址",
                        placeholder: "127.0.0.1",
                        text: $model.config.bridgeHost,
                        monospaced: true
                    )
                    intSettingRow(
                        title: "监听端口",
                        value: $model.config.bridgePort,
                        range: 1024...65535,
                        step: 1,
                        unit: ""
                    )
                    .frame(width: 220)
                }
                textSettingRow(
                    title: "本地桥接校验 Token",
                    hint: "(选填，本机回环默认留空免密)",
                    placeholder: "留空即可免密接收本机油猴脚本请求",
                    text: $model.config.bridgeToken,
                    monospaced: true
                )

                HStack {
                    Circle()
                        .fill(model.bridgeRunning ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(model.bridgeRunning ? "正在监听 http://127.0.0.1:\(model.bridgePort)" : "当前未启动")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("在浏览器打开安装油猴脚本 (userscript.user.js)") {
                        model.openUserscriptURL()
                    }
                }
            }

            sectionCard("macOS 原生定时巡检服务 (LaunchAgent: com.bo.collector)") {
                toggleSettingRow(
                    title: "开机自动加载并定时运行原生 CLI (bo-collect)",
                    hint: "跑完即退，空闲时 0 内存驻留",
                    isOn: Binding(
                        get: { model.launchAgent.loaded },
                        set: { model.toggleLaunchAgent($0) }
                    )
                )
                Divider()
                intSettingRow(
                    title: "定时巡检间隔",
                    hint: "(推荐 1800 秒 = 30 分钟；保存配置后自动同步更新 LaunchAgent)",
                    value: $model.config.syncIntervalSeconds,
                    range: 300...86400,
                    step: 300,
                    unit: "秒"
                )
                if !model.launchAgent.binaryPath.isEmpty {
                    HStack {
                        Text("当前注册可执行程序")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(model.launchAgent.binaryPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            sectionCard("连续异常告警与 Orca Agent 自动自愈") {
                textSettingRow(
                    title: "orca CLI 路径或命令名",
                    placeholder: "/Applications/Orca.app/Contents/Resources/bin/orca",
                    text: $model.config.orcaBin,
                    monospaced: true
                )
                textSettingRow(
                    title: "Orca 自愈 Automation ID",
                    hint: "(连续 ≥2 次非网络异常时写入脱敏 incident.json 并唤醒修复)",
                    placeholder: "例如：02756aed-a394-42eb-a474-24087308b5b8（留空仅发通知不唤醒 Agent）",
                    text: $model.config.orcaHealAutomationId,
                    monospaced: true
                )
                intSettingRow(
                    title: "自愈唤醒冷却时间",
                    value: $model.config.healCooldownSeconds,
                    range: 600...86400,
                    step: 600,
                    unit: "秒"
                )
            }
        }
    }

    // MARK: - 6. Logs & Incident Snapshot

    private var logsPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("运行日志与故障快照")
                    .font(.title2.bold())
                Spacer()
                Button("刷新日志") {
                    model.reloadDiskSnapshots()
                }
                Button("在 Finder 打开状态与日志目录") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.savedConfig.stateDir])
                }
            }

            sectionCard("collector.log（最近 \(model.logLines.count) 行 · 自动脱敏轮转）") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if model.logLines.isEmpty {
                            Text("暂无日志记录")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(model.logLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(line.contains("[ERROR]") ? .red : (line.contains("[WARN]") ? .orange : .primary))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(minHeight: 280, maxHeight: 360)
            }

            if !model.incidentJSON.isEmpty {
                sectionCard("最近一次故障快照 (incident.json)") {
                    ScrollView {
                        Text(model.incidentJSON)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                    .frame(height: 150)
                }
            }
        }
    }

    private func pickBoDistillerFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择旧 bo-distiller 项目目录（读取 .env 与 config.yaml）"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Code")
        if panel.runModal() == .OK, let url = panel.url {
            model.importFromBoDistiller(directory: url)
        }
    }
}
