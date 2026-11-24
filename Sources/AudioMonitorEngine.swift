import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import Accelerate
import AppKit

final class AudioMonitorEngine: NSObject, ObservableObject, AVAudioPlayerDelegate {
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
    private var lastCapturedSamples: [Float] = []

    // MARK: - Internal Audio Processing State
    private var audioEngine: AVAudioEngine?
    private var audioPlayer: AVAudioPlayer?
    private let processingQueue = DispatchQueue(label: "com.soundalert.audioprocessing", qos: .userInteractive)

    /// 16kHz mono ring buffer (stores last 4 seconds = 64,000 samples)
    private var pcmRingBuffer: [Float] = []
    private let maxRingBufferSamples = 64000
    private var stftSampleAccumulator: [Float] = []

    /// Ring buffer of recent whitened spectrogram frames (stores last 250 frames = ~4 seconds)
    private var spectrogramRing: [[Float]] = []
    private let maxSpectrogramFrames = 250

    /// Auto-trigger recording buffers
    private var isWaitingForTrigger: Bool = false
    private var isCapturingSample: Bool = false
    private var captureBuffer: [Float] = []
    private let targetCaptureSamples: Int = Int(AudioFeatureExtractor.sampleRate * 1.6)

    /// Cooldown tracking
    private var lastTriggerTime: Date = .distantPast
    private var pendingPeakCandidate: (profile: SoundProfile, maxSim: Float, framesLeft: Int)? = nil
    private var activeHoldFramesRemaining: Int = 0
    private var lastUIUpdateTimestamp: CFAbsoluteTime = 0
    private var lastUIWasQuiet: Bool = false
    private static let zeroFrame = [Float](repeating: 0, count: AudioFeatureExtractor.numBands)

    // MARK: - Persistence Paths
    let storageDir: URL
    private let profilesFileURL: URL
    private let settingsFileURL: URL
    private let historyFileURL: URL

    override init() {
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

        super.init()

        loadSettings()
        loadProfiles()
        loadHistory()
        refreshInputDevices()
        checkAndRequestMicrophonePermission()
    }

    // MARK: - Persistence

