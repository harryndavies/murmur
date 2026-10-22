import AVFoundation

/// Records from the default microphone and converts audio to the speech model's format.
/// A fresh engine is used per dictation so a newly plugged-in headset is picked up.
final class AudioCapture {
    enum CaptureError: LocalizedError {
        case noMicrophone
        case converterUnavailable

        var errorDescription: String? {
            switch self {
            case .noMicrophone: return "No microphone found"
            case .converterUnavailable: return "Couldn't read from the microphone"
            }
        }
    }

    private let engine = AVAudioEngine()
    private var converter: BufferConverter?
    private let targetFormat: AVAudioFormat

    /// Called on the audio thread with each converted buffer.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Called on the audio thread with the input level, 0...1.
    var onLevel: ((Float) -> Void)?

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    func start() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw CaptureError.noMicrophone }
        guard let converter = BufferConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.converterUnavailable
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.onLevel?(Self.level(of: buffer))
            if let converted = self.converter?.convert(buffer) { self.onBuffer?(converted) }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// RMS level mapped from roughly -55 dB (silence) ... -12 dB (loud speech) onto 0...1.
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        let rms = sqrt(sum / Float(count))
        let db = 20 * log10(max(rms, 1e-7))
        return min(max((db + 55) / 43, 0), 1)
    }
}

/// Streams buffers from one audio format to another (e.g. 48 kHz stereo mic → 16 kHz mono).
final class BufferConverter {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat

    init?(from source: AVAudioFormat, to target: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: source, to: target) else { return nil }
        self.converter = converter
        self.target = target
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status != .error && output.frameLength > 0 ? output : nil
    }
}
