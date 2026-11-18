import SwiftUI
import CoreAudio

struct MainContentView: View {
    @ObservedObject var engine: AudioMonitorEngine
    @State private var selectedTab: Int = 0
    @State private var showingCustomRecorder: Bool = false
    @State private var addingSampleToProfile: SoundProfile? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Top Header & Live Microphone Visualizer
            HeaderMonitorBar(
                engine: engine,
                onOpenCustomRecorder: {
                    addingSampleToProfile = nil
                    engine.beginCustomSoundSession()
                    showingCustomRecorder = true
                }
            )

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

// MARK: - Top Header with Device Picker & Live Spectrum

struct HeaderMonitorBar: View {
    @ObservedObject var engine: AudioMonitorEngine
    var onOpenCustomRecorder: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                // Status indicator circle
                ZStack {
                    Circle()
                        .fill(engine.isMonitoring ? Color.green.opacity(0.2) : Color.secondary.opacity(0.2))
                        .frame(width: 44, height: 44)
                    Image(systemName: engine.isMonitoring ? "ear.badge.waveform" : "mic.slash.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(engine.isMonitoring ? .green : .secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(engine.isMonitoring ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(engine.isMonitoring ? "リアルタイム音声認識 稼働中" : "音声認識 停止中")
                            .font(.system(size: 15, weight: .bold))
                    }
                    Text(engine.statusMessage)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Microphone Device Picker
                HStack(spacing: 6) {
                    Image(systemName: "web.camera.fill")
                        .foregroundColor(.accentColor)
                    Picker("入力マイク:", selection: Binding(
                        get: { engine.selectedDeviceID },
                        set: { newID in
                            if let dev = engine.inputDevices.first(where: { $0.id == newID }) {
                                engine.selectDevice(dev)
                            }
                        }
                    )) {
                        ForEach(engine.inputDevices) { dev in
                            Text("\(dev.name) (\(Int(dev.sampleRate))Hz)").tag(dev.id)
                        }
                    }
                    .frame(maxWidth: 270)

                    Button {
                        engine.refreshInputDevices()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("マイク一覧を更新")
                }

                // Start / Stop Button
                Button {
                    if engine.isMonitoring {
                        engine.stopMonitoring()
                    } else {
                        engine.startMonitoring()
                    }
                } label: {
                    Label(
                        engine.isMonitoring ? "監視を停止" : "監視を開始",
                        systemImage: engine.isMonitoring ? "stop.fill" : "play.fill"
                    )
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.isMonitoring ? .red.opacity(0.85) : .green)
            }

            // Live Audio Level + 40-Band Tonal Spectrum Visualizer
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("マイク音量: \(Int(engine.currentRMSdB)) dB")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(engine.currentRMSdB >= engine.settings.minimumRMSdB ? .primary : .secondary)

                        Text("(赤線ゲート: \(Int(engine.settings.minimumRMSdB)) dB)")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.red)

                        Spacer()

                        Button {
                            engine.calibrateNoiseGate()
                        } label: {
                            Label("今の静けさに合わせる", systemImage: "wand.and.stars")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.small)
                        .help("現在の部屋の環境音＋6dBに赤線（最小音量ゲート）を自動設定し、普段の環境音を遮断します")
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.secondary.opacity(0.18))
                            Capsule()
                                .fill(
                                    engine.currentRMSdB >= engine.settings.minimumRMSdB
                                        ? AnyShapeStyle(LinearGradient(
                                            colors: [.green, .yellow, .orange],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        ))
                                        : AnyShapeStyle(Color.secondary.opacity(0.45))
                                )
                                .frame(width: max(4, geo.size.width * CGFloat(engine.currentLevelNormalized)))