    private func writeProtectedFile(_ data: Data, to url: URL) {
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Ignore write errors silently to avoid disrupting audio monitoring
        }
    }

    /// Validates that a filename resolves strictly inside `storageDir` (prevents path traversal)
    private func safeStorageFileURL(for filename: String) -> URL? {
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

    private func removeStorageFile(named filename: String) {
        guard let url = safeStorageFileURL(for: filename) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func saveSettings() {
        KeychainHelper.saveWebhookURL(settings.discordWebhookURL)
        var sanitized = settings
        sanitized.discordWebhookURL = ""
        if let data = try? JSONEncoder().encode(sanitized) {
            writeProtectedFile(data, to: settingsFileURL)
        }
    }

    private func loadSettings() {
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
                needSave = true // Strip legacy plaintext copy from settings.json
            }
            decoded.discordWebhookURL = keychainURL
        } else if !decoded.discordWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            KeychainHelper.saveWebhookURL(decoded.discordWebhookURL)
            needSave = true // Rewrite settings.json without plaintext webhook URL
        }

        self.settings = decoded
        if needSave {
            saveSettings()
        }
    }

    func calibrateNoiseGate() {
        // Set gate 6 dB above current room ambient level
        let targetGate = min(-20.0, max(-55.0, roundf(currentRMSdB + 6.0)))
        settings.minimumRMSdB = targetGate
        saveSettings()
    }

    func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            writeProtectedFile(data, to: profilesFileURL)
        }
    }

    private func loadProfiles() {
        if let data = try? Data(contentsOf: profilesFileURL),
           let decoded = try? JSONDecoder().decode([SoundProfile].self, from: data) {
            // Remove any legacy preset profiles so only user-recorded profiles remain
            let customOnly = decoded.filter { !$0.isBuiltIn }
            self.profiles = customOnly
            if customOnly.count != decoded.count {
                saveProfiles()
                // Clean up preset wav files
                if let files = try? FileManager.default.contentsOfDirectory(atPath: storageDir.path) {
                    for f in files where f.hasPrefix("preset_") {
                        removeStorageFile(named: f)
                    }
                }
            }
        } else {
            self.profiles = []
        }
    }

    func saveHistory() {
        if let data = try? JSONEncoder().encode(Array(detectionHistory.prefix(100))) {
            writeProtectedFile(data, to: historyFileURL)
        }
    }

    func clearDetectionHistory() {
        for event in detectionHistory {
            if let wav = event.capturedWavFilename {
                removeStorageFile(named: wav)
            }
        }
        detectionHistory.removeAll()
        saveHistory()
    }

    private func loadHistory() {
        if let data = try? Data(contentsOf: historyFileURL),
           let decoded = try? JSONDecoder().decode([DetectionEvent].self, from: data) {
            self.detectionHistory = decoded
        }
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
        var propAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddress,
            0,
            nil,
            &dataSize
        ) == noErr else { return }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else { return }

        var defaultInputID: AudioDeviceID = 0
        var defaultSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddr,
            0,
            nil,
            &defaultSize,
            &defaultInputID
        )

        var found: [AudioDevice] = []
        for id in deviceIDs {
            let inputChannels = Self.getInputChannelCount(deviceID: id)
            guard inputChannels > 0 else { continue }

            let name = Self.getDeviceStringProperty(deviceID: id, selector: kAudioObjectPropertyName) ?? "Unknown Mic (\(id))"
            let uid = Self.getDeviceStringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceUID) ?? "\(id)"
            let sr = Self.getDeviceSampleRate(deviceID: id)
            found.append(
                AudioDevice(
                    id: id,
                    uid: uid,
                    name: name,
                    sampleRate: sr,
                    inputChannels: inputChannels,
                    isDefault: id == defaultInputID
                )
            )
        }

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
        saveSettings()
        if isMonitoring {
            stopMonitoring()
            startMonitoring()
        }
    }

    var currentDeviceName: String {
        inputDevices.first(where: { $0.id == selectedDeviceID })?.name ?? "USBマイク"
    }

    private static func getInputChannelCount(deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let rawPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawPtr.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, rawPtr) == noErr else {
            return 0
        }
        let bufferList = UnsafeMutableAudioBufferListPointer(rawPtr.assumingMemoryBound(to: AudioBufferList.self))
        var channels = 0
        for buf in bufferList {
            channels += Int(buf.mNumberChannels)
        }
        return channels
    }

    private static func getDeviceStringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfStr)
        guard status == noErr, let value = cfStr?.takeUnretainedValue() else { return nil }
        return value as String
    }

    private static func getDeviceSampleRate(deviceID: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 16000.0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        return rate
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
            for c in 0..<channels {
                vDSP_vsma(channelData[c], 1, &scale, monoInput, 1, &monoInput, 1, vDSP_Length(frameCount))
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

        // 3. Handle iOS-style custom sound auto-trigger / manual recording
        if isWaitingForTrigger {
            // Trigger when RMS rises above -42 dB (or 8 dB above minimumRMSdB)
            let triggerDB = max(-42.0, settings.minimumRMSdB + 6.0)
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
            DispatchQueue.main.async {
                self.recordingState = .capturing(progress: progress)
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
        let extractor = AudioFeatureExtractor.shared
        if db >= settings.minimumRMSdB {
            // Keep analysis active for ~1.4 seconds (90 frames) after sound crosses noise gate
            // so the full chime duration + decay tail aligns completely with the template.
            activeHoldFramesRemaining = 90
        }
        let isAboveNoiseGate = activeHoldFramesRemaining > 0
        let shouldComputeFFT = isAboveNoiseGate || db >= (settings.minimumRMSdB - 6.0) || isCapturingSample

        guard stftSampleAccumulator.count >= fftSize else { return }

        var latestFrame: [Float] = Self.zeroFrame
        var newFramesCount = 0
        var simMap: [UUID: Float] = [:]
        let currentProfiles = self.profiles

        if shouldComputeFFT {
            var offset = 0
            stftSampleAccumulator.withUnsafeBufferPointer { buf in
                while offset + fftSize <= buf.count {
                    let slice = UnsafeBufferPointer(start: buf.baseAddress! + offset, count: fftSize)
                    let frame = extractor.computeFrame(samples512: slice)
                    spectrogramRing.append(frame)
                    latestFrame = frame
                    newFramesCount += 1
                    offset += hopSize

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
                                }
                            }
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
            newFramesCount = hops
            stftSampleAccumulator.removeFirst(hops * hopSize)
            if !lastUIWasQuiet || pendingPeakCandidate != nil {
                for _ in 0..<min(hops, 4) {
                    spectrogramRing.append(Self.zeroFrame)
                }
            }
        }

        // Advance peak candidate countdown if active
        var triggeredCandidate: (profile: SoundProfile, maxSim: Float, clipSamples: [Float])? = nil
        if var cand = pendingPeakCandidate {
            cand.framesLeft -= newFramesCount
            if cand.framesLeft <= 0 {
                let now = Date()
                if now.timeIntervalSince(lastTriggerTime) >= settings.cooldownSeconds {
                    lastTriggerTime = now
                    // Capture last 2.0 seconds of audio for replay in History
                    let clipLen = min(pcmRingBuffer.count, Int(AudioFeatureExtractor.sampleRate * 2.0))
                    let clip = Array(pcmRingBuffer.suffix(clipLen))
                    triggeredCandidate = (cand.profile, cand.maxSim, clip)
                }
                pendingPeakCandidate = nil
            } else {
                pendingPeakCandidate = cand
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

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Skip UI layout updates completely if all main windows are closed or hidden
            let hasVisibleMainWindow = NSApp.windows.contains {
                $0.isVisible && $0.occlusionState.contains(.visible) && $0.frame.width > 300
            }
            guard hasVisibleMainWindow || self.isWaitingForTrigger || self.isCapturingSample else {
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
        let wavURL = storageDir.appendingPathComponent(wavName)
        try? AudioFeatureExtractor.writeWavFile(samples: clipSamples, to: wavURL)

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
                    removeStorageFile(named: wav)
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
        lastCapturedSamples.removeAll()
        recordedSamplesCount = 0
        recordingState = .idle
    }

    /// Cancels the current recording session and deletes any unsaved pending WAV files
    func discardCustomSoundSession() {
        for wav in pendingWavFilenames {
            removeStorageFile(named: wav)
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
        guard let extracted = AudioFeatureExtractor.shared.extractNormalizedTemplate(from: rawSamples) else {
            DispatchQueue.main.async {
                self.recordingState = .error("音が小さすぎるか短すぎるため特徴を抽出できませんでした。もう一度お試しください。")
            }
            return
        }

        let wavName = "custom_\(UUID().uuidString).wav"
        let wavURL = storageDir.appendingPathComponent(wavName)
        try? AudioFeatureExtractor.writeWavFile(
            samples: extracted.trimmedSamples,
            normalizePeak: true,
            addSpeakerWakeupAndRepeatIfShort: true,
            to: wavURL
        )
        let dur = Double(extracted.trimmedSamples.count) / AudioFeatureExtractor.sampleRate

        DispatchQueue.main.async {
            self.lastCapturedSamples = extracted.trimmedSamples
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
            removeStorageFile(named: wav)
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
        saveProfiles()
        beginCustomSoundSession()
    }

    /// Appends a newly recorded template to an existing profile (e.g., adding a real mic sample to an existing profile)
    func addRecordedSamplesToProfile(_ profileID: UUID) {
        guard !pendingTemplates.isEmpty,
              let idx = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[idx].templates.append(contentsOf: pendingTemplates)
        profiles[idx].sampleWavFilenames.append(contentsOf: pendingWavFilenames)
        saveProfiles()
        beginCustomSoundSession()
    }

    func deleteProfile(_ profile: SoundProfile) {
        for wav in profile.sampleWavFilenames where !wav.hasPrefix("preset_") {
            removeStorageFile(named: wav)
        }
        profiles.removeAll { $0.id == profile.id }
        saveProfiles()
    }

    // MARK: - Audio Playback (Preview Registered Sound or Detected Clip)

    func playWavFile(named filename: String) {
        guard let url = safeStorageFileURL(for: filename),
              FileManager.default.fileExists(atPath: url.path) else {
            statusMessage = "再生ファイルが見つかりません: \(filename)"
            return
        }

        if isPlayingPreview && playingFilename == filename {
            audioPlayer?.stop()
            isPlayingPreview = false
            playingFilename = nil
            statusMessage = isMonitoring ? "監視中 (\(currentDeviceName))" : "停止中"
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.volume = 1.0
            player.prepareToPlay()
            player.play()
            self.audioPlayer = player
            self.isPlayingPreview = true
            self.playingFilename = filename
            self.statusMessage = "🔊 テスト音をMacのスピーカーから再生中..."
        } catch {
            self.statusMessage = "再生エラー: \(error.localizedDescription)"
        }
    }

    func playLastCapturedPreview() {
        guard let lastWav = pendingWavFilenames.last else { return }
        playWavFile(named: lastWav)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isPlayingPreview = false
            self.playingFilename = nil
            self.statusMessage = self.isMonitoring ? "監視中 (\(self.currentDeviceName))" : "停止中"
        }
    }
}
