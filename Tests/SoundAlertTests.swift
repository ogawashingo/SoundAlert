import Foundation

private var passed = 0
private var failed = 0

private func expect(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition {
        passed += 1
    } else {
        failed += 1
        fputs("FAIL [\(file):\(line)]: \(message)\n", stderr)
    }
}

private func generateTone(frequency: Double, duration: Double, sampleRate: Double = 16000.0, amplitude: Float = 0.5) -> [Float] {
    let count = Int(sampleRate * duration)
    return (0..<count).map { i in
        let t = Double(i) / sampleRate
        return amplitude * Float(sin(2.0 * .pi * frequency * t))
    }
}

private func testDiscordWebhookValidation() {
    let validURLs = [
        "https://discord.com/api/webhooks/1234567890/abcdef_token-123",
        "https://discordapp.com/api/webhooks/1234567890/abcdef_token-123",
        "https://ptb.discord.com/api/webhooks/1234567890/abcdef_token-123",
        "https://canary.discord.com/api/v10/webhooks/1234567890/abcdef_token-123",
        "  https://discord.com/api/webhooks/1234567890/abcdef_token-123  "
    ]
    for url in validURLs {
        if case .valid = DiscordNotifier.validateWebhookURL(url) {
            expect(true, "Valid URL accepted: \(url)")
        } else {
            expect(false, "Expected valid URL to be accepted: \(url)")
        }
    }

    let invalidURLs = [
        "",
        "   ",
        "http://discord.com/api/webhooks/1234567890/abcdef",
        "https://evil.example.com/api/webhooks/1234567890/abcdef",
        "http://127.0.0.1:8080/api/webhooks/1234567890/abcdef",
        "https://discord.com/api/webhooks/1234567890",
        "https://discord.com/channels/123/456",
        "file:///etc/passwd"
    ]
    for url in invalidURLs {
        if case .invalid = DiscordNotifier.validateWebhookURL(url) {
            expect(true, "Invalid URL rejected: \(url)")
        } else {
            expect(false, "Expected invalid URL to be rejected: \(url)")
        }
    }
}

private func testStoragePathTraversalAndFlush() {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SoundAlertTests_\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let storage = StorageManager(storageDir: tempDir)

    // Safe filenames
    expect(storage.safeFileURL(for: "custom_123.wav") != nil, "Normal wav filename should be allowed")
    expect(storage.safeFileURL(for: "detected_abc.wav") != nil, "Detected wav filename should be allowed")

    // Path traversal / unsafe filenames
    expect(storage.safeFileURL(for: "") == nil, "Empty filename should be rejected")
    expect(storage.safeFileURL(for: ".") == nil, "Dot filename should be rejected")
    expect(storage.safeFileURL(for: "..") == nil, "Double-dot filename should be rejected")
    expect(storage.safeFileURL(for: "../secret.txt") == nil, "Parent traversal should be rejected")
    expect(storage.safeFileURL(for: "subdir/file.wav") == nil, "Subdirectory path should be rejected")
    expect(storage.safeFileURL(for: "/etc/passwd") == nil, "Absolute path should be rejected")

    // Debounced save + flushPendingSaves
    let profile = SoundProfile(
        id: UUID(),
        name: "テストチャイム",
        icon: "bell.fill",
        createdAt: Date(),
        durationSeconds: 0.5,
        threshold: 0.75,
        isEnabled: true,
        isBuiltIn: false,
        templates: [[[Float](repeating: 0.1, count: 40)]],
        sampleWavFilenames: []
    )
    storage.saveProfiles([profile], immediate: false)
    storage.flushPendingSaves()

    let reloaded = storage.loadProfiles()
    expect(reloaded.count == 1 && reloaded.first?.name == "テストチャイム", "Flushed profiles should persist immediately")
}

private func testAudioFeatureExtractor() {
    let extractor = AudioFeatureExtractor()

    // Synthesize a 2-tone chime surrounded by silence
    let silence = [Float](repeating: 0, count: 8000) // 0.5s
    let chime = generateTone(frequency: 1200, duration: 0.25) + generateTone(frequency: 1800, duration: 0.25)
    let rawRecording = silence + chime + silence

    let trimmed = extractor.trimActiveAudio(samples: rawRecording)
    expect(trimmed.count < rawRecording.count, "trimActiveAudio should strip leading/trailing silence")
    expect(trimmed.count >= 4000, "trimActiveAudio should preserve active chime audio")

    guard let extracted = extractor.extractNormalizedTemplate(from: rawRecording) else {
        expect(false, "extractNormalizedTemplate should succeed on synthetic chime")
        return
    }

    // Compute live frames from the exact same chime
    var liveFrames: [[Float]] = []
    var idx = 0
    while idx + AudioFeatureExtractor.fftSize <= extracted.trimmedSamples.count {
        extracted.trimmedSamples.withUnsafeBufferPointer { buf in
            let slice = UnsafeBufferPointer(start: buf.baseAddress! + idx, count: AudioFeatureExtractor.fftSize)
            liveFrames.append(extractor.computeFrame(samples512: slice))
        }
        idx += AudioFeatureExtractor.hopSize
    }

    let selfSim = AudioFeatureExtractor.computeSimilarity(
        normalizedTemplate: extracted.template,
        liveFrames: liveFrames[...]
    )
    expect(selfSim > 0.95, "Self-similarity should be > 0.95 (got \(selfSim))")

    // Different frequency tone should have low similarity
    let otherTone = generateTone(frequency: 440, duration: Double(extracted.trimmedSamples.count) / AudioFeatureExtractor.sampleRate)
    var otherFrames: [[Float]] = []
    idx = 0
    while idx + AudioFeatureExtractor.fftSize <= otherTone.count && otherFrames.count < extracted.template.count {
        otherTone.withUnsafeBufferPointer { buf in
            let slice = UnsafeBufferPointer(start: buf.baseAddress! + idx, count: AudioFeatureExtractor.fftSize)
            otherFrames.append(extractor.computeFrame(samples512: slice))
        }
        idx += AudioFeatureExtractor.hopSize
    }
    if otherFrames.count == extracted.template.count {
        let diffSim = AudioFeatureExtractor.computeSimilarity(
            normalizedTemplate: extracted.template,
            liveFrames: otherFrames[...]
        )
        expect(diffSim < 0.5, "Unrelated tone similarity should be < 0.5 (got \(diffSim))")
    }

    // WAV writer test
    let wavURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: wavURL) }
    do {
        try AudioFeatureExtractor.writeWavFile(samples: chime, to: wavURL)
        let data = try Data(contentsOf: wavURL)
        expect(data.count == 44 + chime.count * 2, "WAV file size should match 44-byte header + 16-bit PCM samples")
        expect(String(data: data.prefix(4), encoding: .ascii) == "RIFF", "WAV header should start with RIFF")
        expect(String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WAVE", "WAV header should contain WAVE")
    } catch {
        expect(false, "writeWavFile threw unexpected error: \(error)")
    }
}

@main
struct SoundAlertTestRunner {
    static func main() {
        testDiscordWebhookValidation()
        testStoragePathTraversalAndFlush()
        testAudioFeatureExtractor()

        print("SoundAlert Tests: \(passed) passed, \(failed) failed")
        if failed > 0 {
            exit(1)
        }
    }
}
