import Foundation
import CoreAudio

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let sampleRate: Double
    let inputChannels: Int
    let isDefault: Bool
}

struct SoundProfile: Identifiable, Codable {
    var id: UUID
    var name: String
    var icon: String
    var createdAt: Date
    var durationSeconds: Double
    var threshold: Float
    var isEnabled: Bool
    var isBuiltIn: Bool
    /// Each element is a 2D spectrogram template: [frameIndex][bandIndex]
    /// Multiple templates allow recording 1~3 samples (like iOS Custom Sound Recognition)
    var templates: [[[Float]]]
    /// Saved WAV filename in Application Support directory for preview playback
    var sampleWavFilenames: [String]

    var sampleCount: Int {
        templates.count
    }
}

struct DetectionEvent: Identifiable, Codable {
    var id: UUID
    var timestamp: Date
    var profileId: UUID
    var profileName: String
    var similarity: Float
    var discordSent: Bool
    var discordStatusMessage: String
    var capturedWavFilename: String?
}

struct AppSettings: Codable {
    var discordWebhookURL: String = ""
    var discordMention: String = "@here"
    var customMessageText: String = "Microsoft Teamsのアラート音を検知しました！"
    var cooldownSeconds: Double = 10.0
    var selectedDeviceUID: String = ""
    var minimumRMSdB: Float = -38.0
    var sendMacOSNotification: Bool = true
    var flashWindowOnDetect: Bool = true
    var includeSimilarityInDiscord: Bool = true
}
