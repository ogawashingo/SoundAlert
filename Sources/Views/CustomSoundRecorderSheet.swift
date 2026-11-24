import SwiftUI

struct CustomSoundRecorderSheet: View {
    @ObservedObject var engine: AudioMonitorEngine
    let targetProfile: SoundProfile?
    @Binding var isPresented: Bool

    @State private var customName: String = "カスタムサウンド"
    @State private var selectedIcon: String = "bell.and.waves.left.and.right.fill"
    private let defaultThreshold: Float = 0.70

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
                    Text(targetProfile.map { "「\($0.name)」に実音サンプルを追加" } ?? "カスタムサウンドの録音・登録（iOS方式）")
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
                    engine.discardCustomSoundSession()
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
                            threshold: defaultThreshold
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
        .onDisappear {
            // Ensure any unsaved recorded WAV files are cleaned up if the sheet is dismissed
            if engine.recordedSamplesCount > 0 || engine.recordingState != .idle {
                engine.discardCustomSoundSession()
            }
        }
    }
}
