import Foundation

final class StorageManager {
    let storageDir: URL
    private let profilesFileURL: URL
    private let settingsFileURL: URL
    private let historyFileURL: URL

    private let ioQueue = DispatchQueue(label: "com.soundalert.storage", qos: .utility)
    private var settingsSaveWorkItem: DispatchWorkItem?
    private var profilesSaveWorkItem: DispatchWorkItem?

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.storageDir = appSupport.appendingPathComponent("SoundAlert", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: storageDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storageDir.path)

        self.profilesFileURL = storageDir.appendingPathComponent("profiles.json")
        self.settingsFileURL = storageDir.appendingPathComponent("settings.json")
        self.historyFileURL = storageDir.appendingPathComponent("history.json")
    }

    // MARK: - Safe File Helpers

    /// Validates that a filename resolves strictly inside `storageDir` (prevents path traversal)
    func safeFileURL(for filename: String) -> URL? {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              (trimmed as NSString).lastPathComponent == trimmed else {
            return nil
        }
        let candidate = storageDir.appendingPathComponent(trimmed).standardizedFileURL
        let basePath = storageDir.standardizedFileURL.path
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        guard candidate.path.hasPrefix(prefix) else { return nil }
        return candidate
    }

    func removeFile(named filename: String) {
        guard let url = safeFileURL(for: filename) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func writeProtectedFile(_ data: Data, to url: URL) {
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Ignore write errors silently to avoid disrupting audio monitoring
        }
    }

    // MARK: - Settings Persistence

    func loadSettings() -> AppSettings {
        var decoded = AppSettings()
        var needSave = false

        if let data = try? Data(contentsOf: settingsFileURL),
           let loaded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            decoded = loaded
            // Migrate old default (-48 dB) to a calmer noise gate (-38 dB) for ambient microphones
            if decoded.minimumRMSdB == -48.0 {
                decoded.minimumRMSdB = -38.0
                needSave = true
            }
            if decoded.hostName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                decoded.hostName = Host.current().localizedName ?? "Mac"
                needSave = true
            }
            // Migrate legacy Teams text to generalized text
            if decoded.customMessageText.contains("Teams") {
                decoded.customMessageText = "登録されたサウンドを検知しました！"
                needSave = true
            }
        }

        // Load Webhook URL from Keychain; migrate from plaintext settings.json if present
        if let keychainURL = KeychainHelper.loadWebhookURL(), !keychainURL.isEmpty {
            if !decoded.discordWebhookURL.isEmpty {
                needSave = true
            }
            decoded.discordWebhookURL = keychainURL
        } else if !decoded.discordWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            KeychainHelper.saveWebhookURL(decoded.discordWebhookURL)
            needSave = true
        }

        if needSave {
            saveSettings(decoded, immediate: true)
        }
        return decoded
    }

    func saveSettings(_ settings: AppSettings, immediate: Bool = false) {
        let webhookURL = settings.discordWebhookURL
        var sanitized = settings
        sanitized.discordWebhookURL = ""

        let performWrite = { [weak self] in
            guard let self = self else { return }
            KeychainHelper.saveWebhookURL(webhookURL)
            if let data = try? JSONEncoder().encode(sanitized) {
                self.writeProtectedFile(data, to: self.settingsFileURL)
            }
        }

        settingsSaveWorkItem?.cancel()
        if immediate {
            ioQueue.async(execute: performWrite)
        } else {
            let item = DispatchWorkItem(block: performWrite)
            settingsSaveWorkItem = item
            ioQueue.asyncAfter(deadline: .now() + 0.35, execute: item)
        }
    }

    // MARK: - Profiles Persistence

    func loadProfiles() -> [SoundProfile] {
        guard let data = try? Data(contentsOf: profilesFileURL),
              let decoded = try? JSONDecoder().decode([SoundProfile].self, from: data) else {
            return []
        }

        // Remove any legacy preset profiles so only user-recorded profiles remain
        let customOnly = decoded.filter { !$0.isBuiltIn }
        if customOnly.count != decoded.count {
            saveProfiles(customOnly, immediate: true)
            if let files = try? FileManager.default.contentsOfDirectory(atPath: storageDir.path) {
                for f in files where f.hasPrefix("preset_") {
                    removeFile(named: f)
                }
            }
        }
        return customOnly
    }

    func saveProfiles(_ profiles: [SoundProfile], immediate: Bool = false) {
        let snapshot = profiles
        let performWrite = { [weak self] in
            guard let self = self else { return }
            if let data = try? JSONEncoder().encode(snapshot) {
                self.writeProtectedFile(data, to: self.profilesFileURL)
            }
        }

        profilesSaveWorkItem?.cancel()
        if immediate {
            ioQueue.async(execute: performWrite)
        } else {
            let item = DispatchWorkItem(block: performWrite)
            profilesSaveWorkItem = item
            ioQueue.asyncAfter(deadline: .now() + 0.35, execute: item)
        }
    }

    // MARK: - History Persistence

    func loadHistory() -> [DetectionEvent] {
        guard let data = try? Data(contentsOf: historyFileURL),
              let decoded = try? JSONDecoder().decode([DetectionEvent].self, from: data) else {
            return []
        }
        return decoded
    }

    func saveHistory(_ history: [DetectionEvent]) {
        let snapshot = Array(history.prefix(100))
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            if let data = try? JSONEncoder().encode(snapshot) {
                self.writeProtectedFile(data, to: self.historyFileURL)
            }
        }
    }
}
