import Foundation

enum DiscordNotifier {
    struct SendResult {
        let success: Bool
        let message: String
    }

    private static let allowedHosts: Set<String> = [
        "discord.com",
        "discordapp.com",
        "ptb.discord.com",
        "canary.discord.com"
    ]

    private static let isoFormatter: ISO8601DateFormatter = {
        ISO8601DateFormatter()
    }()

    private struct AllowedMentions: Encodable {
        let parse: [String]
        let users: [String]?
        let roles: [String]?
    }

    private struct EmbedField: Encodable {
        let name: String
        let value: String
        let inline: Bool
    }

    private struct EmbedFooter: Encodable {
        let text: String
    }

    private struct Embed: Encodable {
        let title: String
        let description: String
        let color: Int
        let fields: [EmbedField]
        let timestamp: String
        let footer: EmbedFooter
    }

    private struct WebhookPayload: Encodable {
        let username: String
        let content: String
        let embeds: [Embed]
        let allowed_mentions: AllowedMentions
    }

    enum URLValidationResult {
        case valid(URL)
        case invalid(String)
    }

    static func validateWebhookURL(_ urlString: String) -> URLValidationResult {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .invalid("Webhook URLが未設定です")
        }
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              allowedHosts.contains(host) else {
            return .invalid("Discord公式のHTTPS Webhook URLを指定してください")
        }

        let pathComponents = url.pathComponents.filter { $0 != "/" }
        // Expected: ["api", "webhooks", "<id>", "<token>"] or ["api", "v10", "webhooks", "<id>", "<token>"]
        let isValidPath: Bool
        if pathComponents.count >= 4 && pathComponents[0] == "api" && pathComponents[1] == "webhooks" {
            isValidPath = !pathComponents[2].isEmpty && !pathComponents[3].isEmpty
        } else if pathComponents.count >= 5 && pathComponents[0] == "api" && pathComponents[2] == "webhooks" {
            isValidPath = !pathComponents[3].isEmpty && !pathComponents[4].isEmpty
        } else {
            isValidPath = false
        }

        guard isValidPath else {
            return .invalid("Webhook URLの形式が正しくありません")
        }

        return .valid(url)
    }

    private static func buildAllowedMentions(from mention: String) -> AllowedMentions {
        var parse: [String] = []
        if mention.contains("@everyone") || mention.contains("@here") {
            parse.append("everyone")
        }

        var users: [String] = []
        var roles: [String] = []

        if let userRegex = try? NSRegularExpression(pattern: #"<@!?(\d+)>"#) {
            let range = NSRange(mention.startIndex..., in: mention)
            for match in userRegex.matches(in: mention, range: range) {
                if let r = Range(match.range(at: 1), in: mention) {
                    users.append(String(mention[r]))
                }
            }
        }

        if let roleRegex = try? NSRegularExpression(pattern: #"<@&(\d+)>"#) {
            let range = NSRange(mention.startIndex..., in: mention)
            for match in roleRegex.matches(in: mention, range: range) {
                if let r = Range(match.range(at: 1), in: mention) {
                    roles.append(String(mention[r]))
                }
            }
        }

        return AllowedMentions(
            parse: parse,
            users: users.isEmpty ? nil : users,
            roles: roles.isEmpty ? nil : roles
        )
    }

    private static func escapeInlineCode(_ text: String) -> String {
        text.replacingOccurrences(of: "`", with: "'")
    }

    private static func escapeBold(_ text: String) -> String {
        text.replacingOccurrences(of: "*", with: "\\*")
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
        let url: URL
        switch validateWebhookURL(webhookURLString) {
        case .valid(let validURL):
            url = validURL
        case .invalid(let message):
            return SendResult(success: false, message: message)
        }

        let effectiveHost = hostName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "Mac")
            : hostName.trimmingCharacters(in: .whitespacesAndNewlines)

        let isoNow = isoFormatter.string(from: Date())
        let simPercent = Int(round(similarity * 100))

        let trimmedMention = mention.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleText = isTest
            ? "🔔 SoundAlert テスト通知"
            : "🚨 \(customMessage.isEmpty ? "登録されたサウンドを検知しました！" : customMessage)"

        let contentText = trimmedMention.isEmpty ? titleText : "\(trimmedMention) \(titleText)"

        var fields: [EmbedField] = [
            EmbedField(name: "検知したサウンド", value: "**\(escapeBold(profileName))**", inline: true),
            EmbedField(name: "検知元デバイス", value: "`\(escapeInlineCode(effectiveHost))`", inline: true),
            EmbedField(name: "入力マイク", value: "`\(escapeInlineCode(deviceName))`", inline: true)
        ]

        if includeSimilarity {
            fields.append(EmbedField(name: "一致度スコア", value: "**\(simPercent)%**", inline: true))
        }

        let embed = Embed(
            title: isTest ? "Discord通知テスト成功" : "サウンド検知アラート",
            description: isTest
                ? "\(effectiveHost) (\(deviceName)) からのDiscord通知連携が正常に動作しています。"
                : "\(effectiveHost) のマイクが登録済みのアラート音を検知しました。",
            color: isTest ? 0x5865F2 : 0xED4245,
            fields: fields,
            timestamp: isoNow,
            footer: EmbedFooter(text: "SoundAlert")
        )

        let payload = WebhookPayload(
            username: "SoundAlert (\(effectiveHost))",
            content: contentText,
            embeds: [embed],
            allowed_mentions: buildAllowedMentions(from: trimmedMention)
        )

        guard let bodyData = try? JSONEncoder().encode(payload) else {
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
