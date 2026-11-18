import Foundation
import Accelerate
import AVFoundation

final class AudioFeatureExtractor {
    static let sampleRate: Double = 16000.0
    static let fftSize: Int = 512
    static let hopSize: Int = 256
    static let numBands: Int = 40
    static let minFreq: Double = 300.0
    static let maxFreq: Double = 5200.0

    private let hannWindow: [Float]
    private let fftSetup: vDSP_DFT_Setup?
    /// Triangular filter weights: [numBands][fftSize / 2]
    private let filterBank: [[Float]]

    // Reusable scratch buffers (accessed serially on processingQueue) to eliminate heap allocations
    private var scratchWindowed = [Float](repeating: 0, count: AudioFeatureExtractor.fftSize)
    private let scratchZeros = [Float](repeating: 0, count: AudioFeatureExtractor.fftSize)
    private var scratchRealOut = [Float](repeating: 0, count: AudioFeatureExtractor.fftSize)
    private var scratchImagOut = [Float](repeating: 0, count: AudioFeatureExtractor.fftSize)
    private var scratchPowerSpec = [Float](repeating: 0, count: AudioFeatureExtractor.fftSize / 2)
    private var scratchBandLog = [Float](repeating: 0, count: AudioFeatureExtractor.numBands)
    private var scratchSorted = [Float](repeating: 0, count: AudioFeatureExtractor.numBands)

    static let shared = AudioFeatureExtractor()

    init() {
        var win = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&win, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        self.hannWindow = win
        self.fftSetup = vDSP_DFT_zop_CreateSetup(
            nil,
            vDSP_Length(Self.fftSize),
            vDSP_DFT_Direction.FORWARD
        )
        self.filterBank = Self.buildLogFilterBank(
            numBands: Self.numBands,
            fftSize: Self.fftSize,
            sampleRate: Self.sampleRate,
            minFreq: Self.minFreq,
            maxFreq: Self.maxFreq
        )
    }

    deinit {
        if let setup = fftSetup {
            vDSP_DFT_DestroySetup(setup)
        }
    }

    private static func hzToMel(_ hz: Double) -> Double {
        return 2595.0 * log10(1.0 + hz / 700.0)
    }

    private static func melToHz(_ mel: Double) -> Double {
        return 700.0 * (pow(10.0, mel / 2595.0) - 1.0)
    }

    private static func buildLogFilterBank(
        numBands: Int,
        fftSize: Int,
        sampleRate: Double,
        minFreq: Double,
        maxFreq: Double
    ) -> [[Float]] {
        let halfFFT = fftSize / 2
        let minMel = hzToMel(minFreq)
        let maxMel = hzToMel(maxFreq)
        let melStep = (maxMel - minMel) / Double(numBands + 1)

        var melPoints = [Double]()
        for i in 0...(numBands + 1) {
            melPoints.append(minMel + Double(i) * melStep)
        }
        let hzPoints = melPoints.map { melToHz($0) }
        let binFreqs = (0..<halfFFT).map { Double($0) * sampleRate / Double(fftSize) }

        var bank = [[Float]](repeating: [Float](repeating: 0, count: halfFFT), count: numBands)
        for m in 0..<numBands {
            let fLeft = hzPoints[m]
            let fCenter = hzPoints[m + 1]
            let fRight = hzPoints[m + 2]

            for k in 0..<halfFFT {
                let f = binFreqs[k]
                if f >= fLeft && f <= fCenter && fCenter > fLeft {
                    bank[m][k] = Float((f - fLeft) / (fCenter - fLeft))
                } else if f > fCenter && f <= fRight && fRight > fCenter {
                    bank[m][k] = Float((fRight - f) / (fRight - fCenter))
                }
            }
            // Guarantee at least the nearest bin has weight 1.0 for narrow low-frequency bands
            let centerBin = min(halfFFT - 1, max(1, Int(round(fCenter * Double(fftSize) / sampleRate))))
            if bank[m].reduce(0, +) < 0.01 {
                bank[m][centerBin] = 1.0
            }
        }
        return bank
    }

