import SwiftUI

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
                        let isPlayingThis = engine.isPlayingPreview &&
                            (engine.playingFilename.map { profile.sampleWavFilenames.contains($0) } ?? false)
                        SoundProfileCard(
                            profile: $profile,
                            liveSimilarity: engine.liveSimilarities[profile.id] ?? 0.0,
                            peakSimilarity: engine.recentPeakSimilarities[profile.id] ?? 0.0,
                            isPlaying: isPlayingThis,
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

    @State private var isEditingName: Bool = false
    @State private var editingNameText: String = ""

    private func commitNameEdit() {
        let trimmed = editingNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            profile.name = trimmed
            onChanged()
        }
        isEditingName = false
    }

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
                        if isEditingName {
                            HStack(spacing: 4) {
                                TextField("サウンド名", text: $editingNameText)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 14, weight: .bold))
                                    .frame(maxWidth: 220)
                                    .onSubmit {
                                        commitNameEdit()
                                    }

                                Button {
                                    commitNameEdit()
                                } label: {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                        .font(.system(size: 16))
                                }
                                .buttonStyle(.plain)
                                .help("名前を保存")

                                Button {
                                    isEditingName = false
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                        .font(.system(size: 16))
                                }
                                .buttonStyle(.plain)
                                .help("キャンセル")
                            }
                        } else {
                            HStack(spacing: 6) {
                                Text(profile.name)
                                    .font(.system(size: 15, weight: .bold))

                                Button {
                                    editingNameText = profile.name
                                    isEditingName = true
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("サウンド名を変更")
                            }
                        }

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
