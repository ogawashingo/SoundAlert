import SwiftUI

struct MainContentView: View {
    @ObservedObject var engine: AudioMonitorEngine
    @State private var selectedTab: Int = 0
    @State private var showingCustomRecorder: Bool = false
    @State private var addingSampleToProfile: SoundProfile? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Top Header & Live Microphone Visualizer
            HeaderMonitorBar(engine: engine)

            // Alert Flash Banner when a sound is detected
            if let alert = engine.activeAlertBanner {
                AlertBannerView(event: alert) {
                    engine.activeAlertBanner = nil
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Divider()

            // Main Tab Selector
            HStack(spacing: 12) {
                TabButton(
                    title: "サウンド認識 (\(engine.profiles.filter(\.isEnabled).count))",
                    icon: "waveform.badge.magnifyingglass",
                    isSelected: selectedTab == 0
                ) { selectedTab = 0 }

                TabButton(
                    title: "Discord通知設定",
                    icon: "bell.badge.fill",
                    badgeWarning: engine.settings.discordWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    isSelected: selectedTab == 1
                ) { selectedTab = 1 }

                TabButton(
                    title: "検知履歴 (\(engine.detectionHistory.count))",
                    icon: "clock.arrow.circlepath",
                    isSelected: selectedTab == 2
                ) { selectedTab = 2 }

                Spacer()

                Button {
                    addingSampleToProfile = nil
                    engine.beginCustomSoundSession()
                    showingCustomRecorder = true
                } label: {
                    Label("新しいサウンドを録音して登録", systemImage: "mic.badge.plus")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Tab Content
            Group {
                switch selectedTab {
                case 0:
                    SoundProfilesTabView(
                        engine: engine,
                        onOpenNewRecorder: {
                            addingSampleToProfile = nil
                            engine.beginCustomSoundSession()
                            showingCustomRecorder = true
                        },
                        onAddSampleToProfile: { profile in
                            addingSampleToProfile = profile
                            engine.beginCustomSoundSession()
                            showingCustomRecorder = true
                        }
                    )
                case 1:
                    DiscordSettingsTabView(engine: engine)
                default:
                    DetectionHistoryTabView(engine: engine)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 620)
        .sheet(isPresented: $showingCustomRecorder) {
            CustomSoundRecorderSheet(
                engine: engine,
                targetProfile: addingSampleToProfile,
                isPresented: $showingCustomRecorder
            )
        }
    }
}

struct AlertBannerView: View {
    let event: DetectionEvent
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.and.waves.left.and.right.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 2) {
                Text("🚨 \(event.profileName) を検知しました！ (一致度: \(Int(round(event.similarity * 100)))%)")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Text("Discord通知ステータス: \(event.discordStatusMessage)")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.9))
            }

            Spacer()

            Button("閉じる") {
                onDismiss()
            }
            .buttonStyle(.bordered)
            .tint(.white)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color.red)
    }
}

struct TabButton: View {
    let title: String
    let icon: String
    var badgeWarning: Bool = false
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                    .fontWeight(isSelected ? .semibold : .regular)
                if badgeWarning {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.orange)
                        .help("Discord Webhook URLが未設定です")
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .foregroundColor(isSelected ? .accentColor : .primary)
        }
        .buttonStyle(.plain)
    }
}
