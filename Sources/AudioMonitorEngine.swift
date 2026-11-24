import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import Accelerate
import AppKit

final class AudioMonitorEngine: NSObject, ObservableObject {
    // MARK: - Published UI State
    @Published var inputDevices: [AudioDevice] = []
    @Published var selectedDeviceID: AudioDeviceID = 0
    @Published var isMonitoring: Bool = false
    @Published var permissionGranted: Bool = false
    @Published var statusMessage: String = "待機中"
    @Published var currentRMSdB: Float = -80.0
    @Published var currentLevelNormalized: Float = 0.0
    @Published var liveSpectrum: [Float] = Array(repeating: 0, count: AudioFeatureExtractor.numBands)

    /// Real-time similarity (0.0 ... 1.0) per SoundProfile.id
    @Published var liveSimilarities: [UUID: Float] = [:]
    /// Recent peak similarity (decays slowly so the user can read the meter easily)
    @Published var recentPeakSimilarities: [UUID: Float] = [:]

    @Published var profiles: [SoundProfile] = []
    @Published var detectionHistory: [DetectionEvent] = []
    @Published var settings: AppSettings = AppSettings()

    /// Visual flash state when an alert is triggered
    @Published var activeAlertBanner: DetectionEvent? = nil
    @Published var isPlayingPreview: Bool = false
    @Published var playingFilename: String? = nil

    // MARK: - Custom Sound Recording State (iOS-style training)
    enum RecordingState: Equatable {
        case idle
        case waitingForSoundTrigger
        case capturing(progress: Double)
        case capturedPreview(duration: Double)
        case error(String)
    }

    @Published var recordingState: RecordingState = .idle
    @Published var recordedSamplesCount: Int = 0
    private var pendingTemplates: [[[Float]]] = []
    private var pendingWavFilenames: [String] = []

    // MARK: - Collaborators
    private let storage = StorageManager()
    private let previewPlayer = AudioPreviewPlayer()
    /// Owned exclusively by `processingQueue` so scratch buffers are never accessed concurrently
    private let featureExtractor = AudioFeatureExtractor()

    // MARK: - Internal Audio Processing State
    private var audioEngine: AVAudioEngine?
    private let processingQueue = DispatchQueue(label: "com.soundalert.audioprocessing", qos: .userInteractive)

    /// 16kHz mono ring buffer (stores last 4 seconds = 64,000 samples)
    private var pcmRingBuffer: [Float] = []
    private let maxRingBufferSamples = 64000
    private var stftSampleAccumulator: [Float] = []

    /// Ring buffer of recent whitened spectrogram frames (stores last 250 frames = ~4 seconds)
    private var spectrogramRing: [[Float]] = []
    private let maxSpectrogramFrames = 250

    /// Auto-trigger recording buffers (accessed exclusively on `processingQueue`)
    private var isWaitingForTrigger: Bool = false
    private var isCapturingSample: Bool = false
    private var captureBuffer: [Float] = []
    private let targetCaptureSamples: Int = Int(AudioFeatureExtractor.sampleRate * 1.6)

    /// Cooldown tracking (accessed exclusively on `processingQueue`)
    private var lastTriggerTime: Date = .distantPast
    private var pendingPeakCandidate: (profile: SoundProfile, maxSim: Float, framesLeft: Int)? = nil
    private var activeHoldFramesRemaining: Int = 0
    private var lastUIUpdateTimestamp: CFAbsoluteTime = 0
    private var lastUIWasQuiet: Bool = false
    private static let zeroFrame = [Float](repeating: 0, count: AudioFeatureExtractor.numBands)

    /// Thread-safe snapshots accessed exclusively on `processingQueue`
    private var processingProfiles: [SoundProfile] = []
    private var processingSettings: AppSettings = AppSettings()

    override init() {
        super.init()

        previewPlayer.onStateChanged = { [weak self] isPlaying, filename in
            guard let self = self else { return }
            self.isPlayingPreview = isPlaying
            self.playingFilename = filename
            if isPlaying {
                self.statusMessage = "🔊 テスト音をMacのスピーカーから再生中..."
            } else {
                self.statusMessage = self.isMonitoring ? "監視中 (\(self.currentDeviceName))" : "停止中"
            }
        }
        previewPlayer.onError = { [weak self] message in
            self?.statusMessage = message
        }

        self.settings = storage.loadSettings()
        self.profiles = storage.loadProfiles()
        self.detectionHistory = storage.loadHistory()
        syncProcessingSettings()
        syncProcessingProfiles()

        refreshInputDevices()
        checkAndRequestMicrophonePermission()
    }

