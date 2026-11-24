import SwiftUI

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
                                Text(String(format: "検知する最小音量（これ以下の生活音・雑音は無視）: %.0f dB", engine.settings.minimumRMSdB))
                                    .font(.system(size: 13, weight: .medium))
                                Text("現在のマイク音量: \(Int(engine.currentRMSdB)) dB（上部メーターの目印ラインを上回ると音を判定します）")
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
    @State private var showPlain: Bool = false

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
