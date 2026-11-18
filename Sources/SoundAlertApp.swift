import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = iconImage
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in the menu bar even if the main window is closed
        return false
    }
}

@main
struct SoundAlertApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var engine = AudioMonitorEngine()

    var body: some Scene {
        WindowGroup("SoundAlert") {
            MainContentView(engine: engine)
        }
        .windowStyle(.titleBar)

        MenuBarExtra(
            "SoundAlert",
            systemImage: engine.isMonitoring ? "ear.badge.waveform" : "mic.slash"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text(engine.isMonitoring ? "🟢 監視中: \(engine.currentDeviceName)" : "⚪️ 停止中")
                    .font(.headline)

                Divider()

                Button(engine.isMonitoring ? "監視を停止" : "監視を開始") {
                    if engine.isMonitoring {
                        engine.stopMonitoring()
                    } else {
                        engine.startMonitoring()
                    }
                }

                if let last = engine.detectionHistory.first {
                    Divider()
                    Text("直近の検知: \(last.profileName) (\(Int(round(last.similarity * 100)))%)")
                        .font(.caption)
                }

                Divider()

                Button("メイン画面を表示") {
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows {
                        window.makeKeyAndOrderFront(nil)
                    }
                }

                Button("SoundAlertを終了") {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
