import SwiftUI

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
                        engine.clearDetectionHistory()
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