                            // Gate threshold line
                            let gateNorm = max(0.0, min(1.0, (engine.settings.minimumRMSdB + 65.0) / 55.0))
                            Rectangle()
                                .fill(Color.red)
                                .frame(width: 3, height: geo.size.height + 6)
                                .offset(x: geo.size.width * CGFloat(gateNorm))
                        }
                    }
                    .frame(height: 10)
                }
                .frame(width: 390)

                // 40-band Tonal Peak Visualizer
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("チャイム周波数スペクトル (300Hz - 5.2kHz)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        Spacer()
                        if engine.currentRMSdB >= engine.settings.minimumRMSdB {
                            Text("● 音声解析中")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.indigo)
                        } else {
                            Text("環境ノイズ遮断中（静寂）")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(0..<engine.liveSpectrum.count, id: \.self) { idx in
                            let val = CGFloat(engine.liveSpectrum[idx])
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(val > 0.35 ? Color.indigo : Color.accentColor.opacity(0.55))
                                .frame(height: max(2, 22 * val))
                        }
                    }
                    .frame(height: 22)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color(NSColor.controlBackgroundColor))
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

// MARK: - Tab 1: Sound Recognition Profiles

struct SoundProfilesTabView: View {
    @ObservedObject var engine: AudioMonitorEngine
    var onOpenNewRecorder: () -> Void
    var onAddSampleToProfile: (SoundProfile) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Tip box explaining iOS-style Custom Sound Recognition
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.indigo)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("iOS「カスタムサウンド認識」と同じ仕組みで、周囲で鳴る通知音・アラート音を検知します")
                            .font(.system(size: 13, weight: .bold))
                        Text("検知したい音を「新しいサウンドを録音して登録」（または各カードの「＋実音を追加録音」）で1〜3回マイクに聴かせるだけで、高精度に音響パターンを学習・検知します。")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineSpacing(2)
                    }
                    Spacer()
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.indigo.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.indigo.opacity(0.25), lineWidth: 1)
                        )
                )

                if engine.profiles.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "waveform.badge.plus")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary.opacity(0.6))
                        Text("登録されたサウンドがありません")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.secondary)
                        Text("右上の「新しいサウンドを録音して登録」ボタンから、\n検知したい通知音やチャイム音を録音してください。")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)

                        Button {
                            onOpenNewRecorder()
                        } label: {
                            Label("サウンドを録音して登録する", systemImage: "mic.badge.plus")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(NSColor.controlBackgroundColor))
                    )
                } else {
                    // Sound Profile Cards
                    ForEach($engine.profiles) { $profile in
                        SoundProfileCard(
                            profile: $profile,
                            liveSimilarity: engine.liveSimilarities[profile.id] ?? 0.0,
                            peakSimilarity: engine.recentPeakSimilarities[profile.id] ?? 0.0,
                            isPlaying: engine.isPlayingPreview && profile.sampleWavFilenames.contains(engine.playingFilename ?? ""),
                            onChanged: {
                                engine.saveProfiles()
                            },
                            onPlaySample: {
                                if let wav = profile.sampleWavFilenames.last {
                                    engine.playWavFile(named: wav)
                                }
                            },
                            onAddSample: {
                                onAddSampleToProfile(profile)
                            },
                            onDelete: {
                                engine.deleteProfile(profile)
                            }
                        )
                    }

                    HStack {
                        Button {
                            onOpenNewRecorder()
                        } label: {
                            Label("＋ 新しいサウンドを録音して追加", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.bordered)

                        Spacer()
                    }
                    .padding(.top, 4)
                }
            }
            .padding(18)
        }
    }
}