    /// Computes a single whitened spectral frame [numBands] from 512 mono samples at 16kHz
    func computeFrame(samples512: UnsafeBufferPointer<Float>) -> [Float] {
        guard samples512.count == Self.fftSize, let setup = fftSetup else {
            return [Float](repeating: 0, count: Self.numBands)
        }

        vDSP_vmul(samples512.baseAddress!, 1, hannWindow, 1, &scratchWindowed, 1, vDSP_Length(Self.fftSize))
        vDSP_DFT_Execute(setup, scratchWindowed, scratchZeros, &scratchRealOut, &scratchImagOut)

        let halfFFT = Self.fftSize / 2
        for k in 0..<halfFFT {
            let r = scratchRealOut[k]
            let im = scratchImagOut[k]
            scratchPowerSpec[k] = r * r + im * im
        }

        for b in 0..<Self.numBands {
            var dot: Float = 0
            vDSP_dotpr(scratchPowerSpec, 1, filterBank[b], 1, &dot, vDSP_Length(halfFFT))
            scratchBandLog[b] = 10.0 * log10f(max(dot, 1e-9))
        }

        // Spectral whitening: subtract median across bands to emphasize tonal peaks (chimes/alerts)
        // and suppress broadband background noise (fan, typing, speech rumble).
        scratchSorted = scratchBandLog
        scratchSorted.sort()
        let median = scratchSorted[Self.numBands / 2]
        let baseline = median + 1.5
        var whitened = [Float](repeating: 0, count: Self.numBands)
        for b in 0..<Self.numBands {
            whitened[b] = max(0.0, scratchBandLog[b] - baseline)
        }
        return whitened
    }

    /// Extracts a 2D normalized spectrogram template from a mono 16kHz audio buffer.
    /// Automatically trims leading/trailing silence and normalizes the template.
    func extractNormalizedTemplate(from rawSamples: [Float]) -> (template: [[Float]], trimmedSamples: [Float])? {
        let trimmed = trimActiveAudio(samples: rawSamples)
        guard trimmed.count >= Self.fftSize * 2 else { return nil }

        var frames = [[Float]]()
        var idx = 0
        while idx + Self.fftSize <= trimmed.count {
            trimmed.withUnsafeBufferPointer { buf in
                let slice = UnsafeBufferPointer(
                    start: buf.baseAddress! + idx,
                    count: Self.fftSize
                )
                frames.append(computeFrame(samples512: slice))
            }
            idx += Self.hopSize
        }

        guard frames.count >= 8 else { return nil }
        let normalized = Self.normalizeTemplate(frames)
        return (normalized, trimmed)
    }

    /// Trims leading and trailing silence around an acoustic event
    func trimActiveAudio(samples: [Float]) -> [Float] {
        guard samples.count > Self.fftSize * 2 else { return samples }

        // Compute short-time energy in hop-sized windows
        var frameEnergies = [Float]()
        var indices = [Int]()
        var i = 0
        while i + Self.fftSize <= samples.count {
            var rms: Float = 0
            samples.withUnsafeBufferPointer { buf in
                vDSP_rmsqv(buf.baseAddress! + i, 1, &rms, vDSP_Length(Self.fftSize))
            }
            frameEnergies.append(rms)
            indices.append(i)
            i += Self.hopSize
        }

        guard let maxRMS = frameEnergies.max(), maxRMS > 0.001 else {
            return samples
        }

        let sortedRMS = frameEnergies.sorted()
        let noiseFloor = sortedRMS[max(0, sortedRMS.count / 5)]
        let threshold = max(noiseFloor * 2.2, maxRMS * 0.12)

        var firstFrame = 0
        var lastFrame = frameEnergies.count - 1
        for (idx, e) in frameEnergies.enumerated() {
            if e >= threshold {
                firstFrame = max(0, idx - 2)
                break
            }
        }
        for (idx, e) in frameEnergies.enumerated().reversed() {
            if e >= threshold {
                lastFrame = min(frameEnergies.count - 1, idx + 3)
                break
            }
        }

        let startSample = indices[firstFrame]
        let endSample = min(samples.count, indices[max(firstFrame, lastFrame)] + Self.fftSize)
        var slice = Array(samples[startSample..<endSample])

        // Cap length between 0.35s and 3.0s
        let maxSamples = Int(Self.sampleRate * 3.0)
        if slice.count > maxSamples {
            slice = Array(slice.prefix(maxSamples))
        }
        return slice
    }

    /// Normalizes a 2D spectrogram matrix [T][B] to zero-mean and unit L2 norm
    static func normalizeTemplate(_ frames: [[Float]]) -> [[Float]] {
        let T = frames.count
        guard T > 0 else { return [] }
        let B = frames[0].count
        let count = Float(T * B)

        var sum: Float = 0
        for f in frames {
            for v in f { sum += v }
        }
        let mean = sum / count

        var normSq: Float = 0
        for f in frames {
            for v in f {
                let d = v - mean
                normSq += d * d
            }
        }
        // Add regularizer so near-silence doesn't blow up to unit norm
        let norm = sqrtf(max(normSq, 25.0))

        var result = [[Float]]()
        result.reserveCapacity(T)
        for f in frames {
            var row = [Float](repeating: 0, count: B)
            for b in 0..<B {
                row[b] = (f[b] - mean) / norm
            }
            result.append(row)
        }
        return result
    }

