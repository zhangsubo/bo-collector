import AppKit
import BoCollectorCore
import SwiftUI

struct MenuBarView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: model.statusSymbolName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("BoCollector 原生边缘采集")
                        .font(.headline)
                    Text(model.statusHeadline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if model.isAuthPaused {
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(.orange)
                    Text(model.state.healer?.authReason ?? "平台需要人工登录或完成验证")
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                    Button("恢复同步") {
                        model.resumeAndSync()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            }

            Divider()

            // Source Counters
            VStack(spacing: 6) {
                sourceRow(platform: "x_bookmarks", icon: "bookmark.fill", enabled: model.savedConfig.xBookmarksEnabled)
                sourceRow(platform: "douyin", icon: "play.rectangle.fill", enabled: model.savedConfig.douyinEnabled)
                sourceRow(platform: "x_monitor", icon: "person.wave.2.fill", enabled: model.savedConfig.xMonitorEnabled)
            }

            if let asr = model.state.asr, (asr.stillPending > 0 || asr.completed > 0) {
                HStack {
                    Label("待回收语音稿: \(asr.stillPending) 篇（上次补齐 \(asr.completed) 篇）", systemImage: "waveform")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("回收") {
                        model.harvestNow()
                    }
                    .controlSize(.mini)
                    .disabled(model.isBusy)
                }
            }

            Divider()

            // Quick Sync Actions
            HStack(spacing: 8) {
                Button {
                    model.syncNow(source: "all")
                } label: {
                    Label("立即增量同步", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)

                Menu {
                    Button("仅同步 X 书签") { model.syncNow(source: "x_bookmarks") }
                    Button("仅同步 抖音收藏") { model.syncNow(source: "douyin") }
                    Button("仅同步 X 用户监控") { model.syncNow(source: "x_monitor") }
                    Divider()
                    Button("强制忽略暂停重试") { model.syncNow(source: "all", force: true) }
                    Button("仅从 Koofr 回收语音稿") { model.harvestNow(cloudMode: false) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .frame(width: 34)
                .disabled(model.isBusy)
            }

            // Toggles: LaunchAgent & L2 Bridge
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { model.launchAgent.loaded },
                    set: { model.toggleLaunchAgent($0) }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("后台定时自动巡检 (LaunchAgent)")
                            .font(.subheadline)
                        Text("每 \(model.savedConfig.syncIntervalSeconds / 60) 分钟运行一次，跑完即退 0 内存")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                HStack {
                    Toggle(isOn: Binding(
                        get: { model.savedConfig.bridgeEnabled },
                        set: { model.toggleBridge($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("L2 油猴伴随桥接 (:\(String(model.bridgePort)))")
                                .font(.subheadline)
                            Text(model.bridgeRunning ? "监听中 127.0.0.1:\(model.bridgePort)" : "未启用")
                                .font(.caption2)
                                .foregroundStyle(model.bridgeRunning ? .green : .secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    if model.bridgeRunning {
                        Button("装脚本") {
                            model.openUserscriptURL()
                        }
                        .controlSize(.mini)
                    }
                }
            }

            if let updated = model.state.updatedAt {
                Text("最近更新: \(updated)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            HStack {
                Button {
                    openWindow(id: "control-center")
                    AppWindowCoordinator.activateForControlWindow()
                } label: {
                    Label("打开控制台与全部配置…", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.link)

                Spacer()

                Button("退出菜单栏") {
                    model.stopBridgeServer()
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("退出菜单栏界面；若已开启 LaunchAgent，后台定时采集仍继续运行")
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private var statusColor: Color {
        if model.isBusy { return .accentColor }
        if model.isAuthPaused { return .orange }
        if model.state.status == "error" { return .red }
        return .green
    }

    @ViewBuilder
    private func sourceRow(platform: String, icon: String, enabled: Bool) -> some View {
        let src = model.state.sources[platform]
        let saved = src?.saved ?? 0
        let known = src?.known.count ?? 0
        let outbox = src?.outbox?.count ?? 0

        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundStyle(enabled ? .primary : .tertiary)
            Text(SourceNames.displayName(for: platform))
                .font(.subheadline)
                .foregroundStyle(enabled ? .primary : .secondary)
            if !enabled {
                Text("未启用")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
            Spacer()
            if outbox > 0 {
                Text("待传 \(outbox)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Text("已存 \(saved) · 水位 \(known)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