    // MARK: - Persistence & Thread-Safe Snapshots

    private func syncProcessingSettings() {
        let snapshot = settings
        processingQueue.async { [weak self] in
            self?.processingSettings = snapshot
        }
    }

    private func syncProcessingProfiles() {
        let snapshot = profiles
        processingQueue.async { [weak self] in
            self?.processingProfiles = snapshot
        }
    }

    func saveSettings(immediate: Bool = false) {
        syncProcessingSettings()
        storage.saveSettings(settings, immediate: immediate)
    }

    func calibrateNoiseGate() {
        // Set gate 6 dB above current room ambient level
        let targetGate = min(-20.0, max(-55.0, roundf(currentRMSdB + 6.0)))
        settings.minimumRMSdB = targetGate
        saveSettings(immediate: true)
    }

    func saveProfiles(immediate: Bool = false) {
        syncProcessingProfiles()
        storage.saveProfiles(profiles, immediate: immediate)
    }

    func saveHistory() {
        storage.saveHistory(detectionHistory)
    }

    func clearDetectionHistory() {
        for event in detectionHistory {
            if let wav = event.capturedWavFilename {
                storage.removeFile(named: wav)
            }
        }
        detectionHistory.removeAll()
        saveHistory()
    }

    // MARK: - Microphone Permission & CoreAudio Device Enumeration