    /// Computes cosine similarity (0.0 ... 1.0) between a pre-normalized template [T][B]
    /// and the latest T frames of the live spectrogram buffer (allowing small band shift +/-1 for pitch tolerance).
    static func computeSimilarity(
        normalizedTemplate: [[Float]],
        liveFrames: ArraySlice<[Float]>
    ) -> Float {
        let T = normalizedTemplate.count
        guard liveFrames.count == T, T > 0 else { return 0.0 }
        let B = normalizedTemplate[0].count

        let normalizedLive = normalizeTemplate(Array(liveFrames))

        // Compute dot product with exact band alignment and +/- 1 band tolerance
        var bestDot: Float = 0.0
        for shift in [-1, 0, 1] {
            var dot: Float = 0.0
            for t in 0..<T {
                let tplRow = normalizedTemplate[t]
                let liveRow = normalizedLive[t]
                if shift == 0 {
                    for b in 0..<B {
                        dot += tplRow[b] * liveRow[b]
                    }
                } else if shift == -1 {
                    for b in 1..<B {
                        dot += tplRow[b] * liveRow[b - 1]
                    }
                } else {
                    for b in 0..<(B - 1) {
                        dot += tplRow[b] * liveRow[b + 1]
                    }
                }
            }
            let weight: Float = (shift == 0) ? 1.0 : 0.94
            bestDot = max(bestDot, dot * weight)
        }

        return min(1.0, max(0.0, bestDot))
    }

    // MARK: - WAV File I/O

    static func writeWavFile(
        samples: [Float],
        sampleRate: Double = 16000.0,
        normalizePeak: Bool = true,
        addSpeakerWakeupAndRepeatIfShort: Bool = false,
        to url: URL
    ) throws {
        guard !samples.isEmpty else { return }

        // 1. Peak-normalize samples to 0.95 full scale so quiet mic recordings and presets are clearly audible
        var processed = samples
        if normalizePeak {
            var maxAbs: Float = 0
            for s in processed {
                let a = abs(s)
                if a > maxAbs { maxAbs = a }
            }
            if maxAbs > 0.0005 {
                let gain = 0.95 / maxAbs
                for i in 0..<processed.count {
                    processed[i] = max(-1.0, min(1.0, processed[i] * gain))
                }
            }
        }

        // 2. For short alert chimes (< 1.5s), prepend a 0.3s wake-up pre-roll (wakes Mac mini speaker DAC/amp from standby)
        // and repeat the chime twice so it is unmistakably audible and easy for the USB mic to pick up.
        var finalSamples = [Float]()
        if addSpeakerWakeupAndRepeatIfShort {
            let wakeupCount = Int(sampleRate * 0.30)
            for i in 0..<wakeupCount {
                // Sub-audible pilot tone to wake up macOS audio output hardware before the chime attack
                let t = Double(i) / sampleRate
                finalSamples.append(Float(0.003 * sin(2.0 * .pi * 120.0 * t)))
            }
            finalSamples.append(contentsOf: processed)
            if Double(processed.count) / sampleRate < 1.3 {
                let pauseCount = Int(sampleRate * 0.35)
                finalSamples.append(contentsOf: [Float](repeating: 0, count: pauseCount))
                finalSamples.append(contentsOf: processed)
            }
        } else {
            finalSamples = processed
        }

        let numSamples = finalSamples.count
        var int16Samples = [Int16](repeating: 0, count: numSamples)
        for i in 0..<numSamples {
            let clamped = max(-1.0, min(1.0, finalSamples[i]))
            int16Samples[i] = Int16(clamped * 32767.0)
        }

        let dataSize = UInt32(numSamples * 2)
        let fileSize = 36 + dataSize
        let sr = UInt32(sampleRate)
        let byteRate = sr * 2
        let blockAlign: UInt16 = 2
        let bitsPerSample: UInt16 = 16
        let audioFormat: UInt16 = 1
        let numChannels: UInt16 = 1
        let fmtChunkSize: UInt32 = 16

        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        withUnsafeBytes(of: fileSize.littleEndian) { header.append(contentsOf: $0) }
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        withUnsafeBytes(of: fmtChunkSize.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: audioFormat.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: numChannels.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: sr.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: byteRate.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: blockAlign.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: bitsPerSample.littleEndian) { header.append(contentsOf: $0) }
        header.append("data".data(using: .ascii)!)
        withUnsafeBytes(of: dataSize.littleEndian) { header.append(contentsOf: $0) }

        int16Samples.withUnsafeBytes { rawBuf in
            header.append(contentsOf: rawBuf)
        }

        try header.write(to: url, options: .atomic)
    }
}