struct SoundProfileCard: View {
    @Binding var profile: SoundProfile
    let liveSimilarity: Float
    let peakSimilarity: Float
    let isPlaying: Bool
    var onChanged: () -> Void
    var onPlaySample: () -> Void
    var onAddSample: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: profile.icon)
                    .font(.system(size: 22))
                    .foregroundColor(profile.isEnabled ? .indigo : .secondary)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(profile.isEnabled ? Color.indigo.opacity(0.12) : Color.secondary.opacity(0.1))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(profile.name)
                            .font(.system(size: 15, weight: .bold))

                        Text("学習サンプル数: \(profile.sampleCount)")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.indigo.opacity(0.12)))
                            .foregroundColor(.indigo)
                    }

                    Text(String(format: "サンプル長: 約%.2f秒 / 検知しきい値: %d%%", profile.durationSeconds, Int(round(profile.threshold * 100))))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if !profile.sampleWavFilenames.isEmpty {
                    Button(action: onPlaySample) {
                        Label(
                            isPlaying ? "停止" : "登録音をテスト再生",
                            systemImage: isPlaying ? "stop.circle.fill" : "play.circle.fill"
                        )
                        .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .help("Macのスピーカーからこの音を鳴らして、USBカメラマイクが検知するかテストできます")
                }

                Button(action: onAddSample) {
                    Label("＋実音を追加録音", systemImage: "mic.badge.plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .help("別PCから鳴る実際の音をマイクで追加録音して、このサウンドの認識精度を高めます")

                Toggle("", isOn: $profile.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: profile.isEnabled) { onChanged() }

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundColor(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("このサウンドを削除")
            }

            // Live Similarity Meter & Threshold Slider
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("リアルタイム一致度: \(Int(round(liveSimilarity * 100)))%")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(liveSimilarity >= profile.threshold ? .red : .primary)

                    Text("(直近ピーク: \(Int(round(peakSimilarity * 100)))%)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)

                    Spacer()

                    Text("検知しきい値: \(Int(round(profile.threshold * 100)))%")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.indigo)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.secondary.opacity(0.15))

                        // Peak hold bar
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.indigo.opacity(0.28))
                            .frame(width: max(0, geo.size.width * CGFloat(peakSimilarity)))

                        // Live similarity bar
                        RoundedRectangle(cornerRadius: 5)
                            .fill(
                                liveSimilarity >= profile.threshold
                                    ? Color.red
                                    : Color.indigo
                            )
                            .frame(width: max(0, geo.size.width * CGFloat(liveSimilarity)))

                        // Threshold vertical marker
                        Rectangle()
                            .fill(Color.orange)
                            .frame(width: 3, height: geo.size.height + 4)
                            .offset(x: geo.size.width * CGFloat(profile.threshold))
                    }
                }
                .frame(height: 12)

                HStack(spacing: 8) {
                    Text("高感度 (45%)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(profile.threshold) },
                            set: { newVal in
                                profile.threshold = Float(newVal)
                                onChanged()
                            }
                        ),
                        in: 0.45...0.92,
                        step: 0.01
                    )
                    Text("厳密 (92%)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            liveSimilarity >= profile.threshold && profile.isEnabled
                                ? Color.red
                                : Color.secondary.opacity(0.2),
                            lineWidth: liveSimilarity >= profile.threshold && profile.isEnabled ? 2 : 1
                        )
                )
        )
    }
}

// MARK: - iOS-Style Custom Sound Recording Sheet

struct CustomSoundRecorderSheet: View {
    @ObservedObject var engine: AudioMonitorEngine
    let targetProfile: SoundProfile?
    @Binding var isPresented: Bool

    @State private var customName: String = "カスタムサウンド"
    @State private var selectedIcon: String = "bell.and.waves.left.and.right.fill"
    @State private var customThreshold: Float = 0.70