    func checkAndRequestMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            DispatchQueue.main.async {
                self.permissionGranted = true
                if !self.isMonitoring {
                    self.startMonitoring()
                }
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.permissionGranted = granted
                    if granted {
                        self.startMonitoring()
                    } else {
                        self.statusMessage = "マイク権限が許可されていません（システム設定 > プライバシーとセキュリティ > マイク）"
                    }
                }
            }
        default:
            DispatchQueue.main.async {
                self.permissionGranted = false
                self.statusMessage = "マイクへのアクセスを許可してください"
            }
        }
    }

    func refreshInputDevices() {
        let found = CoreAudioDeviceManager.enumerateInputDevices()
        DispatchQueue.main.async {
            self.inputDevices = found

            // Prefer previously saved device UID, otherwise fallback to system default input device
            if let saved = found.first(where: { $0.uid == self.settings.selectedDeviceUID }) {
                self.selectedDeviceID = saved.id
            } else if let def = found.first(where: { $0.isDefault }) ?? found.first {
                self.selectedDeviceID = def.id
                self.settings.selectedDeviceUID = def.uid
            }
        }
    }

    func selectDevice(_ device: AudioDevice) {
        selectedDeviceID = device.id
        settings.selectedDeviceUID = device.uid
        saveSettings(immediate: true)
        if isMonitoring {
            stopMonitoring()
            startMonitoring()
        }
    }

    var currentDeviceName: String {
        inputDevices.first(where: { $0.id == selectedDeviceID })?.name ?? "USBマイク"
    }

    // MARK: - Start / Stop Real-Time Audio Monitoring

    func startMonitoring() {
        stopMonitoring()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Bind selected CoreAudio input device if valid
        if selectedDeviceID != 0, let audioUnit = inputNode.audioUnit {
            var devID = selectedDeviceID
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        let hwFormat = inputNode.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 && hwFormat.channelCount > 0 else {
            statusMessage = "マイク入力フォーマットの取得に失敗しました"
            return
        }

        processingQueue.sync {
            pcmRingBuffer.removeAll(keepingCapacity: true)
            stftSampleAccumulator.removeAll(keepingCapacity: true)
            spectrogramRing.removeAll(keepingCapacity: true)
            pendingPeakCandidate = nil
        }

        let inputSampleRate = hwFormat.sampleRate
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.handleIncomingAudioBuffer(buffer, hardwareSampleRate: inputSampleRate)
        }

        do {
            try engine.start()
            self.audioEngine = engine
            self.isMonitoring = true
            self.statusMessage = "監視中 (\(currentDeviceName))"
        } catch {
            self.isMonitoring = false
            self.statusMessage = "オーディオ開始エラー: \(error.localizedDescription)"
        }
    }

    func stopMonitoring() {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.audioEngine = nil
        }
        isMonitoring = false
        statusMessage = "停止中"
    }

    // MARK: - Real-Time Audio Buffer Processing

    private func handleIncomingAudioBuffer(_ buffer: AVAudioPCMBuffer, hardwareSampleRate: Double) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frameCount > 0, channels > 0 else { return }

        // Downmix to mono using hardware-accelerated vDSP
        var monoInput = [Float](repeating: 0, count: frameCount)
        if channels == 1 {
            memcpy(&monoInput, channelData[0], frameCount * MemoryLayout<Float>.size)
        } else if channels == 2 {
            var half: Float = 0.5
            vDSP_vasm(channelData[0], 1, channelData[1], 1, &half, &monoInput, 1, vDSP_Length(frameCount))
        } else {
            var scale = 1.0 / Float(channels)
            monoInput.withUnsafeMutableBufferPointer { dst in
                guard let base = dst.baseAddress else { return }
                for c in 0..<channels {
                    vDSP_vsma(channelData[c], 1, &scale, base, 1, base, 1, vDSP_Length(frameCount))
                }
            }
        }

        // Resample to 16,000 Hz if needed
        let targetSR = AudioFeatureExtractor.sampleRate
        let samples16k: [Float]
        if abs(hardwareSampleRate - targetSR) < 1.0 {
            samples16k = monoInput
        } else {
            let ratio = hardwareSampleRate / targetSR
            let outCount = max(1, Int(Double(frameCount) / ratio))
            var resampled = [Float](repeating: 0, count: outCount)
            for i in 0..<outCount {
                let srcPos = Double(i) * ratio
                let idx0 = min(frameCount - 1, Int(srcPos))
                let idx1 = min(frameCount - 1, idx0 + 1)
                let frac = Float(srcPos - Double(idx0))
                resampled[i] = monoInput[idx0] * (1.0 - frac) + monoInput[idx1] * frac
            }
            samples16k = resampled
        }

        processingQueue.async { [weak self] in
            self?.processResampled16k(samples16k)
        }
    }

    private func processResampled16k(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        // 1. Compute RMS level in dB
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        let db = max(-80.0, 20.0 * log10f(max(rms, 1e-5)))
        let normLevel = max(0.0, min(1.0, (db + 65.0) / 55.0))

        // 2. Append to PCM ring buffer (amortize removeFirst to once per second)
        pcmRingBuffer.append(contentsOf: samples)
        if pcmRingBuffer.count > maxRingBufferSamples + 16000 {
            pcmRingBuffer.removeFirst(pcmRingBuffer.count - maxRingBufferSamples)
        }

        let currentSettings = processingSettings
        let currentProfiles = processingProfiles

        // 3. Handle iOS-style custom sound auto-trigger / manual recording
        if isWaitingForTrigger {
            // Trigger when RMS rises above -42 dB (or 6 dB above minimumRMSdB)
            let triggerDB = max(-42.0, currentSettings.minimumRMSdB + 6.0)
            if db >= triggerDB {
                isWaitingForTrigger = false
                isCapturingSample = true
                // Include last 0.18s (2880 samples) pre-roll so the attack transient is preserved
                let preRollCount = min(pcmRingBuffer.count, 2880)
                captureBuffer = Array(pcmRingBuffer.suffix(preRollCount))
            }
        } else if isCapturingSample {
            captureBuffer.append(contentsOf: samples)
            let progress = min(1.0, Double(captureBuffer.count) / Double(targetCaptureSamples))
            DispatchQueue.main.async { [weak self] in
                self?.recordingState = .capturing(progress: progress)
            }
            if captureBuffer.count >= targetCaptureSamples {
                isCapturingSample = false
                let finishedSamples = captureBuffer
                captureBuffer.removeAll()
                finalizeCapturedSample(finishedSamples)
            }
        }

        // 4. Accumulate samples for STFT hops (single batch removeFirst instead of per-hop shift)
        stftSampleAccumulator.append(contentsOf: samples)
        let fftSize = AudioFeatureExtractor.fftSize
        let hopSize = AudioFeatureExtractor.hopSize
        if db >= currentSettings.minimumRMSdB {
            // Keep analysis active for ~1.4 seconds (90 frames) after sound crosses noise gate
            // so the full chime duration + decay tail aligns completely with the template.
            activeHoldFramesRemaining = 90
        }
        let isAboveNoiseGate = activeHoldFramesRemaining > 0
        let shouldComputeFFT = isAboveNoiseGate || db >= (currentSettings.minimumRMSdB - 6.0) || isCapturingSample

        guard stftSampleAccumulator.count >= fftSize else { return }

        var latestFrame: [Float] = Self.zeroFrame
        var simMap: [UUID: Float] = [:]
        var triggeredCandidate: (profile: SoundProfile, maxSim: Float, clipSamples: [Float])? = nil

        let triggerIfReady: (SoundProfile, Float) -> Void = { profile, maxSim in
            let now = Date()
            if now.timeIntervalSince(self.lastTriggerTime) >= currentSettings.cooldownSeconds {
                self.lastTriggerTime = now
                // Capture last 2.0 seconds of audio for replay in History
                let clipLen = min(self.pcmRingBuffer.count, Int(AudioFeatureExtractor.sampleRate * 2.0))
                let clip = Array(self.pcmRingBuffer.suffix(clipLen))
                triggeredCandidate = (profile, maxSim, clip)
            }
        }

        if shouldComputeFFT {
            var offset = 0
            stftSampleAccumulator.withUnsafeBufferPointer { buf in
                while offset + fftSize <= buf.count {
                    let slice = UnsafeBufferPointer(start: buf.baseAddress! + offset, count: fftSize)
                    let frame = featureExtractor.computeFrame(samples512: slice)
                    spectrogramRing.append(frame)
                    latestFrame = frame
                    offset += hopSize

                    var candidateCreatedThisHop = false
                    if activeHoldFramesRemaining > 0 {
                        activeHoldFramesRemaining -= 1
                        // Evaluate template alignment on every hop so large audio buffers never skip peak alignment
                        for profile in currentProfiles {
                            var hopBest: Float = 0.0
                            for tpl in profile.templates {
                                let T = tpl.count
                                guard T > 0, spectrogramRing.count >= T else { continue }
                                let sim = AudioFeatureExtractor.computeSimilarity(
                                    normalizedTemplate: tpl,
                                    liveFrames: spectrogramRing.suffix(T)
                                )
                                if sim > hopBest {
                                    hopBest = sim
                                }
                            }
                            if hopBest > (simMap[profile.id] ?? 0.0) {
                                simMap[profile.id] = hopBest
                            }
                            if profile.isEnabled && hopBest >= profile.threshold {
                                if let cand = pendingPeakCandidate {
                                    if hopBest > cand.maxSim {
                                        pendingPeakCandidate = (profile, hopBest, cand.framesLeft)
                                    }
                                } else {
                                    pendingPeakCandidate = (profile, hopBest, 6)
                                    candidateCreatedThisHop = true
                                }
                            }
                        }
                    }

                    // Advance peak candidate countdown one hop at a time
                    if !candidateCreatedThisHop, var cand = pendingPeakCandidate {
                        cand.framesLeft -= 1
                        if cand.framesLeft <= 0 {
                            triggerIfReady(cand.profile, cand.maxSim)
                            pendingPeakCandidate = nil
                        } else {
                            pendingPeakCandidate = cand
                        }
                    }
                }
            }
            if offset > 0 {
                stftSampleAccumulator.removeFirst(offset)
            }
            if spectrogramRing.count > maxSpectrogramFrames + 32 {
                spectrogramRing.removeFirst(spectrogramRing.count - maxSpectrogramFrames)
            }
        } else {
            let hops = (stftSampleAccumulator.count - fftSize) / hopSize + 1
            stftSampleAccumulator.removeFirst(hops * hopSize)
            if !lastUIWasQuiet || pendingPeakCandidate != nil {
                for _ in 0..<min(hops, 4) {
                    spectrogramRing.append(Self.zeroFrame)
                }
            }
            if var cand = pendingPeakCandidate {
                cand.framesLeft -= hops
                if cand.framesLeft <= 0 {
                    triggerIfReady(cand.profile, cand.maxSim)
                    pendingPeakCandidate = nil
                } else {
                    pendingPeakCandidate = cand
                }
            }
        }

        // Always dispatch detection events immediately
        if let trig = triggeredCandidate {
            DispatchQueue.main.async { [weak self] in
                self?.handleDetection(
                    profile: trig.profile,
                    similarity: trig.maxSim,
                    clipSamples: trig.clipSamples
                )
            }
        }

        // Throttle UI meter updates to save CPU (max 6 fps when active, 2 fps when quiet)
        let nowTime = CFAbsoluteTimeGetCurrent()
        let minInterval: CFAbsoluteTime = isAboveNoiseGate ? 0.16 : 0.50
        guard nowTime - lastUIUpdateTimestamp >= minInterval else { return }
        lastUIUpdateTimestamp = nowTime

        let visualSpec: [Float]
        if isAboveNoiseGate {
            visualSpec = latestFrame.map { min(1.0, max(0.0, $0 / 24.0)) }
        } else {
            visualSpec = Self.zeroFrame
        }

        let wasQuiet = lastUIWasQuiet
        lastUIWasQuiet = !isAboveNoiseGate
        let isRecordingActive = isWaitingForTrigger || isCapturingSample

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Skip UI layout updates completely if all main windows are closed or hidden
            let hasVisibleMainWindow = NSApp.windows.contains {
                $0.isVisible && $0.occlusionState.contains(.visible) && $0.frame.width > 300
            }
            guard hasVisibleMainWindow || isRecordingActive else {
                return
            }

            if abs(self.currentRMSdB - db) >= 1.5 {
                self.currentRMSdB = db
                self.currentLevelNormalized = normLevel
            }

            if isAboveNoiseGate || !wasQuiet {
                self.liveSpectrum = visualSpec
                self.liveSimilarities = simMap
            }

            if !self.recentPeakSimilarities.isEmpty || !simMap.isEmpty {
                var updatedPeaks = self.recentPeakSimilarities
                var changed = false
                for profile in self.profiles {
                    let id = profile.id
                    let val = simMap[id] ?? 0.0
                    let prev = updatedPeaks[id] ?? 0.0
                    let next: Float
                    if val >= prev {
                        next = val
                    } else {
                        let decayed = prev * 0.85
                        next = decayed < 0.02 ? 0.0 : decayed
                    }
                    if abs(next - prev) >= 0.015 {
                        updatedPeaks[id] = next
                        changed = true
                    }
                }
                if changed {
                    self.recentPeakSimilarities = updatedPeaks
                }
            }
        }
    }

    // MARK: - Alert Trigger & Notification Dispatch

    private func handleDetection(profile: SoundProfile, similarity: Float, clipSamples: [Float]) {
        let eventID = UUID()
        let wavName = "detected_\(eventID.uuidString).wav"
        if let wavURL = storage.safeFileURL(for: wavName) {
            try? AudioFeatureExtractor.writeWavFile(samples: clipSamples, to: wavURL)
        }

        let initialEvent = DetectionEvent(
            id: eventID,
            timestamp: Date(),
            profileId: profile.id,
            profileName: profile.name,
            similarity: similarity,
            discordSent: false,
            discordStatusMessage: settings.discordWebhookURL.isEmpty ? "Webhook未設定" : "送信中...",
            capturedWavFilename: wavName
        )

        detectionHistory.insert(initialEvent, at: 0)
        if detectionHistory.count > 100 {
            let evicted = detectionHistory[100...]
            for event in evicted {
                if let wav = event.capturedWavFilename {
                    storage.removeFile(named: wav)
                }
            }
            detectionHistory.removeLast(detectionHistory.count - 100)
        }
        saveHistory()

        activeAlertBanner = initialEvent
        if settings.flashWindowOnDetect {
            NSApp.requestUserAttention(.criticalRequest)
        }

        // Clear banner after 6 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            if self?.activeAlertBanner?.id == eventID {
                self?.activeAlertBanner = nil
            }
        }

        // Send Discord webhook notification
        let webhookURL = settings.discordWebhookURL
        let mention = settings.discordMention
        let customMsg = settings.customMessageText
        let hostName = settings.hostName
        let devName = currentDeviceName
        let includeSim = settings.includeSimilarityInDiscord

        if !webhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task {
                let result = await DiscordNotifier.sendAlert(
                    webhookURLString: webhookURL,
                    mention: mention,
                    customMessage: customMsg,
                    hostName: hostName,
                    profileName: profile.name,
                    similarity: similarity,
                    deviceName: devName,
                    includeSimilarity: includeSim,
                    isTest: false
                )
                await MainActor.run {
                    if let idx = self.detectionHistory.firstIndex(where: { $0.id == eventID }) {
                        self.detectionHistory[idx].discordSent = result.success
                        self.detectionHistory[idx].discordStatusMessage = result.message
                        self.saveHistory()
                    }
                }
            }
        }
    }

    // MARK: - iOS-Style Custom Sound Training Flow

    func beginCustomSoundSession() {
        processingQueue.sync {
            isWaitingForTrigger = false
            isCapturingSample = false
            captureBuffer.removeAll()
        }
        pendingTemplates.removeAll()
        pendingWavFilenames.removeAll()
        recordedSamplesCount = 0
        recordingState = .idle
    }

    /// Cancels the current recording session and deletes any unsaved pending WAV files
    func discardCustomSoundSession() {
        for wav in pendingWavFilenames {
            storage.removeFile(named: wav)
        }
        beginCustomSoundSession()
    }

    /// Waits for the user to play the sound on their other PC, then automatically captures it
    func startWaitingForSoundTrigger() {
        if !isMonitoring {
            startMonitoring()
        }
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            self.captureBuffer.removeAll()
            self.isCapturingSample = false
            self.isWaitingForTrigger = true
        }
        recordingState = .waitingForSoundTrigger
    }

    /// Immediately starts recording 1.6s of audio without waiting for volume threshold
    func startImmediateCapture() {
        if !isMonitoring {
            startMonitoring()
        }
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            self.isWaitingForTrigger = false
            self.captureBuffer.removeAll()
            self.isCapturingSample = true
        }
        recordingState = .capturing(progress: 0.0)
    }

    func cancelCurrentCapture() {
        processingQueue.async { [weak self] in
            self?.isWaitingForTrigger = false
            self?.isCapturingSample = false
            self?.captureBuffer.removeAll()
        }
        recordingState = .idle
    }

    private func finalizeCapturedSample(_ rawSamples: [Float]) {
        guard let extracted = featureExtractor.extractNormalizedTemplate(from: rawSamples) else {
            DispatchQueue.main.async {
                self.recordingState = .error("音が小さすぎるか短すぎるため特徴を抽出できませんでした。もう一度お試しください。")
            }
            return
        }

        let wavName = "custom_\(UUID().uuidString).wav"
        if let wavURL = storage.safeFileURL(for: wavName) {
            try? AudioFeatureExtractor.writeWavFile(
                samples: extracted.trimmedSamples,
                normalizePeak: true,
                addSpeakerWakeupAndRepeatIfShort: true,
                to: wavURL
            )
        }
        let dur = Double(extracted.trimmedSamples.count) / AudioFeatureExtractor.sampleRate

        DispatchQueue.main.async {
            self.pendingTemplates.append(extracted.template)
            self.pendingWavFilenames.append(wavName)
            self.recordedSamplesCount = self.pendingTemplates.count
            self.recordingState = .capturedPreview(duration: dur)
        }
    }

    func discardLastRecordedSample() {
        guard !pendingTemplates.isEmpty else { return }
        pendingTemplates.removeLast()
        if let wav = pendingWavFilenames.popLast() {
            storage.removeFile(named: wav)
        }
        recordedSamplesCount = pendingTemplates.count
        recordingState = .idle
    }

    func saveNewCustomProfile(name: String, icon: String, threshold: Float) {
        guard !pendingTemplates.isEmpty else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? "カスタムサウンド" : trimmedName
        let avgFrames = pendingTemplates.map { $0.count }.reduce(0, +) / max(1, pendingTemplates.count)
        let estDuration = Double(avgFrames * AudioFeatureExtractor.hopSize) / AudioFeatureExtractor.sampleRate

        let profile = SoundProfile(
            id: UUID(),
            name: finalName,
            icon: icon,
            createdAt: Date(),
            durationSeconds: estDuration,
            threshold: threshold,
            isEnabled: true,
            isBuiltIn: false,
            templates: pendingTemplates,
            sampleWavFilenames: pendingWavFilenames
        )

        profiles.insert(profile, at: 0)
        saveProfiles(immediate: true)
        beginCustomSoundSession()
    }

    /// Appends a newly recorded template to an existing profile (e.g., adding a real mic sample to an existing profile)
    func addRecordedSamplesToProfile(_ profileID: UUID) {
        guard !pendingTemplates.isEmpty,
              let idx = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[idx].templates.append(contentsOf: pendingTemplates)
        profiles[idx].sampleWavFilenames.append(contentsOf: pendingWavFilenames)
        saveProfiles(immediate: true)
        beginCustomSoundSession()
    }

    func deleteProfile(_ profile: SoundProfile) {
        for wav in profile.sampleWavFilenames where !wav.hasPrefix("preset_") {
            storage.removeFile(named: wav)
        }
        profiles.removeAll { $0.id == profile.id }
        saveProfiles(immediate: true)
    }

    // MARK: - Audio Playback (Preview Registered Sound or Detected Clip)

    func playWavFile(named filename: String) {
        guard let url = storage.safeFileURL(for: filename),
              FileManager.default.fileExists(atPath: url.path) else {
            statusMessage = "再生ファイルが見つかりません: \(filename)"
            return
        }
        previewPlayer.togglePlay(url: url, filename: filename)
    }

    func playLastCapturedPreview() {
        guard let lastWav = pendingWavFilenames.last else { return }
        playWavFile(named: lastWav)
    }
}
