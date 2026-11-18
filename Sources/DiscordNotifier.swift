import Foundation

enum DiscordNotifier {
    struct SendResult {
        let success: Bool
        let message: String
    }

    static func sendAlert(
        webhookURLString: String,
        mention: String,
        customMessage: String,
        hostName: String,
        profileName: String,
        similarity: Float,
        deviceName: String,
        includeSimilarity: Bool,
        isTest: Bool = false
    ) async -> SendResult {
        let trimmedURL = webhookURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            return SendResult(success: false, message: "Webhook URLが未設定です")
        }
        guard let url = URL(string: trimmedURL),
              url.scheme == "https" || url.scheme == "http" else {
            return SendResult(success: false, message: "Webhook URLの形式が正しくありません")
        }

        let effectiveHost = hostName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "Mac")
            : hostName.trimmingCharacters(in: .whitespacesAndNewlines)

        let formatter = ISO8601DateFormatter()
        let isoNow = formatter.string(from: Date())
        let simPercent = Int(round(similarity * 100))

        let trimmedMention = mention.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleText = isTest
            ? "🔔 SoundAlert テスト通知"
            : "🚨 \(customMessage.isEmpty ? "登録されたサウンドを検知しました！" : customMessage)"

        let contentText: String
        if trimmedMention.isEmpty {
            contentText = titleText
        } else {
            contentText = "\(trimmedMention) \(titleText)"
        }

        var fields: [[String: Any]] = [
            [
                "name": "検知したサウンド",
                "value": "**\(profileName)**",
                "inline": true
            ],
            [
                "name": "検知元デバイス",
                "value": "`\(effectiveHost)`",
                "inline": true
            ],
            [
                "name": "入力マイク",
                "value": "`\(deviceName)`",
                "inline": true
            ]
        ]

        if includeSimilarity {
            fields.append([
                "name": "一致度スコア",
                "value": "**\(simPercent)%**",
                "inline": true
            ])
        }

        let embed: [String: Any] = [
            "title": isTest ? "Discord通知テスト成功" : "サウンド検知アラート",
            "description": isTest
                ? "\(effectiveHost) (\(deviceName)) からのDiscord通知連携が正常に動作しています。"
                : "\(effectiveHost) のマイクが登録済みのアラート音を検知しました。",
            "color": isTest ? 0x5865F2 : 0xED4245,
            "fields": fields,
            "timestamp": isoNow,
            "footer": [
                "text": "SoundAlert"
            ]
        ]

        let payload: [String: Any] = [
            "username": "SoundAlert (\(effectiveHost))",
            "content": contentText,
            "embeds": [embed]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else {
            return SendResult(success: false, message: "JSONエンコードに失敗しました")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = 10.0

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                if (200...299).contains(http.statusCode) {
                    return SendResult(success: true, message: "送信成功 (HTTP \(http.statusCode))")
                } else {
                    return SendResult(success: false, message: "Discordエラー (HTTP \(http.statusCode))")
                }
            }
            return SendResult(success: true, message: "送信完了")
        } catch {
            return SendResult(success: false, message: "通信エラー: \(error.localizedDescription)")
        }
    }
}
