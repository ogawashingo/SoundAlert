import SwiftUI
import CoreAudio

struct HeaderMonitorBar: View {
    @ObservedObject var engine: AudioMonitorEngine

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
                    Image(systemName: "mic.fill")
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
            HStack(spacing: 20) {
                // Left: Microphone Level Meter & Noise Gate Calibration
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("マイク音量: \(Int(engine.currentRMSdB)) dB")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(engine.currentRMSdB >= engine.settings.minimumRMSdB ? .primary : .secondary)

                        Text("(検知する最小音量: \(Int(engine.settings.minimumRMSdB)) dB)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.red.opacity(0.85))

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
                        .fixedSize()
                        .help("現在の部屋の静けさに合わせて、生活音やエアコン等の環境ノイズを無視する音量しきい値を自動設定します")
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
                .frame(maxWidth: .infinity)

                // 40-band Tonal Peak Visualizer
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("周波数スペクトル")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)

                        Spacer()

                        if engine.currentRMSdB >= engine.settings.minimumRMSdB {
                            Text("● 解析中")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.indigo)
                        }
                    }
                    .frame(height: 14)
                    .help("300Hz〜5.2kHz の特徴的なアラート音周波数を表示します")

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
                .frame(width: 260)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color(NSColor.controlBackgroundColor))
    }
}