    private let icons = [
        "bell.and.waves.left.and.right.fill",
        "bubble.left.and.exclamationmark.bubble.right.fill",
        "phone.badge.waveform.fill",
        "speaker.wave.3.fill",
        "exclamationmark.triangle.fill"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 24))
                    .foregroundColor(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text(targetProfile == nil ? "カスタムサウンドの録音・登録（iOS方式）" : "「\(targetProfile!.name)」に実音サンプルを追加")
                        .font(.system(size: 17, weight: .bold))
                    Text("検知したい通知音やチャイム音をマイク（\(engine.currentDeviceName)）で聴き取って記憶します")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Divider()

            if targetProfile == nil {
                HStack(spacing: 12) {
                    Text("サウンド名:")
                        .font(.system(size: 13, weight: .medium))
                    TextField("例: チャット通知音、インターホン、タイマー", text: $customName)
                        .textFieldStyle(.roundedBorder)

                    Picker("アイコン", selection: $selectedIcon) {
                        ForEach(icons, id: \.self) { ic in
                            Image(systemName: ic).tag(ic)
                        }
                    }
                    .frame(width: 110)
                }
            }

            // Step-by-step recording box
            VStack(spacing: 14) {
                HStack {
                    ForEach(1...3, id: \.self) { step in
                        HStack(spacing: 6) {
                            Image(systemName: engine.recordedSamplesCount >= step ? "checkmark.circle.fill" : "circle.dashed")
                                .foregroundColor(engine.recordedSamplesCount >= step ? .green : .secondary)
                            Text("サンプル \(step)\(step == 1 ? " (必須)" : " (任意・精度向上)")")
                                .font(.system(size: 12, weight: engine.recordedSamplesCount >= step ? .semibold : .regular))
                        }
                        if step < 3 {
                            Spacer()
                        }
                    }
                }
                .padding(.horizontal, 12)

                Divider()

                // Recording Status & Controls
                switch engine.recordingState {
                case .idle:
                    VStack(spacing: 10) {
                        Text("ボタンを押してから、検知したい音（通知音や呼び出し音など）を鳴らしてください")
                            .font(.system(size: 13, weight: .medium))
                        HStack(spacing: 14) {
                            Button {
                                engine.startWaitingForSoundTrigger()
                            } label: {
                                Label("音が鳴ったら自動録音する（推奨）", systemImage: "ear.and.waveform")
                                    .font(.system(size: 13, weight: .semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.indigo)

                            Button {
                                engine.startImmediateCapture()
                            } label: {
                                Label("今すぐ手動録音 (1.6秒)", systemImage: "record.circle")
                                    .font(.system(size: 13))
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 10)

                case .waitingForSoundTrigger:
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.regular)
                        Text("耳を澄ませています... 検知したい音を鳴らしてください")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.indigo)
                        Text("現在のマイク音量: \(Int(engine.currentRMSdB)) dB（音が鳴ると自動で約1.6秒間キャプチャします）")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Button("キャンセル") {
                            engine.cancelCurrentCapture()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 8)

                case .capturing(let progress):
                    VStack(spacing: 10) {
                        ProgressView(value: progress)
                            .frame(width: 260)
                        Text("音をキャプチャ中... (\(Int(progress * 100))%)")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.red)
                    }
                    .padding(.vertical, 12)

                case .capturedPreview(let duration):
                    VStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 20))
                            Text(String(format: "サンプル %d を学習しました！（長さ: %.2f秒）", engine.recordedSamplesCount, duration))
                                .font(.system(size: 14, weight: .bold))
                        }

                        HStack(spacing: 12) {
                            Button {
                                engine.playLastCapturedPreview()
                            } label: {
                                Label("録音した音を再生して確認", systemImage: "play.fill")
                            }
                            .buttonStyle(.bordered)

                            Button {
                                engine.discardLastRecordedSample()
                            } label: {
                                Label("やり直す", systemImage: "arrow.counterclockwise")
                            }
                            .buttonStyle(.bordered)

                            if engine.recordedSamplesCount < 3 {
                                Button {
                                    engine.startWaitingForSoundTrigger()
                                } label: {
                                    Label("もう1回録音して精度を高める", systemImage: "plus.circle")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.indigo)
                            }
                        }
                    }
                    .padding(.vertical, 8)

                case .error(let msg):
                    VStack(spacing: 10) {
                        Text(msg)
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                        Button("もう一度試す") {
                            engine.recordingState = .idle
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 8)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.controlBackgroundColor))
            )

            // Footer buttons
            HStack {
                Button("キャンセル") {
                    engine.cancelCurrentCapture()
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Text("※1回の録音でも登録できます（最大3回まで登録可能）")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Button {
                    if let target = targetProfile {
                        engine.addRecordedSamplesToProfile(target.id)
                    } else {
                        engine.saveNewCustomProfile(
                            name: customName,
                            icon: selectedIcon,
                            threshold: customThreshold
                        )
                    }
                    isPresented = false
                } label: {
                    Text(targetProfile == nil ? "このサウンドを登録する" : "サンプルを追加して保存")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .disabled(engine.recordedSamplesCount == 0)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 580)
    }
}

// MARK: - Tab 2: Discord Webhook & Sensitivity Settings

