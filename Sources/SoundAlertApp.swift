import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onWillTerminate: (() -> Void)?

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

    func applicationWillTerminate(_ notification: Notification) {
        onWillTerminate?()
    }
}

@main
struct SoundAlertApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var engine = AudioMonitorEngine()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("SoundAlert", id: "main") {
            MainContentView(engine: engine)
                .onAppear {
                    let targetEngine = engine
                    appDelegate.onWillTerminate = { [weak targetEngine] in
                        targetEngine?.flushPendingSaves()
                    }
                }
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
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }

                Button("SoundAlertを終了") {
                    engine.flushPendingSaves()
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
