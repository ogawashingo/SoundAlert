import Foundation

enum TeamsPresetGenerator {
    static let sampleRate: Double = 16000.0

    /// Synthesizes a realistic two-tone Teams notification chime (16kHz mono)
    static func generateTeamsNotificationSamples() -> [Float] {
        let duration = 0.70
        let totalSamples = Int(sampleRate * duration)
        var buffer = [Float](repeating: 0, count: totalSamples)

        // Note 1: F#5 (739.99 Hz) + B5 (987.77 Hz) bell attack at t = 0.03s
        // Note 2: B5 (987.77 Hz) + D#6 (1244.51 Hz) + F#6 (1479.98 Hz) bright chime at t = 0.17s
        let notes: [(start: Double, length: Double, freqs: [(Double, Double)], decay: Double)] = [
            (0.03, 0.20, [(739.99, 0.55), (1479.98, 0.30), (2219.97, 0.12)], 14.0),
            (0.17, 0.48, [(987.77, 0.60), (1479.98, 0.35), (1975.53, 0.25), (2963.30, 0.10)], 7.5)
        ]

        for note in notes {
            let startIdx = Int(note.start * sampleRate)
            let endIdx = min(totalSamples, Int((note.start + note.length) * sampleRate))
            for i in startIdx..<endIdx {
                let t = Double(i - startIdx) / sampleRate
                let attack = min(1.0, t / 0.006)
                let env = attack * exp(-note.decay * t)
                var sig = 0.0
                for (f, amp) in note.freqs {
                    sig += amp * sin(2.0 * .pi * f * t)
                }
                buffer[i] += Float(sig * env * 0.7)
            }
        }
        return buffer
    }

    /// Synthesizes the Teams Incoming Call arpeggio chime phrase (16kHz mono)
    static func generateTeamsCallRingtoneSamples() -> [Float] {
        let duration = 1.65
        let totalSamples = Int(sampleRate * duration)
        var buffer = [Float](repeating: 0, count: totalSamples)

        // Characteristic upbeat marimba/bell arpeggio motif
        let events: [(start: Double, freq: Double, amp: Double, decay: Double)] = [
            (0.04, 587.33, 0.55, 9.0),   // D5
            (0.22, 659.25, 0.55, 9.0),   // E5
            (0.40, 739.99, 0.60, 8.5),   // F#5
            (0.58, 880.00, 0.65, 8.0),   // A5
            (0.82, 1174.66, 0.75, 5.5),  // D6
            (1.12, 880.00, 0.60, 6.0)    // A5
        ]

        for ev in events {
            let startIdx = Int(ev.start * sampleRate)
            let endIdx = min(totalSamples, Int((ev.start + 0.45) * sampleRate))
            for i in startIdx..<endIdx {
                let t = Double(i - startIdx) / sampleRate
                let attack = min(1.0, t / 0.005)
                let env = attack * exp(-ev.decay * t)
                let fundamental = sin(2.0 * .pi * ev.freq * t)
                let harmonic2 = 0.35 * sin(2.0 * .pi * (ev.freq * 2.0) * t)
                let harmonic3 = 0.12 * sin(2.0 * .pi * (ev.freq * 3.0) * t)
                buffer[i] += Float((fundamental + harmonic2 + harmonic3) * ev.amp * env * 0.65)
            }
        }
        return buffer
    }

    static func createDefaultProfiles(storageDir: URL) -> [SoundProfile] {
        let extractor = AudioFeatureExtractor.shared
        var result = [SoundProfile]()

        let notifSamples = generateTeamsNotificationSamples()
        if let extracted = extractor.extractNormalizedTemplate(from: notifSamples) {
            let wavName = "preset_teams_notification.wav"
            let wavURL = storageDir.appendingPathComponent(wavName)
            try? AudioFeatureExtractor.writeWavFile(
                samples: extracted.trimmedSamples,
                normalizePeak: true,
                addSpeakerWakeupAndRepeatIfShort: true,
                to: wavURL
            )
            result.append(
                SoundProfile(
                    id: UUID(),
                    name: "Teams チャット通知音（プリセット）",
                    icon: "bubble.left.and.exclamationmark.bubble.right.fill",
                    createdAt: Date(),
                    durationSeconds: Double(extracted.trimmedSamples.count) / sampleRate,
                    threshold: 0.68,
                    isEnabled: true,
                    isBuiltIn: true,
                    templates: [extracted.template],
                    sampleWavFilenames: [wavName]
                )
            )
        }

        let callSamples = generateTeamsCallRingtoneSamples()
        if let extracted = extractor.extractNormalizedTemplate(from: callSamples) {
            let wavName = "preset_teams_call.wav"
            let wavURL = storageDir.appendingPathComponent(wavName)
            try? AudioFeatureExtractor.writeWavFile(
                samples: extracted.trimmedSamples,
                normalizePeak: true,
                addSpeakerWakeupAndRepeatIfShort: true,
                to: wavURL
            )
            result.append(
                SoundProfile(
                    id: UUID(),
                    name: "Teams 通話・会議着信音（プリセット）",
                    icon: "phone.badge.waveform.fill",
                    createdAt: Date(),
                    durationSeconds: Double(extracted.trimmedSamples.count) / sampleRate,
                    threshold: 0.65,
                    isEnabled: true,
                    isBuiltIn: true,
                    templates: [extracted.template],
                    sampleWavFilenames: [wavName]
                )
            )
        }

        return result
    }
}