struct DiscordSettingsTabView: View {
    @ObservedObject var engine: AudioMonitorEngine
    @State private var isTestingWebhook: Bool = false
    @State private var testFeedbackMessage: String = ""
    @State private var testFeedbackSuccess: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Discord Webhook Section
                GroupBox(label: Label("Discord チャンネル通知設定 (Webhook)", systemImage: "message.badge.waveform.fill").font(.system(size: 14, weight: .bold))) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Discordの通知を送りたいチャンネルの「チャンネルの編集 ＞ 連携サービス ＞ ウェブフック ＞ 新しいウェブフック」から「ウェブフックURLをコピー」して貼り付けてください。")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Discord Webhook URL:")
                                .font(.system(size: 12, weight: .semibold))
                            SecureWebhookField(text: $engine.settings.discordWebhookURL) {
                                engine.saveSettings()
                            }
                        }

                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("メンション指定（スマホへプッシュ通知を届けるために推奨）:")
                                    .font(.system(size: 12, weight: .semibold))
                                HStack(spacing: 8) {
                                    TextField("例: @here / @everyone / <@ユーザーID>", text: $engine.settings.discordMention)
                                        .textFieldStyle(.roundedBorder)
                                        .onChange(of: engine.settings.discordMention) {
                                            engine.saveSettings()
                                        }

                                    Button("@here") {
                                        engine.settings.discordMention = "@here"
                                        engine.saveSettings()
                                    }
                                    .buttonStyle(.bordered)

                                    Button("@everyone") {
                                        engine.settings.discordMention = "@everyone"
                                        engine.saveSettings()
                                    }
                                    .buttonStyle(.bordered)

                                    Button("なし") {
                                        engine.settings.discordMention = ""
                                        engine.saveSettings()
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("通知元ホスト名 / デバイス表示名:")
                                .font(.system(size: 12, weight: .semibold))
                            TextField("例: Mac mini, 自宅PC, オフィスMac", text: $engine.settings.hostName)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: engine.settings.hostName) {
                                    engine.saveSettings()
                                }
                            Text("DiscordのBot名やメッセージの送信元デバイス名として表示されます")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("通知メッセージ本文:")
                                .font(.system(size: 12, weight: .semibold))
                            TextField("登録されたサウンドを検知しました！", text: $engine.settings.customMessageText)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: engine.settings.customMessageText) {
                                    engine.saveSettings()
                                }
                        }

                        HStack(spacing: 12) {
                            Button {
                                sendTestWebhook()
                            } label: {
                                HStack(spacing: 6) {
                                    if isTestingWebhook {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "paperplane.fill")
                                    }
                                    Text("Discordにテスト通知を送信")
                                        .fontWeight(.semibold)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isTestingWebhook)

                            if !testFeedbackMessage.isEmpty {
                                HStack(spacing: 4) {
                                    Image(systemName: testFeedbackSuccess ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                        .foregroundColor(testFeedbackSuccess ? .green : .red)
                                    Text(testFeedbackMessage)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(testFeedbackSuccess ? .green : .red)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                    .padding(12)
                }

                // Detection Sensitivity & Cooldown Section
                GroupBox(label: Label("検知ルール・誤検知防止設定", systemImage: "slider.horizontal.3").font(.system(size: 14, weight: .bold))) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(String(format: "連続通知のクールダウン時間: %.0f 秒", engine.settings.cooldownSeconds))
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Slider(
                                value: Binding(
                                    get: { engine.settings.cooldownSeconds },
                                    set: { val in
                                        engine.settings.cooldownSeconds = val
                                        engine.saveSettings()
                                    }
                                ),
                                in: 3...60,
                                step: 1
                            )
                            .frame(width: 260)
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(format: "最小音量ゲート（これより小さい環境音は無視）: %.0f dB", engine.settings.minimumRMSdB))
                                    .font(.system(size: 13, weight: .medium))
                                Text("現在のマイク入力レベル: \(Int(engine.currentRMSdB)) dB（上部メーターの赤線がしきい値です）")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Slider(
                                value: Binding(
                                    get: { Double(engine.settings.minimumRMSdB) },
                                    set: { val in
                                        engine.settings.minimumRMSdB = Float(val)
                                        engine.saveSettings()
                                    }
                                ),
                                in: -62...(-20),
                                step: 1
                            )
                            .frame(width: 260)
                        }

                        Toggle("検知時にMacのDockアイコンをバウンスさせて画面上で知らせる", isOn: $engine.settings.flashWindowOnDetect)
                            .onChange(of: engine.settings.flashWindowOnDetect) { engine.saveSettings() }

                        Toggle("Discord通知に一致度スコア（%）を含める", isOn: $engine.settings.includeSimilarityInDiscord)
                            .onChange(of: engine.settings.includeSimilarityInDiscord) { engine.saveSettings() }
                    }
                    .padding(12)
                }
            }
            .padding(18)
        }
    }

    private func sendTestWebhook() {
        isTestingWebhook = true
        testFeedbackMessage = ""
        let settings = engine.settings
        let devName = engine.currentDeviceName
        Task {
            let res = await DiscordNotifier.sendAlert(
                webhookURLString: settings.discordWebhookURL,
                mention: settings.discordMention,
                customMessage: settings.customMessageText,
                hostName: settings.hostName,
                profileName: "テスト通知 (チャイム通知音)",
                similarity: 0.95,
                deviceName: devName,
                includeSimilarity: settings.includeSimilarityInDiscord,
                isTest: true
            )
            await MainActor.run {
                isTestingWebhook = false
                testFeedbackSuccess = res.success
                testFeedbackMessage = res.message
            }
        }
    }
}

