import AppKit
import BoCollectorCore
import SwiftUI

@MainActor
enum AppWindowCoordinator {
    static func activateForControlWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.canBecomeKey && window.isVisible {
                if window.title.contains("BoCollector") {
                    window.makeKeyAndOrderFront(nil)
                    break
                }
            }
        }
    }

    static func restoreAccessoryIfNoControlWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let hasVisibleMainWindow = NSApp.windows.contains { win in
                win.isVisible && win.title.contains("BoCollector")
            }
            if !hasVisibleMainWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = img
        }
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct BoCollectorMainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("BoCollector", systemImage: model.statusSymbolName) {
            MenuBarView(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("BoCollector 控制台与配置", id: "control-center") {
            ControlCenterView(model: model)
                .frame(minWidth: 900, minHeight: 640)
                .onAppear {
                    AppWindowCoordinator.activateForControlWindow()
                }
                .onDisappear {
                    AppWindowCoordinator.restoreAccessoryIfNoControlWindow()
                }
        }
        .defaultSize(width: 980, height: 700)
        .commands {
            TextEditingCommands()
        }
    }
}