struct SecureWebhookField: View {
    @Binding var text: String
    var onCommit: () -> Void
    @State private var showPlain: Bool = true

    var body: some View {
        HStack {
            if showPlain {
                TextField("https://discord.com/api/webhooks/...", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: text) { onCommit() }
            } else {
                SecureField("https://discord.com/api/webhooks/...", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: text) { onCommit() }
            }
            Button {
                showPlain.toggle()
            } label: {
                Image(systemName: showPlain ? "eye.slash" : "eye")
            }
            .buttonStyle(.bordered)
            .help("URLの表示/非表示を切り替え")
        }
    }
}

// MARK: - Tab 3: Detection History Log

struct DetectionHistoryTabView: View {
    @ObservedObject var engine: AudioMonitorEngine

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return df
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("検知されたアラート音の履歴（直近100件・録音データ付き）")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if !engine.detectionHistory.isEmpty {
                    Button("履歴をクリア") {
                        engine.detectionHistory.removeAll()
                        engine.saveHistory()
                    }
                    .font(.system(size: 12))
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)

            Divider()

            if engine.detectionHistory.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "waveform.slash")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("まだ検知履歴はありません")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("「サウンド認識」タブの「登録音をテスト再生」を押すと、検知動作とDiscord通知をすぐにテストできます。")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(engine.detectionHistory) { event in
                    HStack(spacing: 14) {
                        Image(systemName: "bell.badge.fill")
                            .foregroundColor(.red)
                            .font(.system(size: 18))

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(event.profileName)
                                    .font(.system(size: 14, weight: .bold))
                                Text("一致度: \(Int(round(event.similarity * 100)))%")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.indigo.opacity(0.15)))
                                    .foregroundColor(.indigo)
                            }
                            Text(Self.dateFormatter.string(from: event.timestamp))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        // Discord delivery badge
                        HStack(spacing: 4) {
                            Image(systemName: event.discordSent ? "checkmark.circle.fill" : "info.circle")
                                .foregroundColor(event.discordSent ? .green : .orange)
                            Text("Discord: \(event.discordStatusMessage)")
                                .font(.system(size: 12))
                                .foregroundColor(event.discordSent ? .green : .secondary)
                        }

                        // Replay button for captured audio
                        if let wav = event.capturedWavFilename {
                            let isPlayingThis = engine.isPlayingPreview && engine.playingFilename == wav
                            Button {
                                engine.playWavFile(named: wav)
                            } label: {
                                Label(isPlayingThis ? "停止" : "検知音を再生", systemImage: isPlayingThis ? "stop.fill" : "play.fill")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}
